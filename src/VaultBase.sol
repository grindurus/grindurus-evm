// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract VaultBase is Initializable {
    using SafeERC20 for IERC20;

    address public core;
    IERC20 public asset;

    modifier onlyCore() {
        require(msg.sender == core, "not core");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core, address _asset) external initializer {
        require(_core != address(0) && _asset != address(0), "zero addr");
        core = _core;
        asset = IERC20(_asset);
    }

    function balance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function withdraw(address to, uint256 amount) external onlyCore {
        asset.safeTransfer(to, amount);
    }
}
