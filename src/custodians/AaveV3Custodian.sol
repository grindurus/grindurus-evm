// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Custodian} from "../Custodian.sol";
import {IGRAI} from "../interfaces/IGRAI.sol";

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken {
    function POOL() external view returns (address);

    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/// @title AaveV3Custodian (implementation)
/// @notice Single-reserve Aave V3 sleeve: `quoteAsset` = underlying, `baseAsset` = aToken.
///
/// ## Purpose
/// 1. **Earn Aave supply yield** on one underlying — owner `supply`s idle quote into the Pool;
///    aTokens (base) accrue on this contract.
/// 2. **Protect inventory from owner theft** — exits only via Grinders `deallocate` / `distribute` /
///    `liquidate`. Owner `withdraw` always credits this contract.
///
/// ## Assets
/// `setAssets(aToken, underlying)`:
/// - `baseAsset` = aToken (e.g. aUSDC)
/// - `quoteAsset` = underlying (e.g. USDC)
/// Requires `IAToken(base).UNDERLYING_ASSET_ADDRESS() == quote`.
/// Pool is read from `IAToken(base).POOL()`.
///
/// Mint via Grinders: `mint(aave_v3, owner, aUSDC, USDC)`.
///
/// ## Flow
/// - GRAI `allocate` quote → idle underlying
/// - Owner `supply(amount)` → aTokens to this contract
/// - Owner `withdraw(amount)` → underlying back to idle
/// - Grinders exits of quote auto-redeem aTokens via `_send`
contract AaveV3Custodian is Custodian {
    using SafeERC20 for IERC20;

    error PoolZero();
    error ATokenMissing();
    error ATokenMismatch();
    error InsufficientIdle();

    function initialize(address grinders_) public override initializer {
        __Custodian_init(grinders_);
    }

    /// @inheritdoc Custodian
    function custodianKind() public pure override returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256("grindurus.custodian.aave_v3");
    }

    /// @notice Aave V3 Pool proxy from the bound aToken (`IAToken(baseAsset).POOL()`).
    function pool() public view returns (IAaveV3Pool) {
        if (baseAsset == address(0)) revert ATokenMissing();
        address pool_ = IAToken(baseAsset).POOL();
        if (pool_ == address(0)) revert PoolZero();
        return IAaveV3Pool(pool_);
    }

    /// @notice Bind sleeve: `baseAsset_` = aToken, `quoteAsset_` = its underlying.
    /// @dev Reverts unless `IAToken(baseAsset_).UNDERLYING_ASSET_ADDRESS() == quoteAsset_`.
    function setAssets(address baseAsset_, address quoteAsset_) public override {
        _onlyGrinders();
        if (_idle(quoteAsset) != 0 || _aTokenBalance() != 0) revert NonZeroBalance();
        if (baseAsset_ == address(0)) revert BaseZero();
        if (quoteAsset_ == address(0)) revert QuoteZero();
        if (baseAsset_ == quoteAsset_) revert SameAsset();

        if (IAToken(baseAsset_).UNDERLYING_ASSET_ADDRESS() != quoteAsset_) revert ATokenMismatch();
        if (IAToken(baseAsset_).POOL() == address(0)) revert PoolZero();

        baseAsset = baseAsset_;
        quoteAsset = quoteAsset_;
        emit SetAssets(baseAsset_, quoteAsset_);
    }

    /// @notice Idle underlying (`quote`) or aToken balance (`base`); ETH unchanged.
    function balance(address asset) public view override returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        if (asset == quoteAsset) return _idle(quoteAsset);
        if (asset == baseAsset) return _aTokenBalance();
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice USD NAV of idle underlying + aToken, priced as the underlying (one exposure).
    function nav() public view override returns (uint256) {
        if (address(grinders).code.length == 0 || quoteAsset == address(0)) return 0;
        try grinders.grai() returns (IGRAI grai) {
            uint256 exposure = _idle(quoteAsset) + _aTokenBalance();
            return grai.usdValue(quoteAsset, exposure);
        } catch {
            return 0;
        }
    }

    /// @notice Supply idle underlying (`quoteAsset`) into Aave; aTokens minted here.
    /// @param amount Underlying amount; `type(uint256).max` = entire idle balance.
    function supply(uint256 amount) public {
        _onlyOwner();
        if (quoteAsset == address(0)) revert QuoteZero();
        if (amount == 0) revert AmountZero();

        uint256 idle = _idle(quoteAsset);
        if (amount == type(uint256).max) amount = idle;
        if (amount == 0) revert AmountZero();
        if (amount > idle) revert InsufficientIdle();

        IAaveV3Pool pool_ = pool();
        IERC20(quoteAsset).forceApprove(address(pool_), amount);
        pool_.supply(quoteAsset, amount, address(this), 0);
        IERC20(quoteAsset).forceApprove(address(pool_), 0);
    }

    /// @notice Redeem aTokens to idle underlying on this contract (not to owner).
    /// @param amount Underlying to withdraw; `type(uint256).max` = full aToken position.
    function withdraw(uint256 amount) public returns (uint256 withdrawn) {
        _onlyOwner();
        if (quoteAsset == address(0)) revert QuoteZero();
        if (amount == 0) revert AmountZero();

        withdrawn = pool().withdraw(quoteAsset, amount, address(this));
    }

    /// @dev For quote (underlying): redeem aTokens if idle is short, then transfer.
    ///      For base (aToken): transfer aTokens as-is.
    function _send(address to, address asset, uint256 amount)
        internal
        override
        returns (uint256 withdrawn)
    {
        if (amount == 0) return 0;
        if (asset == address(0)) return super._send(to, asset, amount);

        if (asset == quoteAsset) {
            uint256 idle = _idle(asset);
            if (idle < amount) {
                uint256 aBal = _aTokenBalance();
                if (aBal > 0) {
                    uint256 need = amount - idle;
                    uint256 redeem = need > aBal ? type(uint256).max : need;
                    pool().withdraw(asset, redeem, address(this));
                }
            }
            idle = _idle(asset);
            uint256 send = amount > idle ? idle : amount;
            return super._send(to, asset, send);
        }

        return super._send(to, asset, amount);
    }

    function _idle(address asset) internal view returns (uint256) {
        if (asset == address(0)) return 0;
        return IERC20(asset).balanceOf(address(this));
    }

    function _aTokenBalance() internal view returns (uint256) {
        if (baseAsset == address(0)) return 0;
        return IERC20(baseAsset).balanceOf(address(this));
    }
}
