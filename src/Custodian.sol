// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IGrinders} from "./interfaces/IGrinders.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";

/// @title Custodian (base implementation)
/// @notice Shared junior-capital custody: holds assets and routes principal/yield back to Grinders.
/// @dev Grinder ownership is recorded on Grinders (`IGrinders.ownerOf(custodianId)`).
abstract contract Custodian is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error NotOwner(address caller);
    error GrindersZero();
    error AmountZero();
    error BaseZero();
    error QuoteZero();
    error SameAsset();
    error NonZeroBalance();
    error FeatureDisabled();
    error FeatureDelay();
    error NotGrinders(address caller);
    error EthTransferFailed();
    error LiquidationOpen();

    uint48 public constant DISABLE_DELAY = 24 hours;

    IGrinders public grinders;
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

    function _onlyGrinders() internal view {
        if (msg.sender != address(grinders)) revert NotGrinders(msg.sender);
    }

    receive() external payable {}

    function initialize(address grinders_, address baseAsset_, address quoteAsset_) public virtual initializer {
        __Custodian_init(grinders_, baseAsset_, quoteAsset_);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __Custodian_init(address grinders_, address baseAsset_, address quoteAsset_) internal onlyInitializing {
        if (grinders_ == address(0)) revert GrindersZero();

        __UUPSUpgradeable_init();

        grinders = IGrinders(grinders_);
        _setTradingAssets(IERC20(baseAsset_), IERC20(quoteAsset_));
    }

    function custodianId() public view returns (uint256) {
        if (address(grinders).code.length == 0) return type(uint256).max;
        try grinders.custodianIds(address(this)) returns (uint256 id) {
            return id;
        } catch {
            return type(uint256).max;
        }
    }

    /// @dev By default, owner returns the grinders contract if the NFT owner is not found or not registered.
    function owner() public view virtual returns (address) {
        if (address(grinders).code.length == 0) return address(grinders);
        uint256 id = custodianId();
        if (id == type(uint256).max) return address(grinders);
        try grinders.ownerOf(id) returns (address owner_) {
            return owner_;
        } catch {
            return address(grinders);
        }
    }

    /// @notice Stable identifier for unambiguous custodian routing on Grinders and off-chain backends.
    /// @dev Returned as `keccak256("grindurus.custodian.<name>")` (optionally `...<name>.v2` for
    ///      incompatible families). The kind is intentionally **not** bumped on every UUPS upgrade:
    ///      - same kind + `set` → new default impl for future `Grinders.mint`
    ///      - existing proxies keep their impl until the NFT owner runs `upgradeTo`
    ///      - bump the string only when storage/API breaks (new kind = new registry entry)
    ///      Off-chain code can read `ERC1967Utils.getImplementation(proxy)` for the exact bytecode.
    function custodianKind() public view virtual returns (bytes32);

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice USD NAV of `baseAsset` and `quoteAsset` balances (6 decimals).
    /// @dev Returns 0 if grinders/GRAI is missing or price lookups fail.
    function nav() public virtual view returns (uint256) {
        if (address(grinders).code.length == 0) return 0;
        try grinders.grai() returns (IGRAI grai) {
            uint256 baseAssetValue = grai.usdValue(address(baseAsset), balance(address(baseAsset)));
            uint256 quoteAssetValue = grai.usdValue(address(quoteAsset), balance(address(quoteAsset)));
            return baseAssetValue + quoteAssetValue;
        } catch {
            return 0;
        }
        
    }

    /// @dev Safe against non-contract / non-IGrinders `grinders` (same pattern as `custodianId` / `owner`).
    function liquidation() public view returns (bool) {
        if (address(grinders).code.length == 0) return false;
        try grinders.grai() returns (IGRAI grai) {
            return grai.liquidation();
        } catch {
            return false;
        }
    }

    function setAssets(address baseAsset_, address quoteAsset_) public virtual {
        _onlyOwner();
        if (balance(address(baseAsset)) != 0 || balance(address(quoteAsset)) != 0) revert NonZeroBalance();
        _setTradingAssets(IERC20(baseAsset_), IERC20(quoteAsset_));
        emit AssetsUpdated(baseAsset_, quoteAsset_);
    }

    function distribute(address asset, uint256 yieldAmount) public virtual {
        _onlyOwner();
        if (liquidation()) revert LiquidationOpen();
        if (yieldAmount == 0) revert AmountZero();

        IGRAI grai = grinders.grai();
        if (asset == address(0)) {
            grai.distribute{value: yieldAmount}(asset, yieldAmount);
        } else {
            IERC20(asset).forceApprove(address(grai), yieldAmount);
            grai.distribute(asset, yieldAmount);
        }
    }

    /// @notice Return inventory to Grinders. Not limited by `allocated` (custodian may hold swapped assets).
    function deallocate(address asset, uint256 amount) public virtual {
        _onlyOwner();
        if (liquidation()) revert LiquidationOpen();
        if (amount == 0) revert AmountZero();
        if (asset == address(0)) {
            grinders.deallocate{value: amount}(asset, amount);
        } else {
            IERC20(asset).forceApprove(address(grinders), amount);
            grinders.deallocate(asset, amount);
        }
    }

    /// @notice Liquidation pull of ETH / base / quote to Grinders (only Grinders).
    function liquidate() public virtual returns (uint256 ethOut, uint256 baseOut, uint256 quoteOut) {
        _onlyGrinders();
        ethOut = _withdraw(address(grinders), address(0), balance(address(0)));
        baseOut = _withdraw(address(grinders), address(baseAsset), balance(address(baseAsset)));
        quoteOut = _withdraw(address(grinders), address(quoteAsset), balance(address(quoteAsset)));
    }

    /// @notice Lock UUPS upgrades instantly, or schedule unlock after `DISABLE_DELAY` when already locked.
    function toggleUpgradeable() public {
        _onlyOwner();
        if (!isUpgradeableDisabled && block.timestamp > upgradesDisableScheduledAt) {
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

    function _withdraw(address to, address asset, uint256 amount) internal virtual returns (uint256 withdrawn) {
        if (amount == 0) return 0;
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
        withdrawn = amount;
    }

    function _setTradingAssets(IERC20 baseAsset_, IERC20 quoteAsset_) internal virtual {
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
