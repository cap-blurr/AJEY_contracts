// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

/// @title DonationSplitter
/// @notice Splits donation shares among multiple recipients based on configured weights
/// @dev Implements pull-based payment model for gas efficiency
contract DonationSplitter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Recipient configuration
    struct Recipient {
        address payee;
        uint256 weight; // Basis points (10000 = 100%)
        bool active;
    }

    /// @notice Donation strategy templates
    enum DonationStrategy {
        MaxHumanitarian, // 70% humanitarian, 20% hygiene, 10% crypto
        Balanced, // 40% humanitarian, 30% hygiene, 30% crypto
        MaxCrypto // 70% crypto, 20% humanitarian, 10% hygiene
    }

    // State
    Recipient[] public recipients;
    mapping(address => mapping(address => uint256)) public claimable; // token => payee => amount
    mapping(address => bool) public isStrategy; // Authorized strategies that can send shares
    mapping(address => uint256) public accounted; // token => amount of shares already allocated

    // Events
    event RecipientAdded(address indexed payee, uint256 weight);
    event RecipientUpdated(address indexed payee, uint256 weight, bool active);
    event StrategyUpdated(address indexed strategy, bool authorized);
    event SharesReceived(address indexed token, uint256 amount);
    event SharesClaimed(address indexed token, address indexed payee, uint256 amount);
    event StrategySet(DonationStrategy strategy);

    /// @notice Constructor
    /// @param _admin Admin address
    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /// @notice Set recipients based on predefined strategy
    /// @param strategy The donation strategy to apply
    function setDonationStrategy(DonationStrategy strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Clear existing recipients
        delete recipients;

        if (strategy == DonationStrategy.MaxHumanitarian) {
            recipients.push(
                Recipient({
                    payee: address(0x1111111111111111111111111111111111111111), // Humanitarian
                    weight: 7000,
                    active: true
                })
            );
            recipients.push(
                Recipient({
                    payee: address(0x2222222222222222222222222222222222222222), // Hygiene
                    weight: 2000,
                    active: true
                })
            );
            recipients.push(
                Recipient({
                    payee: address(0x3333333333333333333333333333333333333333), // Crypto
                    weight: 1000,
                    active: true
                })
            );
        } else if (strategy == DonationStrategy.Balanced) {
            recipients.push(
                Recipient({
                    payee: address(0x1111111111111111111111111111111111111111), // Humanitarian
                    weight: 4000,
                    active: true
                })
            );
            recipients.push(
                Recipient({
                    payee: address(0x2222222222222222222222222222222222222222), // Hygiene
                    weight: 3000,
                    active: true
                })
            );
            recipients.push(
                Recipient({
                    payee: address(0x3333333333333333333333333333333333333333), // Crypto
                    weight: 3000,
                    active: true
                })
            );
        } else if (strategy == DonationStrategy.MaxCrypto) {
            recipients.push(
                Recipient({
                    payee: address(0x3333333333333333333333333333333333333333), // Crypto
                    weight: 7000,
                    active: true
                })
            );
            recipients.push(
                Recipient({
                    payee: address(0x1111111111111111111111111111111111111111), // Humanitarian
                    weight: 2000,
                    active: true
                })
            );
            recipients.push(
                Recipient({
                    payee: address(0x2222222222222222222222222222222222222222), // Hygiene
                    weight: 1000,
                    active: true
                })
            );
        }

        emit StrategySet(strategy);
    }

    /// @notice Add a custom recipient
    /// @param payee Recipient address
    /// @param weight Weight in basis points
    function addRecipient(address payee, uint256 weight) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(payee != address(0), "payee=0");
        require(weight > 0, "weight=0");

        recipients.push(Recipient({payee: payee, weight: weight, active: true}));

        emit RecipientAdded(payee, weight);
    }

    /// @notice Update recipient configuration
    /// @param index Recipient index
    /// @param weight New weight
    /// @param active Whether recipient is active
    function updateRecipient(uint256 index, uint256 weight, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(index < recipients.length, "invalid index");
        recipients[index].weight = weight;
        recipients[index].active = active;

        emit RecipientUpdated(recipients[index].payee, weight, active);
    }

    /// @notice Authorize or revoke a strategy
    /// @param strategy Strategy address
    /// @param authorized Whether to authorize
    function setStrategy(address strategy, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isStrategy[strategy] = authorized;
        emit StrategyUpdated(strategy, authorized);
    }

    /// @notice Account and distribute newly received strategy shares already held by this splitter
    /// @dev Does NOT transfer tokens; it accounts for an 'amount' of shares that were minted/transferred here
    /// @param token Token address (strategy share token)
    /// @param amount Amount to account and split
    function receiveShares(address token, uint256 amount) external nonReentrant {
        // Allow either authorized strategies or admin to trigger accounting
        require(isStrategy[msg.sender] || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "unauthorized");
        require(amount > 0, "zero amount");

        // Ensure this splitter actually holds at least this unaccounted amount
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal >= accounted[token] + amount, "insufficient unallocated");

        // Calculate and allocate to recipients
        uint256 totalWeight = _getTotalWeight();
        require(totalWeight > 0, "no active recipients");

        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].active) {
                uint256 share = (amount * recipients[i].weight) / totalWeight;
                claimable[token][recipients[i].payee] += share;
            }
        }

        accounted[token] += amount;
        emit SharesReceived(token, amount);
    }

    /// @notice Claim accumulated shares
    /// @param token Token to claim
    function claim(address token) external nonReentrant {
        uint256 amount = claimable[token][msg.sender];
        require(amount > 0, "nothing to claim");

        claimable[token][msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit SharesClaimed(token, msg.sender, amount);
    }

    /// @notice Claim multiple tokens at once
    /// @param tokens Array of tokens to claim
    function claimMultiple(address[] calldata tokens) external nonReentrant {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = claimable[tokens[i]][msg.sender];
            if (amount > 0) {
                claimable[tokens[i]][msg.sender] = 0;
                IERC20(tokens[i]).safeTransfer(msg.sender, amount);
                emit SharesClaimed(tokens[i], msg.sender, amount);
            }
        }
    }

    /// @notice Get total weight of active recipients
    /// @return total Total weight
    function _getTotalWeight() internal view returns (uint256 total) {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].active) {
                total += recipients[i].weight;
            }
        }
    }

    /// @notice Get claimable amount for a payee
    /// @param token Token address
    /// @param payee Payee address
    /// @return Amount claimable
    function getClaimable(address token, address payee) external view returns (uint256) {
        return claimable[token][payee];
    }
}
