// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IGRAI} from "./interfaces/IGRAI.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/// @title Custodian (base implementation)
/// @notice Shared junior-capital custody: holds assets and routes principal/yield back to GRAI.
/// @dev Grinder ownership is the Treasury custodian NFT (`treasury.ownerOf(custodianId)`).
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
    error FeatureEnabled();
    error FeatureScheduled();
    error FeatureDisabled();
    error FeatureDelay();

    uint48 public constant DISABLE_DELAY = 24 hours;

    IERC20 public baseAsset;
    IERC20 public quoteAsset;
    address public treasury;
    uint256 public custodianId;
    bool public upgradesDisabled;
    bool public emergencyWithdrawDisabled;
    uint48 public upgradesDisableScheduledAt;
    uint48 public emergencyWithdrawDisableScheduledAt;

    event EmergencyWithdraw(address indexed asset, address indexed to, uint256 amount);
    event AssetsUpdated(address indexed baseAsset, address indexed quoteAsset);
    event UpgradesReenableScheduled(uint48 reenableAt);
    event UpgradesDisabled();
    event UpgradesReenabled();
    event EmergencyWithdrawReenableScheduled(uint48 reenableAt);
    event EmergencyWithdrawDisabled();
    event EmergencyWithdrawReenabled();

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

    function grai() public view virtual returns (IGRAI) {
        if (treasury == address(0)) return IGRAI(address(0));
        try ITreasury(treasury).grai() returns (IGRAI grai_) {
            return grai_;
        } catch {
            return IGRAI(address(0));
        }
    }

    function owner() public view virtual returns (address) {
        if (treasury == address(0)) return treasury;
        return IERC721(treasury).ownerOf(custodianId);
    }

    /// @notice Stable identifier for unambiguous custodian routing on Treasury and off-chain backends.
    /// @dev Returned as `keccak256("grindurus.custodian.<name>")` (optionally `...<name>.v2` for
    ///      incompatible families). The kind is intentionally **not** bumped on every UUPS upgrade:
    ///      - same kind + `setCustodyImplementation` → new default impl for future `Treasury.mint`
    ///      - existing proxies keep their impl until the NFT owner runs `upgradeTo`
    ///      - bump the string only when storage/API breaks (new kind = new registry entry)
    ///      Off-chain code can read `ERC1967Utils.getImplementation(proxy)` for the exact bytecode.
    function custodyKind() public view virtual returns (bytes32);

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function setAssets(IERC20 baseAsset_, IERC20 quoteAsset_) public {
        _onlyOwner();
        if (balance(address(baseAsset)) != 0 || balance(address(quoteAsset)) != 0) revert NonZeroBalance();
        _setTradingAssets(baseAsset_, quoteAsset_);
        emit AssetsUpdated(address(baseAsset_), address(quoteAsset_));
    }

    function deallocate(address asset, uint256 amount) public {
        _onlyOwner();
        if (amount == 0) revert AmountZero();
        IGRAI grai_ = grai();
        if (asset == address(0)) {
            grai_.deallocate{value: amount}(asset, amount);
        } else {
            IERC20(asset).forceApprove(address(grai_), amount);
            grai_.deallocate(asset, amount);
        }
    }

    function distribute(address asset, uint256 yieldAmount) public {
        _onlyOwner();
        if (yieldAmount == 0) revert AmountZero();
        IGRAI grai_ = grai();
        if (asset == address(0)) {
            grai_.distribute{value: yieldAmount}(asset, yieldAmount);
        } else {
            IERC20(asset).forceApprove(address(grai_), yieldAmount);
            grai_.distribute(asset, yieldAmount);
        }
    }

    /// @notice Rescue assets to owner without going through GRAI accounting.
    function emergencyWithdraw(address asset, uint256 amount) public {
        _onlyOwner();
        _checkEmergencyWithdraw();
        if (amount == 0) revert AmountZero();
        address to = owner();
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
        emit EmergencyWithdraw(asset, to, amount);
    }

    /// @notice Toggle UUPS upgrades. `true`: lock instantly (cancels pending unlock schedule). `false`: schedule unlock.
    function setUpgradesDisabled(bool disabled) public {
        _onlyOwner();
        if (disabled) {
            if (upgradesDisabled) {
                upgradesDisableScheduledAt = type(uint48).max;
                return;
            }
            upgradesDisabled = true;
            upgradesDisableScheduledAt = type(uint48).max;
            emit UpgradesDisabled();
        } else {
            if (!upgradesDisabled) revert FeatureEnabled();
            if (upgradesDisableScheduledAt != type(uint48).max) revert FeatureScheduled();
            upgradesDisabled = false;
            upgradesDisableScheduledAt = uint48(block.timestamp + DISABLE_DELAY);
            emit UpgradesReenableScheduled(upgradesDisableScheduledAt);
        }
    }

    /// @notice Toggle `emergencyWithdraw`. `true`: lock instantly (cancels pending unlock schedule). `false`: schedule unlock.
    function setEmergencyWithdrawDisabled(bool disabled) public {
        _onlyOwner();
        if (disabled) {
            if (emergencyWithdrawDisabled) {
                emergencyWithdrawDisableScheduledAt = type(uint48).max;
                return;
            }
            emergencyWithdrawDisabled = true;
            emergencyWithdrawDisableScheduledAt = type(uint48).max;
            emit EmergencyWithdrawDisabled();
        } else {
            if (!emergencyWithdrawDisabled) revert FeatureEnabled();
            if (emergencyWithdrawDisableScheduledAt != type(uint48).max) revert FeatureScheduled();
            emergencyWithdrawDisabled = false;
            emergencyWithdrawDisableScheduledAt = uint48(block.timestamp + DISABLE_DELAY);
            emit EmergencyWithdrawReenableScheduled(emergencyWithdrawDisableScheduledAt);
        }
    }

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

    function _setTradingAssets(IERC20 baseAsset_, IERC20 quoteAsset_) internal {
        if (address(baseAsset_) == address(0)) revert BaseZero();
        if (address(quoteAsset_) == address(0)) revert QuoteZero();
        if (address(baseAsset_) == address(quoteAsset_)) revert SameAsset();

        baseAsset = baseAsset_;
        quoteAsset = quoteAsset_;

        _onTradingAssetsSet();
    }

    function _checkEmergencyWithdraw() internal view {
        if (emergencyWithdrawDisabled) revert FeatureDisabled();
        if (block.timestamp <= emergencyWithdrawDisableScheduledAt) revert FeatureDelay();
    }

    function _onTradingAssetsSet() internal virtual {}

    function _authorizeUpgrade(address newImplementation) internal view override {
        _onlyOwner();
        newImplementation;
        if (upgradesDisabled) revert FeatureDisabled();
        if (block.timestamp <= upgradesDisableScheduledAt) revert FeatureDelay();
    }
}
