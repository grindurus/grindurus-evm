// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Each non-mint/burn transfer delivers `amount * (BPS - feeBps) / BPS` to `to` and burns the fee.
contract MockFeeOnTransferERC20 is ERC20 {
    uint8 private immutable _DECIMALS;
    uint16 public immutable feeBps;
    uint16 public constant BPS = 10_000;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint16 feeBps_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / BPS;
            if (fee > 0) super._update(from, address(0), fee);
            super._update(from, to, value - fee);
            return;
        }
        super._update(from, to, value);
    }
}
