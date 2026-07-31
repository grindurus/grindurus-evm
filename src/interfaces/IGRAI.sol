// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1046} from "./IERC1046.sol";
import {IPriceOracleRouter} from "./IPriceOracleRouter.sol";
import {IWETH} from "./IWETH.sol";

interface IGRAI is IERC20, IERC20Metadata, IERC1046, IPriceOracleRouter {
    error AssetUnknown();
    error AssetBalanceNonZero();
    error BpsTooHigh();
    error NotPaused();
    error Paused();
    error AuctionNotFound();
    error ZeroAddress();
    error AmountZero();
    /// @notice An amount/limit is out of range (exceeds balance/allowance/supply, min>max, payment bounds).
    error InvalidAmount();
    error EthTransferFailed();
    error GrindersGraiMismatch();
    error ValueMismatch();
    error UnexpectedValue();
    error LiquidationQuorumNotMet();
    error LiquidationNotConfirmed();
    error LiquidationOpen();
    error LiquidationClosed();
    error LiquidationDelay();
    error RedeemPeriodActive();
    error BuybackPeriodTooShort();
    error PeriodZero();
    error BribeAssetUnset();
    error InvalidCuts();
    /// @notice Deposit book is zero while shares remain (bootstrap mint would tax new capital).
    error InsolventBook();
    error InvalidVoterRange(uint256 fromId, uint256 toId);
    error InvalidLockerRange(uint256 fromId, uint256 toId);

    struct AssetConfig {
        /// @notice The asset this config belongs to (mirrors the `assets` mapping key).
        address asset;
        /// @notice Index of this asset in `assetList` while listed.
        uint32 id;
        /// @notice When true, blocks `deposit` for this asset only (not buyback / distribute / claim).
        bool paused;
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

    /// @notice Per-asset locker dividend index and reserved inventory.
    struct TotalPosition {
        /// @notice Cumulative yield of `asset` per unvoted locked GRAI (`amount - voted`), scaled by 1e18.
        uint256 accShare;
        /// @notice Tokens reserved for locker claims (excluded from redeem / resettle).
        uint256 totalClaimable;
    }

    /// @notice Per-user escrow: locked GRAI (dividends) and optional liquidation vote.
    struct Escrow {
        /// @notice The account this escrow belongs to (mirrors the `escrows` mapping key).
        address account;
        /// @notice Index of this account in `lockers` while `amount` is non-zero.
        uint32 lockerId;
        /// @notice Actively locked GRAI (dividend share; max voting capacity).
        uint256 amount;
        /// @notice GRAI counted toward liquidation quorum (≤ `amount`).
        uint256 voted;
        /// @notice Timestamp of the latest `lock`.
        uint48 lockedAt;
        /// @notice Timestamp of the latest `vote`.
        uint48 votedAt;
        /// @notice Index of this account in `voters` while `voted` is non-zero.
        uint32 voterId;
    }

    /// @notice Yield split, bribe premium, liquidation quorum, unlock fee, and timing.
    struct Config {
        /// @notice Share of distributed yield / bribe premium listed for GRAI buyback, in bps.
        uint16 buybackCutBps;
        /// @notice Share of distributed yield / bribe premium paid as dividends on unvoted locked GRAI, in bps.
        uint16 dividendCutBps;
        /// @notice Share of distributed yield / bribe premium sent to `treasury`, in bps.
        uint16 treasuryCutBps;
        /// @notice Slope scale for dynamic bribe ask adj, in bps of book value per half-quorum of
        ///         vote-share (also Dutch buyback max discount).
        /// @dev Ask scales linearly with vote-share vs half-quorum: `|adj| = bribePremiumBps` at 0
        ///      votes and at quorum; par at half quorum; above quorum discount `adj` may exceed
        ///      `bribePremiumBps` (uncapped until `adj ≥ BPS`). Premium splits half the premium to
        ///      cuts; discount applies half the gap to the ask and carves the other half to cuts;
        ///      par pays the full ask to the voter.
        uint16 bribePremiumBps;
        uint16 quorumBps;
        /// @notice Max unlock fee in bps of unlocked GRAI at `lockedAt` (linearly decays to 0).
        uint16 unlockFeeBps;
        /// @notice Buyback Dutch duration from `maxPayment` to `minPayment`.
        /// @dev `minPayment = maxPayment * (BPS - bribePremiumBps) / BPS` (max discount = premium).
        uint32 buybackPeriod;
        /// @notice Delay after liquidation opens before `redeem` (claim) is allowed.
        /// @dev Window for keepers to call `Grinders.liquidate`, which pulls all custodian assets into GRAI
        ///      where they sit as idle inventory for the subsequent pro-rata `redeem` basket.
        uint32 liquidationPeriod;
        /// @notice Extra window after `liquidationPeriod` before liquidation can be closed via `resettle`.
        uint32 redeemPeriod;
        /// @notice Unlock penalty decay window from `lockedAt` (`unlockFeeBps` → 0).
        uint32 unlockPenaltyPeriod;
    }

    event AssetUpdate(address indexed asset, bool listed);
    event AssetConfigUpdate(address indexed asset, AssetConfig cfg);
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
        address indexed bribeAsset,
        uint256 graiAmount,
        uint256 bribeAmount,
        uint256 totalVoted
    );
    event Liquidate(bool liquidation);
    event ConfigUpdate(Config config);

    function config()
        external
        view
        returns (
            uint16 buybackCutBps,
            uint16 dividendCutBps,
            uint16 treasuryCutBps,
            uint16 bribePremiumBps,
            uint16 quorumBps,
            uint16 unlockFeeBps,
            uint32 buybackPeriod,
            uint32 liquidationPeriod,
            uint32 redeemPeriod,
            uint32 unlockPenaltyPeriod
        );

    function treasury() external view returns (address);

    function totalValue() external view returns (uint256);

    function positions(address account, address asset)
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

    function escrows(address account)
        external
        view
        returns (
            address account_,
            uint32 lockerId,
            uint256 amount,
            uint256 voted,
            uint48 lockedAt,
            uint48 votedAt,
            uint32 voterId
        );

    function lockers(uint256 index) external view returns (address);

    /// @notice Accounts with a non-zero lock escrow in `[fromId, toId)`.
    function getLockers(uint256 fromId, uint256 toId) external view returns (Escrow[] memory escrowList);

    function totalLocked() external view returns (uint256);

    function voters(uint256 index) external view returns (address);

    /// @notice Accounts with an open liquidation vote (`voted > 0`) in `[fromId, toId)`.
    function getVoters(uint256 fromId, uint256 toId) external view returns (Escrow[] memory escrowList);

    /// @notice Redeem / resettle basket in `assetList` order: every listed asset and its
    ///         `_redeemable` balance (contract balance minus `totalClaimable`; may be 0).
    ///         Reverts with `LiquidationClosed` when liquidation is not open.
    function getRedeemables() external view returns (address[] memory assetOuts, uint256[] memory amounts);

    function totalVoted() external view returns (uint256);

    function totalPositions(address asset) external view returns (uint256 accShare, uint256 totalClaimable);

    /// @notice True when voted GRAI is at least `config.quorumBps` of `totalSupply`.
    function hasQuorum() external view returns (bool);

    /// @notice Owner confirmation for non-owner liquidation open. Owner toggles via `liquidate` when no quorum; cleared on open.
    function confirmed() external view returns (bool);

    /// @notice True after `liquidate` opens until `resettle` closes it.
    function liquidation() external view returns (bool);

    /// @notice Timestamp when the current liquidation opened; zero while liquidation is closed.
    function liquidationAt() external view returns (uint48);

    function assets(address asset) external view returns (address asset_, uint32 id, bool paused);

    function assetList(uint256 index) external view returns (address);

    function setGrinders(address grinders_) external;

    function setTreasury(address treasury_) external;

    function bribeAsset() external view returns (address);

    /// @notice Canonical WETH for ETH→WETH fallback when a native push is rejected.
    function weth() external view returns (IWETH);

    /// @notice Set bribe settlement asset (listed feed). Must not be fee-on-transfer.
    function setBribeAsset(address bribeAsset_) external;

    /// @notice List (`feedType != 0`) or delist (`feedType == 0`, `cfg` ignored) an asset.
    function set(address asset, Feed calldata feed, AssetConfig calldata cfg) external;

    function setConfig(Config calldata cfg) external;

    function previewDeposit(address asset, uint256 amount) external view returns (uint256 value, uint256 graiOut);

    /// @notice Dutch GRAI in and asset out (capped to auction remaining) at `timestamp`.
    function previewBuyback(address asset, uint256 amount, uint256 timestamp)
        external
        view
        returns (uint256 graiIn, uint256 amountOut);

    function setAssetConfig(address asset, AssetConfig calldata cfg) external;

    /// @notice Mint GRAI against deposited `asset`. If `lock`, escrow the minted `graiOut` for dividends in the same tx.
    function deposit(address asset, uint256 amount, bool lock)
        external
        payable
        returns (uint256 graiOut, uint256 depositValue);

    /// @notice Fill a Dutch lot: pay GRAI ask, receive `asset`; `graiIn` is locked+voted on the buyer.
    ///         Reverts if `graiIn == 0` or `amountOut == 0` (no free / zero fills).
    function buyback(address asset, uint256 amount) external;

    function distribute(address asset, uint256 yieldAmount) external payable;

    /// @notice Pro-rata asset amounts paid for burning wallet-held and/or locked GRAI.
    function previewRedeem(address holder, uint256 graiAmount)
        external
        view
        returns (address[] memory assetOuts, uint256[] memory amounts);

    /// @notice Burn wallet-held and/or locked GRAI for a pro-rata share of the liquidation basket.
    function redeem(uint256 graiAmount) external;

    /// @notice Escrow wallet GRAI for dividend eligibility (optional if only voting — `vote` auto-locks).
    ///         Exit unvoted lock via `unlock`; voted GRAI exits via `bribe` or unlock (clamps vote).
    function lock(uint256 graiAmount) external;

    /// @notice Commit GRAI toward liquidation quorum. No prior `lock` required: locks any wallet
    ///         shortfall first so `voted + graiAmount` ends ≤ locked `amount`.
    function vote(uint256 graiAmount) external;

    /// @notice Accrue residual dividends and return `graiAmount` from the active lock to the wallet.
    ///         Early unlock may take a decaying penalty (`unlockFeeBps` → 0 over `unlockPenaltyPeriod` from `lockedAt`);
    ///         the penalty GRAI is sent to `treasury`.
    ///         While live fee > 0, partial unlocks below `ceil(BPS / penaltyBps)` revert (blocks fee-floor dust chunks);
    ///         unlocking the full remaining escrow is always allowed.
    ///         Yield dividends are claimed separately via `claim` / `claimAll`.
    function unlock(uint256 graiAmount) external;

    /// @notice Preview unlock of `graiAmount` at `timestamp`: `unlockAmount` GRAI returned to wallet and `penalty` to treasury
    ///         (`penalty` is 0 after `unlockPenaltyPeriod` from `lockedAt`; `unlockAmount = graiAmount - penalty`).
    ///         While live fee > 0, reverts on partial unlocks below `ceil(BPS / penaltyBps)` (same rule as `unlock`).
    function previewUnlock(address account, uint256 graiAmount, uint256 timestamp)
        external
        view
        returns (uint256 unlockAmount, uint256 penalty);

    /// @notice Preview yield dividends claimable for `asset`: `type(uint256).max` = full pending,
    ///         otherwise `min(amount, pending)` (including unrealized index accrual).
    function previewClaim(address holder, address asset, uint256 amount) external view returns (uint256);

    /// @notice Pending yield dividends for every listed asset accrued to `holder`'s lock.
    ///         Parallel arrays in `assetList` order (amount may be 0).
    function previewClaimAll(address holder)
        external
        view
        returns (address[] memory assetOuts, uint256[] memory amounts);

    /// @notice Claim yield dividends for `asset` accrued to `holder`'s active lock; paid to `holder`.
    ///         `type(uint256).max` claims the full accrued balance; otherwise `min(amount, claimable)`.
    function claim(address holder, address asset, uint256 amount) external returns (uint256 claimed);

    /// @notice Claim yield dividends for every listed asset accrued to `holder`'s lock; paid to `holder`.
    function claimAll(address holder) external;

    /// @notice Preview bribe ask in `bribeAsset`: `bribeAmount`, plus absolute `premium` or `discount`
    ///         vs book (one is always 0). `premium > 0` ⇒ scarce votes (favor voting); `discount > 0`
    ///         ⇒ excess votes (favor bribing). Discount is half the full book−ask gap; ask = book − discount.
    function previewBribe(address voter, uint256 graiAmount)
        external
        view
        returns (uint256 bribeAmount, uint256 premium, uint256 discount);

    /// @notice Anyone may buy out `voter`'s vote for `previewBribe`. Ask is book scaled by a dynamic
    ///         adj vs half-quorum (premium / par / discount; slope `bribePremiumBps`, uncapped above
    ///         quorum on the discount leg). `bribeAsset` must not be fee-on-transfer: payment must
    ///         credit exactly `bribeAmount`; briber receives the full escrowed `graiAmount`.
    ///         Premium: voter gets book + half the premium, rest → cuts. Discount: ask is book −
    ///         half gap; the other half → cuts. Par: voter gets the full credited pull.
    function bribe(address voter, uint256 graiAmount) external payable;

    /// @notice Liquidation 2-of-2: owner toggles `confirmed` if no quorum, else opens;
    ///         anyone else opens when `confirmed && hasQuorum()`, otherwise reverts.
    function liquidate() external;

    /// @notice Permissionless close after `liquidationPeriod + redeemPeriod`: leftover balances →
    ///         Grinders; force-unpause all listed assets (intentional restart business logic — does
    ///         not restore pre-liquidation pauses); reset `totalValue` to leftover NAV so the fund
    ///         can restart.
    function resettle() external;
}
