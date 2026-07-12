// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ISeniorToken} from "./interfaces/ISeniorToken.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title SeniorToken (implementation)
/// @notice Senior idle reserve plus Grinders Senior Token (ST): yield-accruing tranche (~$ NAV, 6 decimals).
/// @dev Burns of GRAI still redeem physical assets via `withdraw`; ST tracks senior-tranche NAV.
///      Interact only via the ERC1967Proxy, not this implementation.
contract SeniorToken is ISeniorToken, ERC20Upgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error NotGrai();
    error NotAuthorized();
    error ZeroAddress();
    error ToZero();
    error AmountZero();
    error EthTransferFailed();
    error ValueExceedsNav();

    address public grai;

    /// @notice Senior-tranche NAV in USD (6 decimals). ST price ≈ `totalValue / totalSupply()`.
    uint256 public totalValue;

    event SeniorMint(address indexed to, uint256 stOut, uint256 value);
    event SeniorBurn(address indexed from, uint256 stAmount, uint256 value);
    event SeniorValueAccrued(uint256 value);
    event SeniorValueReduced(uint256 value);

    /// @dev Storage gap for future upgrades.
    uint256[44] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address grai_) public initializer {
        if (grai_ == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __ERC20_init("Grinders Senior Token", "ST");
        grai = grai_;
    }

    receive() external payable {}

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint ST when senior capital enters the vault (`value` in USD, 6 decimals).
    function mint(address to, uint256 value) external returns (uint256 stOut) {
        _onlyGrai();
        if (to == address(0)) revert ZeroAddress();
        if (value == 0) revert AmountZero();

        uint256 supply = totalSupply();
        if (supply == 0 || totalValue == 0) {
            stOut = value;
        } else {
            stOut = (value * supply) / totalValue;
        }
        if (stOut == 0) revert AmountZero();

        totalValue += value;
        _mint(to, stOut);
        emit SeniorMint(to, stOut, value);
    }

    /// @notice Accrue senior yield to ST holders without minting (price appreciation).
    function accrueValue(uint256 value) external {
        _onlyGrai();
        if (value == 0) revert AmountZero();
        totalValue += value;
        emit SeniorValueAccrued(value);
    }

    /// @notice Reduce senior-tranche NAV without burning ST (e.g. asset delist).
    function reduceValue(uint256 value) external {
        _onlyGrai();
        if (value == 0) revert AmountZero();
        if (value > totalValue) revert ValueExceedsNav();
        totalValue -= value;
        emit SeniorValueReduced(value);
    }

    /// @notice Burn ST and reduce senior-tranche NAV (`valueOut` in USD, 6 decimals).
    function burn(address from, uint256 stAmount) external returns (uint256 valueOut) {
        _onlyGrai();
        if (stAmount == 0) revert AmountZero();

        uint256 supply = totalSupply();
        if (supply == 0) revert AmountZero();

        valueOut = (stAmount * totalValue) / supply;
        totalValue -= valueOut;
        _burn(from, stAmount);
        emit SeniorBurn(from, stAmount, valueOut);
    }

    function withdraw(address asset, address to, uint256 amount) public {
        _onlyGrai();
        if (asset == address(0)) {
            if (to == address(0)) revert ToZero();
            if (amount == 0) revert AmountZero();
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _onlyGrai() private view {
        if (msg.sender != grai) revert NotGrai();
    }

    function _authorizeUpgrade(address) internal view override {
        bytes32 defaultAdminRole = AccessControlUpgradeable(grai).DEFAULT_ADMIN_ROLE();
        if (!IAccessControl(grai).hasRole(defaultAdminRole, msg.sender)) revert NotAuthorized();
    }
}
