// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStrategyPermit} from "../../src/interfaces/IStrategyPermit.sol";

contract MockPermitToken is IStrategyPermit {
    bool public wasCalled;
    address public lastOwner;
    address public lastSpender;
    uint256 public lastValue;
    uint256 public lastDeadline;
    uint8 public lastV;
    bytes32 public lastR;
    bytes32 public lastS;

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        wasCalled = true;
        lastOwner = owner;
        lastSpender = spender;
        lastValue = value;
        lastDeadline = deadline;
        lastV = v;
        lastR = r;
        lastS = s;
    }
}

