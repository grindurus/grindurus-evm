// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1046} from "./IERC1046.sol";
import {IPriceOracleRouter} from "./IPriceOracleRouter.sol";

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
    error Slippage();
    error EthTransferFailed();
    error GrindersGraiMismatch();
    error ValueMismatch();
    error UnexpectedValue();
    error LiquidationQuorumNotMet();
    error LiquidationOpen();
    error LiquidationClosed();
    error LiquidationDelay();
    error RedeemPeriodActive();
    error SettlementAssetUnset();
    error AuctionDurationTooShort();
    error AuctionsOpen();
    error TargetZero();
    error DataEmpty();
    error SwapFailed();

    struct AssetConfig {
        /// @notice The asset this config belongs to (mirrors the `assets` mapping key).
        address asset;
        /// @notice Index of this asset in `assetList` while listed.
        uint32 id;
        bool paused;
        /// @notice Share of distributed yield sent to `treasury`, in bps.
        uint16 treasuryShare;
    }

    /// @notice One Dutch auction of distributed yield for a single sold asset, paid in `settlementAsset`.
    struct DutchAuction {
        address asset;
        uint256 remaining;
        uint256 initial;
        /// @notice Full-lot payment in `settlementAsset` units at auction start (oracle fair value).
        uint256 maxPayment;
        /// @notice Full-lot payment in `settlementAsset` units after the Dutch auction ends.
        uint256 minPayment;
        uint256 startTime;
    }

    struct VoteEscrow {
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

    /// @notice Bribe premium, liquidation quorum, and timing.
    struct ProtocolConfig {
        /// @notice Settlement payment for a vote buyout, in bps of book value.
        uint16 bribePremiumBps;
        uint16 liquidationQuorumBps;
        /// @notice Dutch auction duration from `maxPayment` to `minPayment`.
        uint32 auctionDuration;
        /// @notice Delay after liquidation opens before `liquidate` (claim) is allowed.
        /// @dev Window for keepers to call `Grinders.liquidate`, which pulls all custodian assets into GRAI
        ///      where they sit as idle inventory for the subsequent pro-rata `liquidate` basket.
        uint32 liquidationPeriod;
        /// @notice Extra window after `liquidationPeriod` before liquidation can be closed via `resolve`.
        uint32 redeemPeriod;
    }

    event AssetUpdate(address indexed asset, bool listed);
    event AssetConfigUpdate(address indexed asset, AssetConfig cfg);
    event Deposit(address indexed depositor, uint256 graiOut, address indexed asset, uint256 amount, uint256 value);
    event TreasuryUpdate(address indexed treasury);
    event SettlementAssetUpdate(address indexed settlementAsset);
    event Distribute(
        address indexed from, address indexed asset, uint256 yieldAmount, uint256 yieldShare, uint256 treasuryShare
    );
    event AuctionUpdate(address indexed asset, uint256 remaining, uint256 maxPayment, uint256 startTime);
    event AuctionFill(address indexed buyer, address indexed asset, uint256 amountOut, uint256 payment);
    event Buyback(address indexed target, uint256 payment, uint256 graiOut);
    event Liquidate(address indexed account, uint256 graiAmount, uint256 depositValue);
    event Vote(address indexed account, uint256 amount, uint256 totalVoted);
    event VoteReward(address indexed account, uint256 amount);
    event Bribe(
        address indexed briber, address indexed voter, uint256 graiAmount, uint256 bribeAmount, uint256 totalVoted
    );
    event Resolve(bool liquidation, uint256 totalVoted, uint256 supply);
    event ConfigUpdate(ProtocolConfig config);

    function config()
        external
        view
        returns (
            uint16 bribePremiumBps,
            uint16 liquidationQuorumBps,
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
            uint256 startTime
        );

    /// @notice Listed assets that currently have an open yield auction.
    function getAuctions() external view returns (address[] memory);

    function votes(address account)
        external
        view
        returns (uint256 amount, uint48 votedAt, uint32 id, uint256 rewardDebt, uint256 claimableReward);

    function voters(uint256 index) external view returns (address);

    function getVoters() external view returns (address[] memory);

    function totalVoted() external view returns (uint256);

    /// @notice True when voted GRAI is at least `config.liquidationQuorumBps` of `totalSupply`.
    function hasQuorum() external view returns (bool);

    /// @notice True after `resolve` opens until it closes.
    function liquidation() external view returns (bool);

    /// @notice Timestamp when the current liquidation opened; zero while liquidation is closed.
    function liquidationAt() external view returns (uint48);

    function assets(address asset) external view returns (address asset_, uint32 id, bool paused, uint16 treasuryShare);

    function assetList(uint256 index) external view returns (address);

    function getAssets() external view returns (address[] memory);

    function setGrinders(address grinders_) external;

    function setTreasury(address treasury_) external;

    function settlementAsset() external view returns (address);

    function setSettlementAsset(address settlementAsset_) external;

    function setProtocolConfig(ProtocolConfig calldata cfg) external;

    function balance(address asset) external view returns (uint256);

    /// @notice Convert a USD amount (`USD_DECIMALS`) into `settlementAsset` base units via oracle.
    function settlementAmount(uint256 usdAmount) external view returns (uint256);

    function previewDeposit(address asset, uint256 amount) external view returns (uint256 value, uint256 graiOut);

    /// @notice Linear Dutch price: decays `maxPayment` → `minPayment` over `duration`.
    function dutchPrice(uint256 maxPayment, uint256 minPayment, uint256 elapsed, uint256 duration)
        external
        pure
        returns (uint256);

    /// @notice Yield-asset out (capped to auction remaining) and dutch `settlementAsset` payment at `timestamp`.
    function previewFill(address asset, uint256 amount, uint256 timestamp)
        external
        view
        returns (uint256 amountOut, uint256 payment);

    function setAssetConfig(address asset, AssetConfig calldata cfg) external;

    function deposit(address asset, uint256 amount) external payable returns (uint256 graiOut, uint256 depositValue);

    function fill(address asset, uint256 amount, uint256 paymentMax) external payable;

    function distribute(address asset, uint256 yieldAmount) external payable;

    /// @notice Swap all GRAI-held `settlementAsset` through `target` for GRAI, held on this contract.
    /// @dev DEX calldata must route the bought GRAI to this contract.
    function buyback(address target, bytes calldata data, uint256 graiOutMin)
        external
        returns (uint256 payment, uint256 graiOut);

    /// @notice Pro-rata asset amounts paid for burning wallet-held and/or vote-escrowed GRAI.
    function previewLiquidate(address holder, uint256 graiAmount)
        external
        view
        returns (address[] memory assetOuts, uint256[] memory amounts);

    /// @notice Burn wallet-held and/or vote-escrowed GRAI for a pro-rata share of the liquidation basket.
    function liquidate(uint256 graiAmount) external;

    /// @notice Irreversibly escrow GRAI toward liquidation quorum; only a third-party `bribe` can buy it out.
    function vote(uint256 graiAmount) external;

    /// @notice Preview the `settlementAsset` payment for a vote buyout.
    function previewBribe(address voter, uint256 graiAmount) external view returns (uint256 bribeAmount);

    /// @notice Buy out `voter` for `previewBribe` settlement and receive the escrowed GRAI.
    function bribe(address voter, uint256 graiAmount) external payable;

    /// @notice Toggle `liquidation`: opening (requires quorum) pauses all assets; closing is available
    ///         after the liquidation and redeem periods, returns leftover balances to Grinders,
    ///         and unpauses all assets. Unredeemed shares retain their book value.
    function resolve() external;
}
