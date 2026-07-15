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
    error AuctionNotFound();
    error AskExists();
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

    struct AssetConfig {
        uint16 yieldSplit;
        bool paused;
        /// @notice Index of this asset in `assetList` while listed.
        uint32 id;
    }

    struct AuctionLot {
        address asset;
        uint256 graiRemaining;
        uint256 graiInitial;
        uint256 maxPayment;
        uint256 minPayment;
        uint256 startTime;
        uint256 duration;
    }

    event AssetAdd(address indexed asset);
    event AssetRemove(address indexed asset);
    event MintingPauseUpdate(address indexed asset, bool paused);
    event YieldSplitUpdate(address indexed asset, uint16 bps);
    event Deposit(address indexed to, uint256 graiOut, uint256 value);
    event GrindersUpdate(address indexed grinders, bool enabled);
    event TreasuryUpdate(address indexed treasury);
    event Redeem(address indexed from, uint256 graiAmount, uint256 value);
    event Distribute(
        address indexed from, address indexed asset, uint256 yieldAmount, uint256 seniorYield, uint256 protocolProfit
    );
    event Ask(
        address indexed seller,
        address indexed asset,
        uint256 graiAmount,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 taxGrai
    );
    event Bid(
        address indexed bidder,
        address indexed seller,
        address asset,
        uint256 graiBought,
        uint256 payment
    );

    function APR_BPS() external view returns (uint16);

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
            uint256 duration
        );

    function assets(address asset) external view returns (uint16 yieldSplit, bool paused, uint32 id);

    function assetList(uint256 index) external view returns (address);

    function setTreasury(address treasury_) external;

    function toggleGrinders(address grinders) external;

    function balance(address asset) external view returns (uint256);

    function seniorNAV() external view returns (uint256);

    function previewDeposit(address asset, uint256 amount) external view returns (uint256 graiOut, uint256 value);

    function previewRedeem(uint256 graiAmount)
        external
        view
        returns (address[] memory assetOuts, uint256[] memory amounts, uint256 value);

    function maxRedeem() external view returns (uint256);

    function previewTax(uint256 graiAmount, uint256 duration) external pure returns (uint256);

    function previewBid(address seller, uint256 graiAmount) external view returns (uint256);

    function addAsset(address asset, uint16 yieldSplit) external;

    function removeAsset(address asset, uint256 hintId) external;

    function setPaused(address asset, bool paused) external;

    function setYieldSplit(address asset, uint16 bps) external;

    function deposit(address asset, uint256 amount) external payable returns (uint256 graiOut, uint256 depositValue);

    function redeem(uint256 graiAmount) external;

    function ask(address asset, uint256 maxPayment, uint256 minPayment, uint256 duration, uint256 graiAmount)
        external;

    function bid(address seller, uint256 graiAmount) external payable;

    function distribute(address asset, uint256 yieldAmount) external payable;

    function take(address asset, address to, uint256 amount) external;

    function put(address asset, uint256 amount) external payable;
}
