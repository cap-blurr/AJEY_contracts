// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IWETHGateway {
    function depositETH(address pool, address onBehalfOf, uint16 referralCode) external payable;
    function withdrawETH(address pool, uint256 amount, address to) external;
}


