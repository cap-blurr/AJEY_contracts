// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockRevertingAggregator {
    function swap(address, address, uint256, uint256) external pure {
        revert("bad swap");
    }
}

