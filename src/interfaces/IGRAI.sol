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
    error BribeAssetUnset();
    error AuctionDurationTooShort();

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

    struct VoteEscrow {
        /// @notice The account this vote escrow belongs to (mirrors the `votes` mapping key).
        address voter;
        uint256 amount;
        /// @notice Timestamp of the latest `vote` (resets on each vote).
        uint48 votedAt;
        /// @notice Index of this account in `voters` while the vote is open.
        uint32 id;
        /// @notice Reward index already accounted for this position.
        uint256 rewardDebt;
        /// @notice Buyback-funded GRAI accrued but not yet claimed.
        uint256 claimableReward;
    }

    /// @notice Bribe premium, liquidation quorum, treasury cut, and timing.
    struct ProtocolConfig {
        /// @notice Share of distributed yield and bribe premium sent to `treasury`, in bps.
        uint16 treasuryCutBps;
        /// @notice Settlement payment for a vote buyout, in bps of book value.
        uint16 bribePremiumBps;
        uint16 quorumBps;
        /// @notice Dutch auction duration from `maxPayment` to `minPayment`.
        uint32 auctionDuration;
        /// @notice Delay after liquidation opens before `redeem` (claim) is allowed.
        /// @dev Window for keepers to call `Grinders.liquidate`, which pulls all custodian assets into GRAI
        ///      where they sit as idle inventory for the subsequent pro-rata `redeem` basket.
        uint32 liquidationPeriod;
        /// @notice Extra window after `liquidationPeriod` before liquidation can be closed via `resettle`.
        uint32 redeemPeriod;
    }

    event AssetUpdate(address indexed asset, bool listed);
    event AssetConfigUpdate(address indexed asset, AssetConfig cfg);
    event Deposit(address indexed depositor, uint256 graiOut, address indexed asset, uint256 amount, uint256 value);
    event TreasuryUpdate(address indexed treasury);
    event BribeAssetUpdate(address indexed bribeAsset);
    event Distribute(
        address indexed from, address indexed asset, uint256 yieldAmount, uint256 yieldShare, uint256 treasuryShare
    );
    event AuctionUpdate(address indexed asset, uint256 remaining, uint256 maxPayment, uint256 startTime);
    event Buyback(address indexed buyer, address indexed asset, uint256 amountOut, uint256 payment);
    event Redeem(address indexed account, uint256 graiAmount, uint256 depositValue);
    event Vote(address indexed account, uint256 amount, uint256 totalVoted);
    event VoteReward(address indexed account, uint256 amount);
    event Bribe(
        address indexed briber, address indexed voter, uint256 graiAmount, uint256 bribeAmount, uint256 totalVoted
    );
    event Liquidate(bool liquidation, uint256 totalVoted, uint256 supply);
    event Resettle(uint256 totalVoted, uint256 supply);
    event ConfigUpdate(ProtocolConfig config);

    function config()
        external
        view
        returns (
            uint16 treasuryCutBps,
            uint16 bribePremiumBps,
            uint16 quorumBps,
            uint32 auctionDuration,
            uint32 liquidationPeriod,
            uint32 redeemPeriod
        );

    function ADMIN_ROLE() external view returns (bytes32);

    function GRINDERS_ROLE() external view returns (bytes32);

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

    function votes(address account)
        external
        view
        returns (address voter, uint256 amount, uint48 votedAt, uint32 id, uint256 rewardDebt, uint256 claimableReward);

    function voters(uint256 index) external view returns (address);

    function getVoters() external view returns (address[] memory);

    function totalVoted() external view returns (uint256);

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

    function balance(address asset) external view returns (uint256);

    /// @notice Convert a USD amount (`USD_DECIMALS`) into `bribeAsset` base units via oracle.
    function bribeAssetAmount(uint256 usdAmount) external view returns (uint256);

    function previewDeposit(address asset, uint256 amount) external view returns (uint256 value, uint256 graiOut);

    /// @notice Linear Dutch amount: decays `maxAmount` → `minAmount` over `duration`.
    function dutchAmount(uint256 maxAmount, uint256 minAmount, uint256 elapsed, uint256 duration)
        external
        pure
        returns (uint256);

    /// @notice Asset out (capped to auction remaining) and dutch GRAI payment at `timestamp`.
    function previewBuyback(address asset, uint256 amount, uint256 timestamp)
        external
        view
        returns (uint256 amountOut, uint256 payment);

    function setAssetConfig(address asset, AssetConfig calldata cfg) external;

    function deposit(address asset, uint256 amount) external payable returns (uint256 graiOut, uint256 depositValue);

    /// @notice Fill a Dutch lot: pay GRAI ask, receive `asset`, credit vote rewards.
    function buyback(address asset, uint256 amount) external;

    function distribute(address asset, uint256 yieldAmount) external payable;

    /// @notice Pro-rata asset amounts paid for burning wallet-held and/or vote-escrowed GRAI.
    function previewRedeem(address holder, uint256 graiAmount)
        external
        view
        returns (address[] memory assetOuts, uint256[] memory amounts);

    /// @notice Burn wallet-held and/or vote-escrowed GRAI for a pro-rata share of the liquidation basket.
    function redeem(uint256 graiAmount) external;

    /// @notice Escrow GRAI toward liquidation quorum. Exit via `bribe`: voter gets book value,
    ///         premium is skimmed to treasury / listed for GRAI buy (self-bribe therefore costs the premium).
    function vote(uint256 graiAmount) external;

    /// @notice Preview the `bribeAsset` payment for a vote buyout.
    function previewBribe(address voter, uint256 graiAmount) external view returns (uint256 bribeAmount);

    /// @notice Buy out `voter` for `previewBribe` settlement: book to voter, premium to treasury/auction;
    ///         briber receives the escrowed GRAI.
    function bribe(address voter, uint256 graiAmount) external payable;

    /// @notice Open liquidation (requires quorum): pauses all assets and cancels open yield auctions
    ///         into the redeem basket. Unredeemed shares retain their book value.
    function liquidate() external;

    /// @notice Close liquidation after `liquidationPeriod + redeemPeriod`: returns leftover balances
    ///         to Grinders, unpauses assets, and resets `totalValue` to leftover basket NAV.
    function resettle() external;
}
