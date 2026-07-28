// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 that notifies the recipient like ERC777 `tokensReceived` (test hook surface).
interface ITokenRecipient {
    function tokensReceived(address operator, address from, address to, uint256 amount) external;
}

contract MockCallbackERC20 is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        // Skip mint/burn; notify contract recipients only (ERC777-like hook surface).
        if (from != address(0) && to != address(0) && to.code.length > 0) {
            ITokenRecipient(to).tokensReceived(msg.sender, from, to, value);
        }
    }
}
