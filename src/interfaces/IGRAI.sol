// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1046} from "./IERC1046.sol";
import {IPriceOracleRouter} from "./IPriceOracleRouter.sol";
import {ITreasury} from "./ITreasury.sol";
import {IWETH} from "./IWETH.sol";

interface IGRAI is IERC20, IERC20Metadata, IERC1046, IPriceOracleRouter {
    error AssetUnknown();
    error AssetNotEmpty();
    error BpsTooHigh();
    error NotPaused();
    error Paused();
    error AuctionNotFound();
    error ZeroAddress();
    /// @notice Amount is zero or otherwise out of range (balance/allowance/supply, min>max, payment bounds).
    error InvalidAmount();
    /// @notice Referrer NFT poach: caller already owns the slot.
    error AlreadyBound();
    error EthTransferFailed();
    error GraiMismatch();
    error ValueMismatch();
    error LiquidationNotReady();
    error LiquidationOpen();
    error LiquidationClosed();
    error LiquidationDelay();
    error RedeemPeriodActive();
    error InvalidPeriod();
    error InvalidCuts();
    error InvalidRange(uint256 fromId, uint256 toId);
    /// @notice `renounceOwnership` is disabled — owner is required for 2-of-2 liquidation consent.
    error OwnershipRenounceDisabled();
    /// @notice Field selector for `setConfig`.
    /// @dev Yield cuts (`buybackCutBps` / `dividendCutBps` / `treasuryCutBps`) are fixed at
    ///      `initialize` and cannot be changed via `setConfig`. Still blocked while liquidation is open.
    enum ConfigId {
        REVENUE_SHARE,
        CLAIM_TIP,
        BRIBE_PREMIUM,
        QUORUM,
        UNLOCK_PENALTY,
        BUYBACK_PERIOD,
        LIQUIDATION_PERIOD,
        REDEEM_PERIOD
    }

    struct AssetConfig {
        /// @notice The asset this config belongs to (mirrors the `assets` mapping key).
        address asset;
        /// @notice Index of this asset in `assetList` while listed.
        uint32 id;
        /// @notice Cumulative yield of `asset` per unvoted locked GRAI (`locked - voted`), scaled by 1e18.
        uint256 accShare;
        /// @notice Tokens reserved for locker claims (excluded from redeem / resettle).
        uint256 totalClaimable;
    }

    /// @notice One Dutch auction lot.
    /// @dev `remaining`/`initial` = sold asset quantity; `maxPayment`/`minPayment` = full-lot GRAI ask
    ///      (mint-price max → floor over `period`). Unit USD/GRAI ask = `maxPayment * 10**decimals / initial`.
    struct DutchAuction {
        address asset;
        uint48 startTime;
        /// @notice Snapshot of `config.buybackPeriod` at last `_place`.
        uint32 period;
        uint256 remaining;
        uint256 initial;
        /// @notice Full-lot Dutch start: GRAI ask at listing (mint price).
        uint256 maxPayment;
        /// @notice Full-lot Dutch end: GRAI ask after `period` (floor at `BPS - bribePremiumBps`).
        uint256 minPayment;
    }

    /// @notice Per-account, per-asset ledger: locker dividends (`debt`/`claimable`), custodian yield (`yielded`).
    struct Position {
        uint256 debt;
        uint256 claimable;
        uint256 yielded;
    }

    /// @notice Per-user escrow: locked GRAI (dividends) and optional liquidation vote.
    /// @dev Survives full unlock (`locked == 0`): `_removeLocker` only drops the `lockers` index.
    ///      Active locker ⟺ `locked > 0` (and present in `lockers`). Sticky referrer lives on Treasury.
    struct Escrow {
        /// @notice The account this escrow belongs to (mirrors the `escrows` mapping key).
        address account;
        /// @notice Index of this account in `lockers` while `locked` is non-zero.
        uint32 lockerId;
        /// @notice Timestamp of the latest `lock`.
        uint48 lockedAt;
        /// @notice Actively locked GRAI (dividend share; max voting capacity).
        uint256 locked;
        /// @notice GRAI counted toward liquidation quorum (≤ `locked`).
        uint256 voted;
        /// @notice Index of this account in `voters` while `voted` is non-zero.
        uint32 voterId;
        /// @notice Timestamp of the latest `vote`.
        uint48 votedAt;
    }

    /// @notice Yield split, bribe premium, liquidation quorum, unlock fee, and timing.
    struct Config {
        /// @notice Share of distributed yield / bribe premium listed for GRAI buyback, in bps.
        uint16 buybackCutBps;
        /// @notice Share of distributed yield / bribe premium paid as dividends on unvoted locked GRAI, in bps.
        uint16 dividendCutBps;
        /// @notice Share of distributed yield / bribe premium sent to `treasury`, in bps.
        uint16 treasuryCutBps;
        /// @notice Slice of treasury yield income paid to referrers on `claim` (bps of yield, ≤ `treasuryCutBps`).
        /// @dev On claim: `revenueShare = claimed * revenueShareBps / dividendCutBps` → referrers;
        ///      `grossProfitShare - allocated` → `Treasury.beneficiar` as `netProfitShare`
        ///      (`grossProfitShare = claimed * treasuryCutBps / dividendCutBps`).
        uint16 revenueShareBps;
        /// @notice Share of each `claim` paid to the caller as a tip, in bps of claimed amount (max 20%).
        uint16 claimTipBps;
        /// @notice Slope scale for dynamic bribe ask adj, in bps of book value per half-quorum of
        ///         vote-share (also Dutch buyback max discount).
        /// @dev Ask scales linearly with vote-share vs half-quorum: `|adj| = bribePremiumBps` at 0
        ///      votes and at quorum; par at half quorum; above quorum discount `adj` may exceed
        ///      `bribePremiumBps` (uncapped until `adj ≥ BPS`). Premium splits half the premium to
        ///      cuts; discount applies half the gap to the ask and carves the other half to cuts;
        ///      par pays the full ask to the voter.
        uint16 bribePremiumBps;
        uint16 quorumBps;
        /// @notice Flat unlock penalty in bps of unlocked GRAI (every unlock; no time decay).
        uint16 unlockPenaltyBps;
        /// @notice Buyback Dutch duration from `maxPayment` to `minPayment`.
        /// @dev `minPayment = maxPayment * (BPS - bribePremiumBps) / BPS` (max discount = premium).
        uint32 buybackPeriod;
        /// @notice Delay after liquidation opens before `redeem` (claim) is allowed.
        /// @dev Window for keepers to call `Grinders.liquidate`, which pulls all custodian assets into GRAI
        ///      where they sit as idle inventory for the subsequent pro-rata `redeem` basket.
        uint32 liquidationPeriod;
        /// @notice Extra window after `liquidationPeriod` before liquidation can be closed via `resettle`.
        uint32 redeemPeriod;
    }

    event AssetUpdate(address indexed asset, bool listed);
    event Deposit(address indexed depositor, uint256 graiOut, address indexed asset, uint256 amount, uint256 value);
    event Distribute(
        address indexed from,
        address indexed asset,
        uint256 yieldAmount,
        uint256 buybackShare,
        uint256 dividendShare,
        uint256 treasuryShare
    );
    event AuctionUpdate(address indexed asset, uint256 remaining, uint256 maxPayment, uint256 startTime);
    event Buyback(address indexed buyer, address indexed asset, uint256 graiIn, uint256 amountOut);
    event Redeem(address indexed account, uint256 graiAmount, uint256 depositValue);
    event Lock(address indexed account, uint256 amount, uint256 totalLocked);
    event Unlock(address indexed account, uint256 amount, uint256 totalLocked);
    event Vote(address indexed account, uint256 amount, uint256 totalVoted);
    event Claim(address indexed account, address indexed asset, uint256 amount);
    event Bribe(
        address indexed briber,
        address indexed voter,
        address indexed settlementAsset,
        uint256 graiAmount,
        uint256 bribeAmount,
        uint256 totalVoted
    );
    event Liquidate(bool liquidation);
    event Poach(address indexed buyer, address indexed locker, uint256 price);
    function config()
        external
        view
        returns (
            uint16 buybackCutBps,
            uint16 dividendCutBps,
            uint16 treasuryCutBps,
            uint16 revenueShareBps,
            uint16 claimTipBps,
            uint16 bribePremiumBps,
            uint16 quorumBps,
            uint16 unlockPenaltyBps,
            uint32 buybackPeriod,
            uint32 liquidationPeriod,
            uint32 redeemPeriod
        );

    function treasury() external view returns (ITreasury);

    /// @notice Protocol fee recipient on the linked `Treasury` (`treasury.beneficiar()`).
    function beneficiar() external view returns (address);

    function owner() external view returns (address);

    function totalValue() external view returns (uint256);

    function positions(address locker, address asset)
        external
        view
        returns (uint256 debt, uint256 claimable, uint256 yielded);

    function auctions(address asset)
        external
        view
        returns (
            address asset_,
            uint48 startTime,
            uint32 period,
            uint256 remaining,
            uint256 initial,
            uint256 maxPayment,
            uint256 minPayment
        );

    /// @notice Listed assets in `assetList` order.
    /// @dev One `DutchAuction` per listed asset; `startTime == 0` means no open auction (`asset` is still set).
    function getAssets() external view returns (DutchAuction[] memory list);

    function escrows(address locker)
        external
        view
        returns (
            address account,
            uint32 lockerId,
            uint48 lockedAt,
            uint256 locked,
            uint256 voted,
            uint32 voterId,
            uint48 votedAt
        );

    function lockers(uint256 index) external view returns (address);

    /// @notice Escrows for `lockers` (`voters_ == false`) or `voters` (`true`) in `[fromId, toId)`.
    function getEscrows(bool voters_, uint256 fromId, uint256 toId)
        external
        view
        returns (Escrow[] memory escrowList);

    function totalLocked() external view returns (uint256);

    function voters(uint256 index) external view returns (address);

    /// @notice Redeem / resettle basket in `assetList` order: every listed asset and its
    ///         `_redeemable` balance (contract balance minus `totalClaimable`; may be 0).
    ///         Reverts with `LiquidationClosed` when liquidation is not open.
    function getRedeemables() external view returns (address[] memory assetOuts, uint256[] memory amounts);

    function totalVoted() external view returns (uint256);

    /// @notice True when voted GRAI is strictly above `config.quorumBps` of `totalSupply`
    ///         (`totalVoted * BPS > totalSupply * quorumBps`). Exact equality is not enough.
    function hasQuorum() external view returns (bool);

    /// @notice Owner confirmation for non-owner liquidation open. Owner toggles via `liquidate` when no quorum; cleared on open.
    function confirmed() external view returns (bool);

    /// @notice True after `liquidate` opens until `resettle` closes it.
    function liquidation() external view returns (bool);

    /// @notice Timestamp when the current liquidation opened; zero while liquidation is closed.
    function liquidationAt() external view returns (uint48);

    function assets(address asset)
        external
        view
        returns (address asset_, uint32 id, uint256 accShare, uint256 totalClaimable);

    function assetList(uint256 index) external view returns (address);

    function setGrinders(address grinders_) external;

    /// @notice Retarget the fee sink. Reverts while liquidation is open.
    function setTreasury(address treasury_) external;

    function settlementAsset() external view returns (address);

    /// @notice Canonical WETH for ETH→WETH fallback when a native push is rejected.
    function weth() external view returns (IWETH);

    /// @notice Set bribe settlement asset (listed feed). Must not be fee-on-transfer.
    function setSettlementAsset(address settlementAsset_) external;

    function setConfig(ConfigId id, uint256 data) external;

    function previewDeposit(address asset, uint256 amount) external view returns (uint256 value, uint256 graiOut);

    /// @notice Dutch GRAI in and asset out (capped to auction remaining) at `timestamp`.
    function previewBuyback(address asset, uint256 amount, uint256 timestamp)
        external
        view
        returns (uint256 graiIn, uint256 amountOut);

    /// @notice Mint GRAI against deposited `asset`. If `lock`, escrow the minted `graiOut` for
    ///         dividends in the same tx. Sticky affiliate bind via `referrer` (once; `address(0)` → self).
    function deposit(address asset, uint256 amount, bool lock, address referrer)
        external
        payable
        returns (uint256 graiOut, uint256 depositValue);

    /// @notice Fill a Dutch lot: pay GRAI ask, receive `asset`; `graiIn` is locked+voted on the buyer.
    ///         Reverts if `graiIn == 0` or `amountOut == 0` (no free fills). Partial fills
    ///         ceil-pay the pro-rata Dutch ask so chunked underpay cannot clear below ask.
    function buyback(address asset, uint256 amount) external;

    function distribute(address asset, uint256 yieldAmount) external payable;

    /// @notice Pro-rata asset amounts paid for burning wallet-held and/or locked GRAI.
    ///         Denominator is `totalSupply` (orphan/dead GRAI on this contract dilutes redeemers).
    function previewRedeem(address holder, uint256 graiAmount)
        external
        view
        returns (address[] memory assetOuts, uint256[] memory amounts);

    /// @notice Burn wallet-held and/or locked GRAI for a pro-rata share of the liquidation basket
    ///         (same `totalSupply` denominator as `previewRedeem`).
    function redeem(uint256 graiAmount) external;

    /// @notice Escrow wallet GRAI for dividend eligibility (optional if only voting — `vote` auto-locks).
    ///         Exit unvoted lock via `unlock`; voted GRAI exits via `bribe` or unlock (clamps vote).
    function lock(uint256 graiAmount) external;

    /// @notice Commit GRAI toward liquidation quorum. No prior `lock` required: locks any wallet
    ///         shortfall first so `voted + graiAmount` ends ≤ `locked`.
    function vote(uint256 graiAmount) external;

    /// @notice Accrue residual dividends and return `graiAmount` from the active lock to the wallet.
    ///         Takes a flat unlock fee (`unlockPenaltyBps` of `graiAmount`); the penalty GRAI stays on
    ///         GRAI as orphan/dead for the next `buyback` scavenge (not sent to treasury).
    ///         While fee > 0, unlocks below `ceil(BPS / unlockPenaltyBps)` revert (including full-escrow dust).
    ///         Yield dividends are claimed separately via `claim` / `claimAll`.
    function unlock(uint256 graiAmount) external;

    /// @notice Preview unlock of `graiAmount`: `unlockAmount` GRAI returned to wallet and `penalty` dead
    ///         on GRAI (`penalty = graiAmount * unlockPenaltyBps / BPS`). Reverts if
    ///         `graiAmount > escrows[account].locked`, or while fee > 0 if
    ///         `graiAmount < ceil(BPS / unlockPenaltyBps)` (same rules as `unlock`).
    function previewUnlock(address account, uint256 graiAmount)
        external
        view
        returns (uint256 unlockAmount, uint256 penalty);

    /// @notice Preview yield dividends claimable for `asset`: `type(uint256).max` = full pending,
    ///         otherwise `min(amount, pending)` (including unrealized index accrual).
    function previewClaim(address locker, address asset, uint256 amount) external view returns (uint256);

    /// @notice Pending yield dividends for every listed asset accrued to `locker`'s lock.
    ///         Parallel arrays in `assetList` order (amount may be 0).
    function previewClaimAll(address locker)
        external
        view
        returns (address[] memory assetOuts, uint256[] memory amounts);

    /// @notice Claim yield dividends for `asset` accrued to `locker`'s active lock; pays tip to
    ///         `msg.sender`, remainder to `locker`. Claim-time treasury income is split via
    ///         `treasury.distribute(asset, locker, grossProfitShare, revenueShare)` resolves
    ///         sticky referrers and pays them; remainder (`netProfitShare`) → `beneficiar`.
    ///         `type(uint256).max` claims the full accrued
    ///         balance; otherwise `min(amount, claimable)`.
    function claim(address locker, address asset, uint256 amount) external returns (uint256 claimed);

    /// @notice Claim yield dividends for every listed asset accrued to `locker`'s lock.
    ///         Same tip split as `claim` per asset.
    function claimAll(address locker) external;

    /// @notice Preview bribe ask in `settlementAsset`: `bribeAmount`, plus absolute `premium` or `discount`
    ///         vs book (one is always 0). `premium > 0` ⇒ scarce votes (favor voting); `discount > 0`
    ///         ⇒ excess votes (favor bribing). Discount is half the full book−ask gap; ask = book − discount.
    function previewBribe(address voter, uint256 graiAmount)
        external
        view
        returns (uint256 bribeAmount, uint256 premium, uint256 discount);

    /// @notice Anyone may buy out `voter`'s vote for `previewBribe`. Ask is book scaled by a dynamic
    ///         adj vs half-quorum (premium / par / discount; slope `bribePremiumBps`, uncapped above
    ///         quorum on the discount leg). `settlementAsset` must not be fee-on-transfer: payment must
    ///         credit exactly `bribeAmount`; briber receives the full escrowed `graiAmount`.
    ///         Premium: voter gets book + half the premium, rest → cuts. Discount: ask is book −
    ///         half gap; the other half → cuts. Par: voter gets the full credited pull.
    function bribe(address voter, uint256 graiAmount) external payable;

    /// @notice Liquidation 2-of-2: owner toggles `confirmed` if no quorum, else opens;
    ///         anyone else opens when `confirmed && hasQuorum()`, otherwise reverts.
    ///         On open: orphan/dead GRAI → `msg.sender`; sweep all Grinders custodians + idle
    ///         listed balances onto GRAI.
    function liquidate() external;

    /// @notice Permissionless close after `liquidationPeriod + redeemPeriod`: leftover balances →
    ///         Grinders; clear liquidation flags. Does not reprice `totalValue` from leftover NAV
    ///         (keeps ~$1/GRAI mint); zeroes `totalValue` only when supply is 0.
    function resettle() external;

    /// @notice GRAI cost to poach the sticky referrer link for `locker`: `value + l1Value`.
    ///         Reverts if unbound, `poacher` is already the referrer, `price == 0`, or balance `< price`.
    /// @return price GRAI due to the current sticky referrer.
    /// @return referrer Current sticky upline (receives payment).
    function previewPoach(address locker, address poacher) external view returns (uint256 price, address referrer);

    /// @notice Poach the sticky referrer link for `locker`. Pays `previewPoach` GRAI to the current
    ///         referrer, then `treasury.rebind` (tree only — cashflow NFT ownership unchanged).
    ///         Reverts while liquidation is open.
    function poach(address locker) external;
}
