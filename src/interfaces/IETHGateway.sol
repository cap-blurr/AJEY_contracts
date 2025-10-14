// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IETHGateway {
    /// @notice Deposits native ETH into the Aave Pool via the Gateway, receiving aWETH in the `onBehalfOf` account.
    function depositEth(address pool, address onBehalfOf, uint16 referralCode) external payable;

    /// @notice Withdraws WETH from Aave and unwraps to native ETH, sending to `to`.
    function withdrawEth(address pool, uint256 amount, address to) external;
}


