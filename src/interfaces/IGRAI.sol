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
    error LiquidationOpen();
    error LiquidationClosed();
    error LiquidationDelay();
    error RedeemPeriodActive();
    error AuctionDurationTooShort();
    error BribeAssetUnset();
    error InvalidCuts();

    struct AssetConfig {
        /// @notice The asset this config belongs to (mirrors the `assets` mapping key).
        address asset;
        /// @notice Index of this asset in `assetList` while listed.
        uint32 id;
        bool paused;
    }

    /// @notice One Dutch auction lot.
    /// @dev `remaining`/`initial` = sold asset quantity; `maxPayment`/`minPayment` = full-lot GRAI ask
    ///      (mint-price max → usually 0 over `duration`).
    struct DutchAuction {
        address asset;
        uint256 remaining;
        uint256 initial;
        /// @notice Full-lot Dutch start: GRAI ask at listing (mint price).
        uint256 maxPayment;
        /// @notice Full-lot Dutch end: GRAI ask after `duration` (usually 0).
        uint256 minPayment;
        uint256 startTime;
        /// @notice Snapshot of `config.auctionDuration` at last `_place`.
        uint32 duration;
    }

    /// @notice Per-user escrow: locked GRAI (dividends) and optional liquidation vote.
    struct Escrow {
        /// @notice The account this escrow belongs to (mirrors the `escrows` mapping key).
        address account;
        /// @notice Index of this account in `accounts` while `amount` is non-zero.
        uint32 accountId;
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
    struct ProtocolConfig {
        /// @notice Share of distributed yield / bribe premium listed for GRAI buyback, in bps.
        uint16 auctionCutBps;
        /// @notice Share of distributed yield / bribe premium paid as lock dividends, in bps.
        uint16 dividendCutBps;
        /// @notice Share of distributed yield / bribe premium sent to `treasury`, in bps.
        uint16 treasuryCutBps;
        /// @notice Settlement premium for a lock buyout, in bps of book value.
        uint16 bribePremiumBps;
        uint16 quorumBps;
        /// @notice Dutch floor as a fraction of `maxPayment` (`minPayment = max * auctionFloorBps / BPS`).
        /// @dev Default 2000 (20%) ⇒ ask decays at most −80% from mint, never free.
        uint16 auctionFloorBps;
        /// @notice Max unlock fee in bps of unlocked GRAI at `lockedAt` (linearly decays to 0).
        uint16 unlockFeeBps;
        /// @notice Dutch auction duration from `maxPayment` to `minPayment`.
        uint32 auctionDuration;
        /// @notice Delay after liquidation opens before `redeem` (claim) is allowed.
        /// @dev Window for keepers to call `Grinders.liquidate`, which pulls all custodian assets into GRAI
        ///      where they sit as idle inventory for the subsequent pro-rata `redeem` basket.
        uint32 liquidationPeriod;
        /// @notice Extra window after `liquidationPeriod` before liquidation can be closed via `resettle`.
        uint32 redeemPeriod;
        /// @notice Unlock fee decay window from `lockedAt` (`unlockFeeBps` → 0).
        uint32 unlockFeeDuration;
    }

    event AssetUpdate(address indexed asset, bool listed);
    event AssetConfigUpdate(address indexed asset, AssetConfig cfg);
    event Deposit(address indexed depositor, uint256 graiOut, address indexed asset, uint256 amount, uint256 value);
    event Distribute(
        address indexed from,
        address indexed asset,
        uint256 yieldAmount,
        uint256 auctionShare,
        uint256 dividendShare,
        uint256 treasuryShare
    );
    event AuctionUpdate(address indexed asset, uint256 remaining, uint256 maxPayment, uint256 startTime);
    event Buyback(address indexed buyer, address indexed asset, uint256 graiIn, uint256 amountOut);
    event Redeem(address indexed account, uint256 graiAmount, uint256 depositValue);
    event Locked(address indexed account, uint256 amount, uint256 totalLocked);
    event Unlock(address indexed account, uint256 amount, uint256 totalLocked);
    event Vote(address indexed account, uint256 amount, uint256 totalVoted);
    event VoteReward(address indexed account, uint256 amount);
    event Dividend(address indexed account, address indexed asset, uint256 amount);
    event Bribe(
        address indexed briber,
        address indexed voter,
        address indexed bribeAsset,
        uint256 graiAmount,
        uint256 bribeAmount,
        uint256 totalVoted
    );
    event Liquidate(bool liquidation);
    event ConfigUpdate(ProtocolConfig config);

    function config()
        external
        view
        returns (
            uint16 auctionCutBps,
            uint16 dividendCutBps,
            uint16 treasuryCutBps,
            uint16 bribePremiumBps,
            uint16 quorumBps,
            uint16 auctionFloorBps,
            uint16 unlockFeeBps,
            uint32 auctionDuration,
            uint32 liquidationPeriod,
            uint32 redeemPeriod,
            uint32 unlockFeeDuration
        );

    function treasury() external view returns (address);

    function totalValue() external view returns (uint256);

    function yieldBy(address custodian, address asset) external view returns (uint256);

    function auctions(address asset)
        external
        view
        returns (
            address asset_,
            uint256 remaining,
            uint256 initial,
            uint256 maxPayment,
            uint256 minPayment,
            uint256 startTime,
            uint32 duration
        );

    /// @notice Listed assets that currently have an open yield auction.
    function getAuctions() external view returns (address[] memory);

    function escrows(address account)
        external
        view
        returns (
            address account_,
            uint32 accountId,
            uint256 amount,
            uint256 voted,
            uint48 lockedAt,
            uint48 votedAt,
            uint32 voterId
        );

    function accounts(uint256 index) external view returns (address);

    function totalLocked() external view returns (uint256);

    function voters(uint256 index) external view returns (address);

    /// @notice Accounts with an open liquidation vote (`voted > 0`).
    function getVoters() external view returns (address[] memory);

    function totalVoted() external view returns (uint256);

    function accDividendShare(address asset) external view returns (uint256);

    function pendingVoteRewards() external view returns (uint256);

    function dividendDebt(address account, address asset) external view returns (uint256);

    function claimableDividend(address account, address asset) external view returns (uint256);

    /// @notice True when voted GRAI is at least `config.quorumBps` of `totalSupply`.
    function hasQuorum() external view returns (bool);

    /// @notice True after `liquidate` opens until `resettle` closes it.
    function liquidation() external view returns (bool);

    /// @notice Timestamp when the current liquidation opened; zero while liquidation is closed.
    function liquidationAt() external view returns (uint48);

    function assets(address asset) external view returns (address asset_, uint32 id, bool paused);

    function assetList(uint256 index) external view returns (address);

    function getAssets() external view returns (address[] memory);

    function setGrinders(address grinders_) external;

    function setTreasury(address treasury_) external;

    function bribeAsset() external view returns (address);

    /// @notice Canonical WETH for ETH→WETH fallback when a native push is rejected.
    function weth() external view returns (IWETH);

    function setBribeAsset(address bribeAsset_) external;

    function setProtocolConfig(ProtocolConfig calldata cfg) external;

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

    /// @notice Fill a Dutch lot: pay GRAI ask, receive `asset`, credit lock (vote) rewards.
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

    /// @notice Accrue residual dividends/rewards and return `graiAmount` from the active lock to the wallet.
    ///         `graiAmount == 0` accrues (and optionally claims) without unlocking.
    ///         Early unlock may take a decaying fee (`unlockFeeBps` → 0 over `unlockFeeDuration` from `lockedAt`);
    ///         the fee stays on GRAI and is credited to voters via the buyback reward index.
    ///         When `claimAll_` is true, also claims all listed-asset yield dividends for the caller.
    function unlock(uint256 graiAmount, bool claimAll_) external;

    /// @notice Preview unlock of `graiAmount` at `timestamp`: `net` GRAI returned to wallet and `fee` credited to voters
    ///         (`fee` is 0 after `unlockFeeDuration` from `lockedAt`; `net = graiAmount - fee`).
    function previewUnlock(address account, uint256 graiAmount, uint256 timestamp)
        external
        view
        returns (uint256 net, uint256 fee);

    /// @notice Pending yield dividends for `asset` accrued to `holder`'s lock (including unrealized index accrual).
    function previewClaim(address holder, address asset) external view returns (uint256 amount);

    /// @notice Pending yield dividends for every listed asset accrued to `holder`'s lock.
    ///         Parallel arrays in `assetList` order (amount may be 0).
    function previewClaimAll(address holder)
        external
        view
        returns (address[] memory assetOuts, uint256[] memory amounts);

    /// @notice Claim yield dividends for `asset` accrued to `holder`'s active lock; paid to `holder`.
    function claim(address holder, address asset) external returns (uint256 amount);

    /// @notice Claim yield dividends for every listed asset accrued to `holder`'s lock; paid to `holder`.
    function claimAll(address holder) external;

    /// @notice Preview the `bribeAsset` payment to buy out a voter's voted GRAI.
    function previewBribe(address voter, uint256 graiAmount) external view returns (uint256 bribeAmount);

    /// @notice Anyone may buy out `voter`'s vote for `previewBribe`: book to voter, premium to
    ///         treasury/dividends/auction; briber receives the escrowed GRAI.
    function bribe(address voter, uint256 graiAmount) external payable;

    /// @notice Open liquidation (requires quorum): pauses all assets and cancels open yield auctions
    ///         into the redeem basket. Unredeemed shares retain their book value.
    function liquidate() external;

    /// @notice Permissionless close after `liquidationPeriod + redeemPeriod`: leftover balances →
    ///         Grinders, unpause assets, reset `totalValue` to leftover NAV so the fund can restart.
    function resettle() external;
}
