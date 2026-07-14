// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1046} from "./IERC1046.sol";
import {IPriceOracleRouter} from "./IPriceOracleRouter.sol";

interface IGRAI is IERC20, IERC1046, IPriceOracleRouter {
    error AssetExists();
    error AssetUnknown();
    error BpsTooHigh();
    error NotPaused();
    error BadHint();
    error HintMismatch();
    error InvalidRedeemAmount();
    error NoSupply();
    error AmountExceedsSupply();
    error AuctionNotFound();
    error AuctionNotExpired();
    error NotSeller();
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

    struct AssetConfig {
        bool exists;
        uint16 yieldSplit;
        bool pausedMinting;
    }

    struct AuctionLot {
        address seller;
        address asset;
        uint256 graiRemaining;
        uint256 graiInitial;
        uint256 maxPayment;
        uint256 minPayment;
        uint256 startTime;
        uint256 duration;
        uint256 listIndex;
    }

    event AssetAdd(address indexed asset);
    event AssetRemove(address indexed asset);
    event MintingPauseUpdate(address indexed asset, bool paused);
    event YieldSplitUpdate(address indexed asset, uint16 bps);
    event Mint(address indexed to, uint256 graiOut, uint256 value);
    event GrindersUpdate(address indexed grinders, bool enabled);
    event TreasuryUpdate(address indexed treasury);
    event Burn(address indexed from, uint256 graiAmount, uint256 value);
    event Distribute(
        address indexed from, address indexed asset, uint256 yieldAmount, uint256 seniorYield, uint256 protocolProfit
    );
    event Ask(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed asset,
        uint256 graiAmount,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 taxGrai
    );
    event Bid(
        uint256 indexed auctionId,
        address indexed bidder,
        address indexed seller,
        address asset,
        uint256 graiBought,
        uint256 payment,
        uint256 graiRemaining
    );
    event Unplace(uint256 indexed auctionId, address indexed seller, uint256 graiAmount);

    function HARBERGER_BPS() external view returns (uint16);

    function ADMIN_ROLE() external view returns (bytes32);

    function ORACLE_ROLE() external view returns (bytes32);

    function GRINDERS_ROLE() external view returns (bytes32);

    function treasury() external view returns (address);

    function nextAuctionId() external view returns (uint256);

    function totalValue() external view returns (uint256);

    function taken(address asset) external view returns (uint256);

    function auctions(uint256 auctionId)
        external
        view
        returns (
            address seller,
            address asset,
            uint256 graiRemaining,
            uint256 graiInitial,
            uint256 maxPayment,
            uint256 minPayment,
            uint256 startTime,
            uint256 duration,
            uint256 listIndex
        );

    function auctionIds(uint256 index) external view returns (uint256);

    function assets(address asset)
        external
        view
        returns (bool exists, uint16 yieldSplit, bool pausedMinting);

    function assetList(uint256 index) external view returns (address);

    function setTreasury(address treasury_) external;

    function toggleGrinders(address grinders) external;

    function balance(address asset) external view returns (uint256);

    function totalNAV() external view returns (uint256);

    function mintPrice() external view returns (uint256);

    function maxRedeem() external view returns (uint256);

    function harbergerTax(uint256 graiAmount, uint256 duration) external pure returns (uint256);

    function auctionPrice(uint256 auctionId) external view returns (uint256);

    function addAsset(address asset, uint16 yieldSplit) external;

    function removeAsset(address asset, uint256 hintId) external;

    function setPaused(address asset, bool paused) external;

    function setYieldSplit(address asset, uint16 bps) external;

    function deposit(address asset, uint256 amount) external payable returns (uint256 depositValue);

    function redeem(uint256 graiAmount) external;

    function ask(address asset, uint256 maxPayment, uint256 minPayment, uint256 duration, uint256 graiAmount)
        external
        returns (uint256 auctionId);

    function bid(uint256 auctionId, uint256 graiAmount) external payable;

    function withdraw(address asset, address to, uint256 amount) external;

    function distribute(address asset, uint256 yieldAmount) external payable;
}
