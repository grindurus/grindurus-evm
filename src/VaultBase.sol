// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract VaultBase {
    using SafeERC20 for IERC20;

    error NotProprietor();
    error ZeroAddress();
    error ValueMismatch();
    error AmountZero();
    error UnexpectedValue();
    error ToZero();
    error EthTransferFailed();

    address public immutable PROPRIETOR;

    function _onlyProprietor() private view {
        if (msg.sender != PROPRIETOR) revert NotProprietor();
    }

    constructor(address _proprietor) {
        if (_proprietor == address(0)) revert ZeroAddress();
        PROPRIETOR = _proprietor;
    }

    receive() external payable {}

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit(address asset, uint256 amount) public payable {
        _onlyProprietor();
        if (asset == address(0)) {
            if (msg.value != amount) revert ValueMismatch();
            if (amount == 0) revert AmountZero();
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function withdraw(address asset, address to, uint256 amount) public {
        _onlyProprietor();
        if (asset == address(0)) {
            if (to == address(0)) revert ToZero();
            if (amount == 0) revert AmountZero();
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}
