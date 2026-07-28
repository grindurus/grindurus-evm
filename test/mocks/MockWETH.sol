// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";

/// @dev Test double for WETH9: `deposit` mints 1:1 from `msg.value`.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH_TRANSFER");
    }
}
