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
    error InsufficientSeniorVault();
    error PaymentExceedsMax();
    error PaymentBelowMin();
    error InsufficientAllowance();
    error LiquidationQuorumNotMet();
    error LiquidationAlreadyOpen();
    error LiquidationNotOpen();
    error LiquidationOpen();

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

    struct Lock {
        uint256 amount;
        /// @notice Timestamp of the latest `lock` (resets on each lock).
        uint48 lockedAt;
    }

    event AssetAdd(address indexed asset);
    event AssetRemove(address indexed asset);
    event PauseUpdate(address indexed asset, bool paused);
    event YieldSplitUpdate(address indexed asset, uint16 bps);
    event Deposit(address indexed to, uint256 graiOut, uint256 value);
    event GrindersUpdate(address indexed grinders, bool enabled);
    event TreasuryUpdate(address indexed treasury);
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
    event LiquidationLock(address indexed account, uint256 amount, uint256 totalLocked);
    event LiquidationUnlock(address indexed account, uint256 amount, uint256 fee, uint256 totalLocked);
    event Liquidated(uint256 totalLocked, uint256 supply);
    event LiquidationClosed(uint256 totalLocked, uint256 supply);
    event LiquidationQuorumUpdate(uint16 bps);

    function ASK_APR_BPS() external view returns (uint16);

    function UNLOCK_FEE_BPS() external view returns (uint16);

    function UNLOCK_APR_BPS() external view returns (uint16);

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

    function liquidationLocks(address account) external view returns (uint256 amount, uint48 lockedAt);

    function totalLiquidationLocked() external view returns (uint256);

    function liquidationQuorumBps() external view returns (uint16);

    /// @notice True when locked GRAI is at least `liquidationQuorumBps` of `totalSupply`.
    function hasQuorum() external view returns (bool);

    /// @notice True after `openLiquidation` until `closeLiquidation`.
    function liquidation() external view returns (bool);

    function assets(address asset) external view returns (uint16 yieldSplit, bool paused, uint32 id);

    function assetList(uint256 index) external view returns (address);

    function getAssets() external view returns (address[] memory);

    function setTreasury(address treasury_) external;

    function setLiquidationQuorumBps(uint16 bps) external;

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

    function setPaused(address asset, bool paused) external;

    function setYieldSplit(address asset, uint16 bps) external;

    function deposit(address asset, uint256 amount) external payable returns (uint256 graiOut, uint256 depositValue);

    function redeem(uint256 graiAmount) external;

    function ask(address asset, uint256 maxPayment, uint256 minPayment, uint256 duration, uint256 graiAmount)
        external;

    function fulfillAsk(address seller, uint256 graiAmount, uint256 paymentMax) external payable;

    /// @notice Soft bid: Harberger tax on listing. ERC20 dutch paid via allowance; ETH dutch paid on fulfill.
    function bid(address asset, uint256 maxPayment, uint256 minPayment, uint256 duration, uint256 graiAmount)
        external
        payable;

    /// @notice Net GRAI sought and listing tax in `asset` for a soft bid.
    function previewBid(
        address buyer,
        address asset,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) external view returns (uint256 lot, uint256 tax);

    /// @notice Fill a soft bid. `msg.value > 0` → ETH path (buyer=`msg.sender`, peer=seller);
    ///         else ERC20 (seller=`msg.sender`, peer=buyer). ETH takes priority when both listings exist.
    function fulfillBid(address peer, uint256 graiAmount, uint256 paymentMin) external payable;

    /// @notice GRAI sold (capped) and dutch payment pulled from buyer's allowance.
    function previewFulfillBid(address buyer, address seller, uint256 graiAmount)
        external
        view
        returns (uint256 graiIn, uint256 payment);

    function distribute(address asset, uint256 yieldAmount) external payable;

    function take(address asset, address to, uint256 amount) external;

    function put(address asset, uint256 amount) external payable;

    /// @notice Lock GRAI on this contract toward the 95% liquidation quorum (resets lock timer).
    function lock(uint256 graiAmount) external;

    /// @notice Net GRAI returned and fee (flat `UNLOCK_FEE_BPS` + time tax at `UNLOCK_APR_BPS`).
    ///         Fee is zero while `hasQuorum()` or `liquidation` so lockers can exit and redeem.
    function previewUnlock(address account, uint256 graiAmount) external view returns (uint256 net, uint256 fee);

    /// @notice Return locked GRAI minus unlock fee (fee to treasury; waived when `hasQuorum()` or `liquidation`).
    function unlock(uint256 graiAmount) external;

    /// @notice If quorum is met, set `liquidation` and pause all assets (Grinders `liquidate` then reads this flag).
    function openLiquidation() external;

    /// @notice Clear `liquidation` and unpause all assets.
    function closeLiquidation() external;
}
