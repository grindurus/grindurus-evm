// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1046} from "./IERC1046.sol";
import {IPriceOracleRouter} from "./IPriceOracleRouter.sol";

interface IGRAI is IERC20, IERC1046, IPriceOracleRouter {
    error AssetExists();
    error AssetUnknown();
    error AssetBalanceNonZero();
    error BpsTooHigh();
    error NotPaused();
    error Paused();
    error BadHint();
    error HintMismatch();
    error InvalidRedeemAmount();
    error NoSupply();
    error AmountExceedsSupply();
    error AskNotFound();
    error BidNotFound();
    error MinAboveMax();
    error InvalidBidAmount();
    error DurationZero();
    error ZeroAddress();
    error ToZero();
    error AmountZero();
    error EthTransferFailed();
    error GrindersGraiMismatch();
    error ValueMismatch();
    error UnexpectedValue();
    error PaymentExceedsMax();
    error PaymentBelowMin();
    error InsufficientAllowance();
    error LiquidationQuorumNotMet();
    error LiquidationAlreadyOpen();
    error LiquidationNotOpen();
    error LiquidationOpen();
    error EthBidsDisabled();

    struct AssetConfig {
        uint16 yieldSplit;
        bool paused;
        /// @notice Index of this asset in `assetList` while listed.
        uint32 id;
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

    /// @notice Ask/bid Harberger APRs, unlock fees, and liquidation quorum threshold.
    struct ProtocolConfig {
        uint16 askAprBps;
        uint16 bidAprBps;
        uint16 unlockFeeBps;
        uint16 unlockAprBps;
        uint16 liquidationQuorumBps;
    }

    event AssetAdd(address indexed asset);
    event AssetRemove(address indexed asset);
    event AssetConfigUpdate(address indexed asset, uint16 yieldSplit, bool paused);
    event Deposit(address indexed to, uint256 graiOut, uint256 value);
    event GrindersUpdate(address indexed grinders, bool enabled);
    event TreasuryUpdate(address indexed treasury);
    event JuniorVaultUpdate(address indexed juniorVault);
    event SeniorVaultUpdate(address indexed seniorVault);
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
    event AskFulfill(
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
    event BidFulfill(
        address indexed seller,
        address indexed buyer,
        address asset,
        uint256 graiSold,
        uint256 payment
    );
    event Voted(address indexed account, uint256 amount, uint256 totalVoted);
    event LiquidationUnlock(address indexed account, uint256 amount, uint256 fee, uint256 totalLocked);
    event Liquidate(bool liquidation, uint256 totalVoted, uint256 supply);
    event ConfigUpdate(ProtocolConfig config);

    function config()
        external
        view
        returns (
            uint16 askAprBps,
            uint16 bidAprBps,
            uint16 unlockFeeBps,
            uint16 unlockAprBps,
            uint16 liquidationQuorumBps
        );

    function ADMIN_ROLE() external view returns (bytes32);

    function ORACLE_ROLE() external view returns (bytes32);

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

    function assets(address asset) external view returns (uint16 yieldSplit, bool paused, uint32 id);

    function assetList(uint256 index) external view returns (address);

    function getAssets() external view returns (address[] memory);

    function setJuniorVault(address juniorVault_) external;

    function setSeniorVault(address seniorVault_) external;

    function setTreasury(address treasury_) external;

    function setConfig(ProtocolConfig calldata cfg) external;

    function toggleGrinders(address grinders) external;

    function balance(address asset) external view returns (uint256);

    /// @notice USD NAV of idle senior balances (6 decimals).
    // forge-lint: disable-next-line(mixed-case-function)
    function seniorNAV() external view returns (uint256);

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

    /// @notice GRAI out (capped to ask remaining + seller balance) and dutch payment.
    function previewFulfillAsk(address seller, uint256 graiAmount)
        external
        view
        returns (uint256 graiOut, uint256 payment);

    function addAsset(address asset, uint16 yieldSplit) external;

    function removeAsset(address asset, uint256 hintId) external;

    function setAssetConfig(address asset, uint16 yieldSplit, bool paused) external;

    function deposit(address asset, uint256 amount) external payable returns (uint256 graiOut, uint256 depositValue);

    function redeem(uint256 graiAmount) external;

    function ask(address asset, uint256 maxPayment, uint256 minPayment, uint256 duration, uint256 graiAmount)
        external;

    function fulfillAsk(address seller, uint256 graiAmount, uint256 paymentMax) external payable;

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
    function fulfillBid(address peer, uint256 graiAmount, uint256 paymentMin) external;

    /// @notice GRAI sold (capped) and dutch payment pulled from buyer's allowance.
    function previewFulfillBid(address buyer, address seller, uint256 graiAmount)
        external
        view
        returns (uint256 graiIn, uint256 payment);

    function distribute(address asset, uint256 yieldAmount) external payable;

    function put(address asset, uint256 amount) external payable;

    /// @notice Vote GRAI toward the liquidation quorum (escrowed on this contract; resets vote timer).
    function vote(uint256 graiAmount) external;

    /// @notice Net GRAI returned and fee (flat `config.unlockFeeBps` + time tax at `config.unlockAprBps`).
    ///         Fee is zero while `liquidation` so voters can exit and redeem.
    function previewUnlock(address account, uint256 graiAmount) external view returns (uint256 net, uint256 fee);

    /// @notice Return voted GRAI minus unlock fee (fee to treasury; waived when `liquidation`).
    function unlock(uint256 graiAmount) external;

    /// @notice If quorum is met, set `liquidation` and pause all assets (Grinders `liquidate` then reads this flag).
    function openLiquidation() external;

    /// @notice Clear `liquidation` and unpause all assets.
    function closeLiquidation() external;
}
