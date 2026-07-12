// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IGRAI} from "./interfaces/IGRAI.sol";
import {IJuniorToken} from "./interfaces/IJuniorToken.sol";

/// @title Custodian (base implementation)
/// @notice Shared junior-capital custody: holds assets and routes principal/yield back to GRAI.
/// @dev Grinder ownership is recorded on JuniorToken (`IJuniorToken.custodianOwners(custodian)`).
///      GRAI is read from `IJuniorToken(juniorToken).grai()`.
abstract contract Custodian is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error NotOwner(address caller);
    error JuniorTokenZero();
    error AmountZero();
    error BaseZero();
    error QuoteZero();
    error SameAsset();
    error NonZeroBalance();
    error FeatureDisabled();
    error FeatureDelay();

    uint48 public constant DISABLE_DELAY = 24 hours;

    IERC20 public baseAsset;
    IERC20 public quoteAsset;
    address public juniorToken;
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
        address juniorToken_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) public virtual initializer {
        __Custodian_init(juniorToken_, baseAsset_, quoteAsset_);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __Custodian_init(
        address juniorToken_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) internal onlyInitializing {
        if (juniorToken_ == address(0)) revert JuniorTokenZero();

        __UUPSUpgradeable_init();

        juniorToken = juniorToken_;
        _setTradingAssets(baseAsset_, quoteAsset_);
    }

    function custodianId() public view returns (uint256) {
        if (juniorToken.code.length == 0) return type(uint256).max;
        try IJuniorToken(juniorToken).custodianIds(address(this)) returns (uint256 id) {
            return id;
        } catch {
            return type(uint256).max;
        }
    }

    function grai() public view virtual returns (address) {
        if (juniorToken.code.length == 0) return address(0);
        try IJuniorToken(juniorToken).grai() returns (address grai_) {
            return grai_;
        } catch {
            return address(0);
        }
    }

    function owner() public view virtual returns (address) {
        if (juniorToken.code.length == 0) return juniorToken;
        try IJuniorToken(juniorToken).ownerOf(custodianId()) returns (address owner_) {
            return owner_;
        } catch {
            return juniorToken;
        }
    }

    /// @notice Stable identifier for unambiguous custodian routing on JuniorToken and off-chain backends.
    /// @dev Returned as `keccak256("grindurus.custodian.<name>")` (optionally `...<name>.v2` for
    ///      incompatible families). The kind is intentionally **not** bumped on every UUPS upgrade:
    ///      - same kind + `setCustodianImplementation` → new default impl for future `JuniorToken.mintCustodian`
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
        address grai_ = grai();
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
        if (asset == address(0)) {
            IJuniorToken(juniorToken).deallocate{value: amount}(asset, amount);
        } else {
            IERC20(asset).forceApprove(juniorToken, amount);
            IJuniorToken(juniorToken).deallocate(asset, amount);
        }
    }

    function distribute(address asset, uint256 yieldAmount) public {
        _onlyOwner();
        if (yieldAmount == 0) revert AmountZero();
        IJuniorToken(juniorToken).recordYield(address(this), asset, yieldAmount);
        address grai_ = grai();
        if (asset == address(0)) {
            IGRAI(grai_).distribute{value: yieldAmount}(asset, yieldAmount);
        } else {
            IERC20(asset).forceApprove(grai_, yieldAmount);
            IGRAI(grai_).distribute(asset, yieldAmount);
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