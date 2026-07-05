// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract VaultBase {
    using SafeERC20 for IERC20;

    address public immutable PROPRIETOR;

    function _onlyProprietor() private view {
        require(msg.sender == PROPRIETOR, "not proprietor");
    }

    constructor(address _proprietor) {
        require(_proprietor != address(0), "zero addr");
        PROPRIETOR = _proprietor;
    }

    receive() external payable {}

    function balance(address asset) external view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit(address asset, uint256 amount) external payable {
        _onlyProprietor();
        if (asset == address(0)) {
            require(msg.value == amount, "value mismatch");
            require(amount > 0, "amount=0");
        } else {
            require(msg.value == 0, "unexpected value");
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function withdraw(address asset, address to, uint256 amount) external {
        _onlyProprietor();
        if (asset == address(0)) {
            require(to != address(0), "to=0");
            require(amount > 0, "amount=0");
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth transfer failed");
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}