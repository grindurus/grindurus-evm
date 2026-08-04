// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IGRAI} from "./interfaces/IGRAI.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/// @title Treasury
/// @notice Protocol fee sink for GRAI `treasuryCut` / bribe cuts and ETH fallbacks.
/// @dev UUPS proxy. `distribute` = only GRAI; upgrades = only `GRAI.owner()`.
contract Treasury is ITreasury, Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Linked GRAI that may call `distribute`; upgrades authorized by its `owner`.
    IGRAI public grai;

    /// @notice Protocol fee recipient for the non-affiliate slice of claim-time treasury income.
    address public beneficiar;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ITreasury
    function initialize(address grai_) external initializer {
        if (grai_ == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        grai = IGRAI(grai_);
    }

    function _onlyGrai() internal view {
        if (msg.sender != address(grai)) revert NotGrai();
    }

    receive() external payable {}

    /// @inheritdoc ITreasury
    /// @dev Caps to balance so an empty treasury does not revert the GRAI `claim`. Referrer is paid first.
    function distribute(
        address asset,
        address referrer,
        uint256 revenueShare,
        uint256 beneficiarShare
    ) external {
        _onlyGrai();
        uint256 bal = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        if (bal == 0) return;

        uint256 paidRevenue;
        if (referrer != address(0) && revenueShare > 0) {
            paidRevenue = revenueShare > bal ? bal : revenueShare;
            unchecked {
                bal -= paidRevenue;
            }
            _pay(asset, referrer, paidRevenue);
        } else if (revenueShare > 0) {
            // No referrer: affiliate slice stays with the protocol recipient.
            beneficiarShare += revenueShare;
        }

        uint256 paidBeneficiar;
        if (beneficiar != address(0) && beneficiarShare > 0 && bal > 0) {
            paidBeneficiar = beneficiarShare > bal ? bal : beneficiarShare;
            _pay(asset, beneficiar, paidBeneficiar);
        }

        if (paidRevenue > 0 || paidBeneficiar > 0) {
            emit Distribute(asset, referrer, beneficiar, paidRevenue, paidBeneficiar);
        }
    }

    function _pay(address asset, address to, uint256 amount) internal {
        if (asset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != grai.owner()) revert NotGraiOwner();
    }
}
