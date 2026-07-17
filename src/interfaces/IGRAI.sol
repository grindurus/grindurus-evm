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
    error AskNotFound();
    error BidNotFound();
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
    error EthBidsDisabled();

    struct AssetConfig {
        /// @notice The asset this config belongs to (mirrors the `assets` mapping key).
        address asset;
        /// @notice Index of this asset in `assetList` while listed.
        uint32 id;
        bool paused;
        uint16 yieldSplit;
    }

    struct Ask {
        address asset;
        uint256 graiRemaining;
        uint256 graiInitial;
        uint256 maxPayment;
        uint256 minPayment;
        uint256 startTime;
        uint256 duration;
        /// @notice Index of this seller in `asksList` while the ask is open.
        uint32 id;
    }

    /// @notice Soft bid to buy GRAI with `asset` (Dutch max→min payment); requires ERC20 allowance.
    struct Bid {
        address asset;
        uint256 graiRemaining;
        uint256 graiInitial;
        uint256 maxPayment;
        uint256 minPayment;
        uint256 startTime;
        uint256 duration;
        /// @notice Index of this buyer in `bidsList` while the bid is open.
        uint32 id;
    }

    struct Vote {
        uint256 amount;
        /// @notice Timestamp of the latest `vote` (resets on each vote).
        uint48 lockedAt;
        /// @notice Index of this account in `voters` while the vote is open.
        uint32 id;
    }

    /// @notice Ask/bid Harberger APRs, vote-buyout (bribe) premium, and liquidation quorum threshold.
    struct ProtocolConfig {
        uint16 askAprBps;
        uint16 bidAprBps;
        /// @notice Premium over book value paid to the bought-out voter.
        uint16 bribePremiumBps;
        uint16 liquidationQuorumBps;
    }

    event AssetAdd(address indexed asset);
    event AssetRemove(address indexed asset);
    event AssetConfigUpdate(address indexed asset, AssetConfig cfg);
    event Deposit(address indexed to, uint256 graiOut, uint256 value);
    event PoolToggle(bytes32 indexed role, address indexed pool, bool enabled);
    event TreasuryUpdate(address indexed treasury);
    event JuniorPoolUpdate(address indexed juniorPool);
    event SeniorPoolUpdate(address indexed seniorPool);
    event Redeem(address indexed from, uint256 graiAmount, uint256 value);
    event Distribute(
        address indexed from, address indexed asset, uint256 yieldAmount, uint256 seniorYield, uint256 protocolProfit
    );
    event AskCreate(
        address indexed seller,
        address indexed asset,
        uint256 graiAmount,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 taxGrai
    );
    event AskFill(
        address indexed buyer,
        address indexed seller,
        address asset,
        uint256 graiBought,
        uint256 payment
    );
    event BidCreate(
        address indexed buyer,
        address indexed asset,
        uint256 graiAmount,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 taxPayment
    );
    event BidFill(
        address indexed seller,
        address indexed buyer,
        address asset,
        uint256 graiSold,
        uint256 payment
    );
    event Voted(address indexed account, uint256 amount, uint256 totalVoted);
    event Bribe(
        address indexed briber,
        address indexed voter,
        uint256 graiAmount,
        uint256 bribeAmount,
        uint256 totalVoted
    );
    event Liquidate(bool liquidation, uint256 totalVoted, uint256 supply);
    event ConfigUpdate(ProtocolConfig config);

    function config()
        external
        view
        returns (
            uint16 askAprBps,
            uint16 bidAprBps,
            uint16 bribePremiumBps,
            uint16 liquidationQuorumBps
        );

    function ADMIN_ROLE() external view returns (bytes32);

    function GRINDERS_ROLE() external view returns (bytes32);

    function treasury() external view returns (address);

    function totalValue() external view returns (uint256);

    function used(address asset) external view returns (uint256);

    function yieldBy(address custodian, address asset) external view returns (uint256);

    function asks(address seller)
        external
        view
        returns (
            address asset,
            uint256 graiRemaining,
            uint256 graiInitial,
            uint256 maxPayment,
            uint256 minPayment,
            uint256 startTime,
            uint256 duration,
            uint32 id
        );

    function asksList(uint256 index) external view returns (address);

    function bids(address buyer)
        external
        view
        returns (
            address asset,
            uint256 graiRemaining,
            uint256 graiInitial,
            uint256 maxPayment,
            uint256 minPayment,
            uint256 startTime,
            uint256 duration,
            uint32 id
        );

    function bidsList(uint256 index) external view returns (address);

    function getOrders() external view returns (address[] memory asks, address[] memory bids);

    function votes(address account) external view returns (uint256 amount, uint48 lockedAt, uint32 id);

    function voters(uint256 index) external view returns (address);

    function getVoters() external view returns (address[] memory);

    function totalVoted() external view returns (uint256);

    /// @notice True when voted GRAI is at least `config.liquidationQuorumBps` of `totalSupply`.
    /// @dev Uses live supply (not a snapshot); deposits may dilute quorum until votes catch up — by design.
    function hasQuorum() external view returns (bool);

    /// @notice True after `openLiquidation` until `closeLiquidation`.
    function liquidation() external view returns (bool);

    function assets(address asset) external view returns (address asset_, uint32 id, bool paused, uint16 yieldSplit);

    function assetList(uint256 index) external view returns (address);

    function getAssets() external view returns (address[] memory);

    function setGrinders(address grinders_) external;

    function setSGRAI(address sgrai_) external;

    function setTreasury(address treasury_) external;

    function setConfig(ProtocolConfig calldata cfg) external;

    function balance(address asset) external view returns (uint256);

    /// @notice USD NAV of idle senior balances (6 decimals).
    // forge-lint: disable-next-line(mixed-case-function)
    function nav() external view returns (uint256);

    function previewDeposit(address asset, uint256 amount) external view returns (uint256 graiOut, uint256 value);

    function previewRedeem(uint256 graiAmount)
        external
        view
        returns (address[] memory assetOuts, uint256[] memory amounts, uint256 value);

    function maxRedeem() external view returns (uint256);

    /// @notice Validates ask params for `seller`, then returns net listed GRAI (`lot`) and listing tax.
    function previewAsk(
        address seller,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) external view returns (uint256 lot, uint256 tax);

    /// @notice Linear Dutch price: decays `maxPayment` → `minPayment` over `duration`.
    function dutchPrice(uint256 maxPayment, uint256 minPayment, uint256 elapsed, uint256 duration)
        external
        pure
        returns (uint256);

    /// @notice GRAI out (capped to ask remaining + seller balance) and dutch payment at `timestamp`.
    function previewFillAsk(address seller, uint256 graiAmount, uint256 timestamp)
        external
        view
        returns (uint256 graiOut, uint256 payment);

    function setAssetConfig(address asset, AssetConfig calldata cfg) external;

    function deposit(address asset, uint256 amount) external payable returns (uint256 graiOut, uint256 depositValue);

    function redeem(uint256 graiAmount) external;

    function ask(address asset, uint256 maxPayment, uint256 minPayment, uint256 duration, uint256 graiAmount)
        external;

    function fillAsk(address seller, uint256 graiAmount, uint256 paymentMax) external payable;

    /// @notice Soft bid: Harberger tax on listing. ERC20 dutch paid via allowance; ETH dutch paid on fulfill.
    function bid(address asset, uint256 maxPayment, uint256 minPayment, uint256 duration, uint256 graiAmount)
        external;

    /// @notice Net GRAI sought and listing tax in `asset` for a soft bid.
    function previewBid(
        address buyer,
        address asset,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) external view returns (uint256 lot, uint256 tax);

    /// @notice Fill a soft bid by the GRAI seller. Payment is pulled from buyer allowance.
    function fillBid(address peer, uint256 graiAmount, uint256 paymentMin) external;

    /// @notice GRAI sold (capped) and dutch payment (at `timestamp`) pulled from buyer's allowance.
    function previewFillBid(address buyer, address seller, uint256 graiAmount, uint256 timestamp)
        external
        view
        returns (uint256 graiIn, uint256 payment);

    function distribute(address asset, uint256 yieldAmount) external payable;

    function put(address asset, uint256 amount) external payable;

    /// @notice Vote GRAI toward the liquidation quorum (escrowed on this contract; resets vote timer).
    function vote(uint256 graiAmount) external;

    /// @notice Preview a vote buyout: settlement `asset`, `bribeAmount` (book value), and `premium`.
    function previewBribe(address voter, uint256 graiAmount)
        external
        view
        returns (address asset, uint256 bribeAmount, uint256 premium);

    /// @notice Buy out `voter`'s vote: briber pays book value + premium to the voter (settled in the senior
    ///         asset), and receives the escrowed GRAI.
    function bribe(address voter, uint256 graiAmount) external payable;

    /// @notice Toggle `liquidation`: opening (requires quorum) pauses all assets, closing unpauses them.
    ///         Grinders `liquidate` reads this flag.
    function liquidate() external;
}
