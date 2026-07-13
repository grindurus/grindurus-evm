// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IGRAI} from "./interfaces/IGRAI.sol";

/// @title Custodian (base implementation)
/// @notice Shared junior-capital custody: holds assets and routes principal/yield back to GRAI.
/// @dev Grinder ownership is recorded on GRAI (`IGRAI.ownerOf(custodianId)`).
abstract contract Custodian is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error NotOwner(address caller);
    error GraiZero();
    error AmountZero();
    error BaseZero();
    error QuoteZero();
    error SameAsset();
    error NonZeroBalance();
    error FeatureDisabled();
    error FeatureDelay();

    uint48 public constant DISABLE_DELAY = 24 hours;

    address public grai;
    IERC20 public baseAsset;
    IERC20 public quoteAsset;
    bool public isUpgradeableDisabled;
    uint48 public upgradesDisableScheduledAt;

    event AssetsUpdated(address indexed baseAsset, address indexed quoteAsset);
    event UpgradesReenableScheduled(uint48 reenableAt);
    event UpgradesDisabled();
    event UpgradesReenabled();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner()) revert NotOwner(msg.sender);
    }

    receive() external payable {}

    function initialize(
        address grai_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) public virtual initializer {
        __Custodian_init(grai_, baseAsset_, quoteAsset_);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __Custodian_init(
        address grai_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) internal onlyInitializing {
        if (grai_ == address(0)) revert GraiZero();

        __UUPSUpgradeable_init();

        grai = grai_;
        _setTradingAssets(baseAsset_, quoteAsset_);
    }

    function custodianId() public view returns (uint256) {
        if (grai.code.length == 0) return type(uint256).max;
        try IGRAI(grai).custodianIds(address(this)) returns (uint256 id) {
            return id;
        } catch {
            return type(uint256).max;
        }
    }

    function owner() public view virtual returns (address) {
        if (grai.code.length == 0) return grai;
        uint256 id = custodianId();
        if (id == type(uint256).max) return grai;
        try IGRAI(grai).ownerOf(id) returns (address owner_) {
            return owner_;
        } catch {
            return grai;
        }
    }

    /// @notice Stable identifier for unambiguous custodian routing on GRAI and off-chain backends.
    /// @dev Returned as `keccak256("grindurus.custodian.<name>")` (optionally `...<name>.v2` for
    ///      incompatible families). The kind is intentionally **not** bumped on every UUPS upgrade:
    ///      - same kind + `setCustodianImplementation` → new default impl for future `GRAI.mint`
    ///      - existing proxies keep their impl until the NFT owner runs `upgradeTo`
    ///      - bump the string only when storage/API breaks (new kind = new registry entry)
    ///      Off-chain code can read `ERC1967Utils.getImplementation(proxy)` for the exact bytecode.
    function custodianKind() public view virtual returns (bytes32);

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice USD NAV of `baseAsset` and `quoteAsset` balances (6 decimals).
    function nav() public view returns (uint256) {
        return IGRAI(grai).usdValue(address(baseAsset), balance(address(baseAsset)))
            + IGRAI(grai).usdValue(address(quoteAsset), balance(address(quoteAsset)));
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
        if (asset == address(0)) {
            IGRAI(grai).deallocate{value: amount}(asset, amount);
        } else {
            IERC20(asset).forceApprove(grai, amount);
            IGRAI(grai).deallocate(asset, amount);
        }
    }

    function distribute(address asset, uint256 yieldAmount) public {
        _onlyOwner();
        if (yieldAmount == 0) revert AmountZero();
        if (asset == address(0)) {
            IGRAI(grai).distribute{value: yieldAmount}(asset, yieldAmount);
        } else {
            IERC20(asset).forceApprove(grai, yieldAmount);
            IGRAI(grai).distribute(asset, yieldAmount);
        }
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

    function _authorizeUpgrade(address newImplementation) internal view override {
        _onlyOwner();
        newImplementation;
        if (isUpgradeableDisabled) revert FeatureDisabled();
        if (block.timestamp <= upgradesDisableScheduledAt) revert FeatureDelay();
    }
}
