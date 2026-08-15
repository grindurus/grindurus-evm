// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IGrinders} from "./interfaces/IGrinders.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";
import {ICustodian} from "./interfaces/ICustodian.sol";

/// @title Custodian (base implementation)
/// @notice Shared junior-capital custody: holds assets and routes principal/yield back to Grinders.
/// @dev Grinder ownership is recorded on Grinders (`IGrinders.ownerOf(custodianId)`).
abstract contract Custodian is Initializable, UUPSUpgradeable, ICustodian {
    using SafeERC20 for IERC20;

    /// @notice Parent Grinders registry / NFT issuer that minted this custodian.
    IGrinders public grinders;
    
    /// @notice Primary trading asset for this sleeve (ERC20; set via `setAssets`).
    address public baseAsset;
    
    /// @notice Secondary trading asset for this sleeve (ERC20; set via `setAssets`).
    address public quoteAsset;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(address grinders_) public virtual initializer {
        __Custodian_init(grinders_);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __Custodian_init(address grinders_) internal onlyInitializing {
        if (grinders_ == address(0)) revert GrindersZero();

        __UUPSUpgradeable_init();

        grinders = IGrinders(grinders_);
    }

    function custodianId() public view returns (uint256) {
        if (address(grinders).code.length == 0) return type(uint256).max;
        try grinders.custodianIdOf(address(this)) returns (uint256 id) {
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
    ///      incompatible families). Proxies are not UUPS-upgradeable; a new kind + `Grinders.set`
    ///      only changes the impl used by future `mint`. Bump the string when storage/API breaks.
    ///      Off-chain code can read `ERC1967Utils.getImplementation(proxy)` for the exact bytecode.
    function custodianKind() public view virtual returns (bytes32);

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice USD NAV of `baseAsset` and `quoteAsset` balances (6 decimals).
    /// @dev Returns 0 if grinders/GRAI is missing or price lookups fail.
    function nav() public view virtual returns (uint256) {
        if (address(grinders).code.length == 0) return 0;
        try grinders.grai() returns (IGRAI grai) {
            uint256 baseAssetValue = grai.usdValue(baseAsset, balance(baseAsset));
            uint256 quoteAssetValue = grai.usdValue(quoteAsset, balance(quoteAsset));
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

    //////////////////// ONLY GRINDERS ////////////////////

    function setAssets(address baseAsset_, address quoteAsset_) public virtual {
        _onlyGrinders();
        if (balance(baseAsset) != 0 || balance(quoteAsset) != 0) revert NonZeroBalance();
        if (baseAsset_ == address(0)) revert BaseZero();
        if (quoteAsset_ == address(0)) revert QuoteZero();
        if (baseAsset_ == quoteAsset_) revert SameAsset();

        baseAsset = baseAsset_;
        quoteAsset = quoteAsset_;
        emit SetAssets(baseAsset_, quoteAsset_);
    }

    /// @notice Return inventory to Grinders. Not capped by prior allocations (custodian may hold swapped assets).
    function deallocate(address asset, uint256 amount) public virtual {
        _onlyGrinders();
        if (liquidation()) revert LiquidationOpen();
        _withdraw(address(grinders), asset, amount);
        emit Deallocate(asset, amount);
    }

    /// @notice Forward reported yield to GRAI for treasury sharing and auctioning.
    /// @dev Intentionally not capped by prior allocations: custodians may swap principal between assets,
    ///      so a reliable on-chain `balance - allocated` profit check is complex. Track Grinders
    ///      `Allocate` / `Deallocate` events off-chain for issuance accounting.
    function distribute(address asset, uint256 yieldAmount) public virtual {
        _onlyGrinders();
        if (liquidation()) revert LiquidationOpen();

        try grinders.grai() returns (IGRAI grai) {
            if (asset == address(0)) {
                try grai.distribute{value: yieldAmount}(asset, yieldAmount) {}
                catch {
                    _withdraw(address(grai), asset, yieldAmount);
                }
            } else {
                IERC20(asset).forceApprove(address(grai), yieldAmount);
                try grai.distribute(asset, yieldAmount) {}
                catch {
                    IERC20(asset).forceApprove(address(grai), 0);
                    _withdraw(address(grai), asset, yieldAmount);
                }
            }
        } catch {
            _withdraw(address(grinders), asset, yieldAmount);
        }
        emit Distribute(asset, yieldAmount);
    }

    /// @notice Liquidation pull of ETH / base / quote to Grinders (only Grinders).
    /// @dev Also returns `baseAsset` / `quoteAsset` so Grinders need not re-read them.
    function liquidate() public virtual returns (
        address baseAssetOut,
        address quoteAssetOut,
        uint256 baseOut,
        uint256 quoteOut,
        uint256 ethOut
    ) {
        _onlyGrinders();
        baseAssetOut = baseAsset;
        quoteAssetOut = quoteAsset;
        ethOut = _withdraw(address(grinders), address(0), balance(address(0)));
        baseOut = _withdraw(address(grinders), baseAssetOut, balance(baseAssetOut));
        quoteOut = _withdraw(address(grinders), quoteAssetOut, balance(quoteAssetOut));
        emit Liquidate(ethOut, baseOut, quoteOut);
    }

    //////////////////// ONLY OWNER ////////////////////

    function _onlyOwner() internal view {
        if (msg.sender != owner()) revert NotOwner(msg.sender);
    }

    function _onlyGrinders() internal view {
        if (msg.sender != address(grinders)) revert NotGrinders(msg.sender);
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

    /// @dev Proxies are ERC1967 for `Grinders.mint`; implementation swaps are permanently disabled.
    function _authorizeUpgrade(address) internal pure override {
        revert FeatureDisabled();
    }
}
