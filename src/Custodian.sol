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

    address public grinders;
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
        if (msg.sender != grinders) revert NotGrinders(msg.sender);
    }

    receive() external payable {}

    function initialize(
        address grinders_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) public virtual initializer {
        __Custodian_init(grinders_, baseAsset_, quoteAsset_);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __Custodian_init(
        address grinders_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) internal onlyInitializing {
        if (grinders_ == address(0)) revert GrindersZero();

        __UUPSUpgradeable_init();

        grinders = grinders_;
        _setTradingAssets(baseAsset_, quoteAsset_);
    }

    function custodianId() public view returns (uint256) {
        if (grinders.code.length == 0) return type(uint256).max;
        try IGrinders(grinders).custodianIds(address(this)) returns (uint256 id) {
            return id;
        } catch {
            return type(uint256).max;
        }
    }

    /// @dev By default, owner returns the grinders contract if the NFT owner is not found or not registered.
    function owner() public view virtual returns (address) {
        if (grinders.code.length == 0) return grinders;
        uint256 id = custodianId();
        if (id == type(uint256).max) return grinders;
        try IGrinders(grinders).ownerOf(id) returns (address owner_) {
            return owner_;
        } catch {
            return grinders;
        }
    }

    /// @notice Stable identifier for unambiguous custodian routing on Grinders and off-chain backends.
    /// @dev Returned as `keccak256("grindurus.custodian.<name>")` (optionally `...<name>.v2` for
    ///      incompatible families). The kind is intentionally **not** bumped on every UUPS upgrade:
    ///      - same kind + `setCustodianImplementation` → new default impl for future `Grinders.mint`
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
        IGRAI token = IGrinders(grinders).grai();
        return token.usdValue(address(baseAsset), balance(address(baseAsset)))
            + token.usdValue(address(quoteAsset), balance(address(quoteAsset)));
    }

    function setAssets(IERC20 baseAsset_, IERC20 quoteAsset_) public virtual {
        _onlyOwner();
        if (balance(address(baseAsset)) != 0 || balance(address(quoteAsset)) != 0) revert NonZeroBalance();
        _setTradingAssets(baseAsset_, quoteAsset_);
        emit AssetsUpdated(address(baseAsset_), address(quoteAsset_));
    }

    function deallocate(address asset, uint256 amount) public {
        _onlyOwner();
        if (_isLiquidating()) revert LiquidationOpen();
        if (amount == 0) revert AmountZero();
        if (asset == address(0)) {
            IGrinders(grinders).deallocate{value: amount}(asset, amount);
        } else {
            IERC20(asset).forceApprove(grinders, amount);
            IGrinders(grinders).deallocate(asset, amount);
        }
    }

    /// @dev Safe against non-contract / non-IGrinders `grinders` (same pattern as `custodianId` / `owner`).
    function _isLiquidating() internal view returns (bool) {
        if (grinders.code.length == 0) return false;
        try IGrinders(grinders).grai() returns (IGRAI grai) {
            return grai.liquidation();
        } catch {
            return false;
        }
    }

    /// @notice Liquidation pull of ETH / base / quote to Grinders (only Grinders).
    function liquidate() public returns (uint256 ethOut, uint256 baseOut, uint256 quoteOut) {
        _onlyGrinders();

        ethOut = address(this).balance;
        if (ethOut > 0) {
            (bool ok,) = grinders.call{value: ethOut}("");
            if (!ok) revert EthTransferFailed();
        }

        baseOut = _sweepToken(baseAsset, grinders);
        quoteOut = _sweepToken(quoteAsset, grinders);
    }

    function _sweepToken(IERC20 token, address to) private returns (uint256 bal) {
        if (address(token) == address(0)) return 0;
        bal = token.balanceOf(address(this));
        if (bal > 0) token.safeTransfer(to, bal);
    }

    function distribute(address asset, uint256 yieldAmount) public {
        _onlyOwner();
        if (yieldAmount == 0) revert AmountZero();

        IGRAI grai_ = IGrinders(grinders).grai();
        if (asset == address(0)) {
            grai_.distribute{value: yieldAmount}(asset, yieldAmount);
        } else {
            IERC20(asset).forceApprove(address(grai_), yieldAmount);
            grai_.distribute(asset, yieldAmount);
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
