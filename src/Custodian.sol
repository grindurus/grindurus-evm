// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IGRAI} from "./interfaces/IGRAI.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/// @title Custodian (base implementation)
/// @notice Shared junior-capital custody: holds assets and routes principal/yield back to GRAI.
/// @dev Grinder ownership is the Treasury custodian NFT (`ITreasury.ownerOf(custodianId)`).
///      GRAI is read from `ITreasury(treasury).grai()`.
abstract contract Custodian is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error NotOwner(address caller);
    error TreasuryZero();
    error AmountZero();
    error BaseZero();
    error QuoteZero();
    error SameAsset();
    error NonZeroBalance();
    error EthTransferFailed();
    error FeatureDisabled();
    error FeatureDelay();
    error GraiZero();

    uint48 public constant DISABLE_DELAY = 24 hours;

    IERC20 public baseAsset;
    IERC20 public quoteAsset;
    address public treasury;
    uint256 public custodianId;
    bool public isUpgradeableDisabled;
    bool public isRescueDisabled;
    uint48 public upgradesDisableScheduledAt;
    uint48 public rescueDisableScheduledAt;

    event Rescued(address indexed asset, address indexed to, uint256 amount);
    event AssetsUpdated(address indexed baseAsset, address indexed quoteAsset);
    event UpgradesReenableScheduled(uint48 reenableAt);
    event UpgradesDisabled();
    event UpgradesReenabled();
    event RescueReenableScheduled(uint48 reenableAt);
    event RescueDisabled();
    event RescueReenabled();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner()) revert NotOwner(msg.sender);
    }

    receive() external payable {}

    function initialize(
        address treasury_,
        uint256 custodianId_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) public virtual initializer {
        __Custodian_init(treasury_, custodianId_, baseAsset_, quoteAsset_);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __Custodian_init(
        address treasury_,
        uint256 custodianId_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) internal onlyInitializing {
        if (treasury_ == address(0)) revert TreasuryZero();

        __UUPSUpgradeable_init();

        treasury = treasury_;
        custodianId = custodianId_;
        _setTradingAssets(baseAsset_, quoteAsset_);
    }

    function grai() public view virtual returns (address) {
        if (treasury.code.length == 0) return address(0);
        try ITreasury(treasury).grai() returns (address grai_) {
            return grai_;
        } catch {
            return address(0);
        }
    }

    function owner() public view virtual returns (address) {
        if (treasury.code.length == 0) return treasury;
        try ITreasury(treasury).ownerOf(custodianId) returns (address owner_) {
            return owner_;
        } catch {
            return treasury;
        }
    }

    /// @notice Stable identifier for unambiguous custodian routing on Treasury and off-chain backends.
    /// @dev Returned as `keccak256("grindurus.custodian.<name>")` (optionally `...<name>.v2` for
    ///      incompatible families). The kind is intentionally **not** bumped on every UUPS upgrade:
    ///      - same kind + `setCustodyImplementation` → new default impl for future `Treasury.mint`
    ///      - existing proxies keep their impl until the NFT owner runs `upgradeTo`
    ///      - bump the string only when storage/API breaks (new kind = new registry entry)
    ///      Off-chain code can read `ERC1967Utils.getImplementation(proxy)` for the exact bytecode.
    function custodianKind() public view virtual returns (bytes32);

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice USD NAV of `baseAsset` and `quoteAsset` balances (18 decimals).
    function nav() public view returns (uint256) {
        address grai_ = grai();
        if (grai_ == address(0)) revert GraiZero();
        return IGRAI(grai_).usdValue(address(baseAsset), balance(address(baseAsset)))
            + IGRAI(grai_).usdValue(address(quoteAsset), balance(address(quoteAsset)));
    }

    function setAssets(IERC20 baseAsset_, IERC20 quoteAsset_) public virtual {
        _onlyOwner();
        if (balance(address(baseAsset)) != 0 || balance(address(quoteAsset)) != 0) revert NonZeroBalance();
        _setTradingAssets(baseAsset_, quoteAsset_);
        emit AssetsUpdated(address(baseAsset_), address(quoteAsset_));
    }

    function deallocate(address asset, uint256 amount) public {
        _onlyOwner();
        if (amount == 0) revert AmountZero();
        address grai_ = grai();
        if (asset == address(0)) {
            IGRAI(grai_).deallocate{value: amount}(asset, amount);
        } else {
            IERC20(asset).forceApprove(grai_, amount);
            IGRAI(grai_).deallocate(asset, amount);
        }
    }

    function distribute(address asset, uint256 yieldAmount) public {
        _onlyOwner();
        if (yieldAmount == 0) revert AmountZero();
        address grai_ = grai();
        if (asset == address(0)) {
            IGRAI(grai_).distribute{value: yieldAmount}(asset, yieldAmount);
        } else {
            IERC20(asset).forceApprove(grai_, yieldAmount);
            IGRAI(grai_).distribute(asset, yieldAmount);
        }
    }

    /// @notice Rescue assets to treasury without going through GRAI accounting.
    function rescue(address asset, uint256 amount) public {
        _onlyOwner();
        _checkRescue();
        if (amount == 0) revert AmountZero();
        address to = treasury;
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
        emit Rescued(asset, to, amount);
    }

    /// @notice Lock UUPS upgrades instantly, or schedule unlock after `DISABLE_DELAY` when already locked.
    function toggleUpgradeable() public {
        _onlyOwner();
        if (_isFeatureUnlocked(isUpgradeableDisabled, upgradesDisableScheduledAt)) {
            isUpgradeableDisabled = true;
            upgradesDisableScheduledAt = type(uint48).max;
            emit UpgradesDisabled();
            return;
        }
        if (isUpgradeableDisabled) {
            isUpgradeableDisabled = false;
            upgradesDisableScheduledAt = uint48(block.timestamp + DISABLE_DELAY);
            emit UpgradesReenableScheduled(upgradesDisableScheduledAt);
            return;
        }
        isUpgradeableDisabled = true;
        upgradesDisableScheduledAt = type(uint48).max;
        emit UpgradesDisabled();
    }

    /// @notice Lock `rescue` instantly, or schedule unlock after `DISABLE_DELAY` when already locked.
    function toggleRescue() public {
        _onlyOwner();
        if (_isFeatureUnlocked(isRescueDisabled, rescueDisableScheduledAt)) {
            isRescueDisabled = true;
            rescueDisableScheduledAt = type(uint48).max;
            emit RescueDisabled();
            return;
        }
        if (isRescueDisabled) {
            isRescueDisabled = false;
            rescueDisableScheduledAt = uint48(block.timestamp + DISABLE_DELAY);
            emit RescueReenableScheduled(rescueDisableScheduledAt);
            return;
        }
        isRescueDisabled = true;
        rescueDisableScheduledAt = type(uint48).max;
        emit RescueDisabled();
    }

    function _isFeatureUnlocked(bool isDisabled, uint48 disableScheduledAt) internal view returns (bool) {
        return !isDisabled && block.timestamp > disableScheduledAt;
    }

    function _setTradingAssets(IERC20 baseAsset_, IERC20 quoteAsset_) internal {
        if (address(baseAsset_) == address(0)) revert BaseZero();
        if (address(quoteAsset_) == address(0)) revert QuoteZero();
        if (address(baseAsset_) == address(quoteAsset_)) revert SameAsset();

        baseAsset = baseAsset_;
        quoteAsset = quoteAsset_;
    }

    function _checkRescue() internal view {
        if (isRescueDisabled) revert FeatureDisabled();
        if (block.timestamp <= rescueDisableScheduledAt) revert FeatureDelay();
    }

    function _authorizeUpgrade(address newImplementation) internal view override {
        _onlyOwner();
        newImplementation;
        if (isUpgradeableDisabled) revert FeatureDisabled();
        if (block.timestamp <= upgradesDisableScheduledAt) revert FeatureDelay();
    }
}
