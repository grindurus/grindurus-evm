// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";
import {IGrinders} from "./interfaces/IGrinders.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";
import {IPriceOracleRouter} from "./interfaces/IPriceOracleRouter.sol";
import {PriceOracleRouter} from "./PriceOracleRouter.sol";

/// @title GRAI (implementation)
/// @notice Senior idle reserve plus Grinders Artificial Index ERC20: yield-accruing tranche (~$ NAV, 6 decimals).
/// @dev NAV is priced from the senior asset basket via on-chain oracles. Interact only via the ERC1967Proxy.
contract GRAI is
    IGRAI,
    PriceOracleRouter,
    ERC20Upgradeable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 100_00; // 100%
    /// @notice Harberger tax rate on listed GRAI, annualized (1% / year).
    uint16 public constant ASK_APR_BPS = 1_00; // 1% 
    uint16 public constant GRAI_DUST_BPS = 10; // 0.1%
    /// @notice Flat unlock fee on locked GRAI (sent to treasury).
    uint16 public constant UNLOCK_FEE_BPS = 5_00; // 5%
    /// @notice Time-based unlock tax, annualized, accrued while GRAI is locked.
    uint16 public constant UNLOCK_APR_BPS = 1_00; // 1% / year

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant GRINDERS_ROLE = keccak256("GRINDERS_ROLE");

    /// @notice Fee recipient for protocol profit from `distribute`.
    address public treasury;

    address[] public assetList;
    mapping(address asset => AssetConfig) public assets;

    uint256 public totalValue;
    mapping(address asset => uint256) public used;
    mapping(address custodian => mapping(address asset => uint256)) public yieldBy;

    /// @notice One open Dutch ask per seller.
    mapping(address seller => Ask) public asks;
    /// @notice Sellers with an open ask; `asks[seller].id` is the index here.
    address[] public asksList;

    /// @notice One open soft Dutch bid per buyer (buy GRAI with `asset`).
    mapping(address buyer => Bid) public bids;
    /// @notice Buyers with an open bid; `bids[buyer].id` is the index here.
    address[] public bidsList;

    /// @notice GRAI locked toward liquidation quorum (held by this contract).
    mapping(address account => Lock) public liquidationLocks;
    uint256 public totalLiquidationLocked;
    /// @notice Share of GRAI supply that must be locked to trigger protocol liquidation (bps).
    uint16 public liquidationQuorumBps;
    /// @notice True after `openLiquidation` until `closeLiquidation`.
    bool public liquidation;

    /// @dev Storage gap for future upgrades.
    uint256[26] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) public initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __ERC20_init("Grinders Artificial Index", "GRAI");
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        treasury = admin_;
        liquidationQuorumBps = 80_00; // 80%
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(ORACLE_ROLE, admin_);
    }

    function setLiquidationQuorumBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > BPS) revert BpsTooHigh();
        liquidationQuorumBps = bps;
        emit LiquidationQuorumUpdate(bps);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdate(treasury_);
    }

    function toggleGrinders(address grinders) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (grinders == address(0)) revert ZeroAddress();
        if (hasRole(GRINDERS_ROLE, grinders)) {
            _revokeRole(GRINDERS_ROLE, grinders);
            emit GrindersUpdate(grinders, false);
        } else {
            if (address(IGrinders(grinders).grai()) != address(this)) revert GrindersGraiMismatch();
            _grantRole(GRINDERS_ROLE, grinders);
            emit GrindersUpdate(grinders, true);
        }
    }

    receive() external payable {}

    /// @inheritdoc IGRAI
    function getAssets() public view returns (address[] memory) {
        return assetList;
    }

    function getAsks() public view returns (address[] memory) {
        return asksList;
    }

    function getBids() public view returns (address[] memory) {
        return bidsList;
    }

    /// @inheritdoc IERC1046
    function tokenURI() public pure returns (string memory) {
        return "https://grindurus.xyz/metadata.json";
    }

    function decimals() public pure override returns (uint8) {
        return USD_DECIMALS;
    }

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @inheritdoc IGRAI
    // forge-lint: disable-next-line(mixed-case-function)
    function seniorNAV() public view returns (uint256 value) {
        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            uint256 bal = balance(asset);
            if (bal > 0) value += usdValue(asset, bal);
        }
    }

    /// @inheritdoc IGRAI
    function hasQuorum() public view returns (bool) {
        uint256 supply = totalSupply();
        return supply > 0 && totalLiquidationLocked * BPS >= supply * liquidationQuorumBps;
    }

    /// @inheritdoc IGRAI
    /// @notice Liquid senior tranche cap: how much GRAI may exit against *current idle* NAV only.
    /// @dev Sticky `totalValue` can exceed idle mark-to-market (e.g. after an oracle drop while book is
    ///      unchanged). Redeeming exactly `maxRedeem()` intentionally drains 100% of idle balances while
    ///      burning only that NAV-capped share count — residual GRAI stays as a claim on non-idle /
    ///      sticky book. Partial redeems pro-rate idle by `graiAmount / maxRedeem`, not `/ totalSupply`.
    ///      This FCFS idle model is by design, not an accounting bug.
    function maxRedeem() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        // Invert of previewRedeem book value: (graiAmount * totalValue) / supply <= seniorNAV().
        if (totalValue == 0) return supply;

        uint256 byNav = ((seniorNAV() + 1) * supply - 1) / totalValue;
        return byNav < supply ? byNav : supply;
    }

    function setFeed(address asset, Feed calldata feed) public override(IPriceOracleRouter, PriceOracleRouter) onlyRole(ORACLE_ROLE) {
        super.setFeed(asset, feed);
    }

    function addAsset(address asset, uint16 yieldSplit) external onlyRole(ADMIN_ROLE) {
        if (feeds[asset].feedType == FEED_NONE) revert FeedNotSet();
        if (yieldSplit > BPS) revert BpsTooHigh();
        uint256 existingId = assets[asset].id;
        if (existingId < assetList.length && assetList[existingId] == asset) revert AssetExists();

        uint32 id = uint32(assetList.length);
        assets[asset] = AssetConfig({yieldSplit: yieldSplit, paused: false, id: id});
        assetList.push(asset);
        emit AssetAdd(asset);
    }

    function removeAsset(address asset, uint256 hintId) external onlyRole(ADMIN_ROLE) {
        uint256 index = assets[asset].id;
        if (index >= assetList.length || assetList[index] != asset) revert AssetUnknown();
        if (!assets[asset].paused) revert NotPaused();
        if (balance(asset) > 0) revert AssetBalanceNonZero();
        if (hintId != index) revert HintMismatch();

        uint256 lastIndex = assetList.length - 1;
        if (index != lastIndex) {
            address moved = assetList[lastIndex];
            assetList[index] = moved;
            // list length / index always fit uint32 in practice
            // forge-lint: disable-next-line(unsafe-typecast)
            assets[moved].id = uint32(index);
        }
        assetList.pop();
        delete assets[asset];
        delete feeds[asset];
        emit AssetRemove(asset);
    }

    /// @inheritdoc IGRAI
    function openLiquidation() public onlyRole(ADMIN_ROLE) {
        if (liquidation) revert LiquidationAlreadyOpen();
        if (!hasQuorum()) revert LiquidationQuorumNotMet();
        uint256 len = assetList.length;
        for (uint256 i; i < len; ) {
            address asset = assetList[i];
            assets[asset].paused = true;
            emit PauseUpdate(asset, true);
            unchecked { ++i; }
        }
        liquidation = true;
        emit Liquidated(totalLiquidationLocked, totalSupply());
    }

    /// @inheritdoc IGRAI
    function closeLiquidation() public onlyRole(ADMIN_ROLE) {
        if (!liquidation) revert LiquidationNotOpen();
        uint256 len = assetList.length;
        for (uint256 i; i < len; ) {
            address asset = assetList[i];
            assets[asset].paused = false;
            emit PauseUpdate(asset, false);
            unchecked { ++i; }
        }
        liquidation = false;
        emit LiquidationClosed(totalLiquidationLocked, totalSupply());
    }

    function setPaused(address asset, bool paused) external onlyRole(ADMIN_ROLE) {
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        assets[asset].paused = paused;
        emit PauseUpdate(asset, paused);
    }

    function setYieldSplit(address asset, uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (bps > BPS) revert BpsTooHigh();
        assets[asset].yieldSplit = bps;
        emit YieldSplitUpdate(asset, bps);
    }

    function take(address asset, address to, uint256 amount) public onlyRole(GRINDERS_ROLE) {
        if (amount > balance(asset)) revert InsufficientSeniorVault();
        _withdraw(to, asset, amount);
        used[asset] += amount;
    }

    function put(address asset, uint256 amount) public payable onlyRole(GRINDERS_ROLE) {
        if (amount == 0) revert AmountZero();
        uint256 received = _deposit(msg.sender, asset, amount);
        uint256 prev = used[asset];
        used[asset] = prev > received ? prev - received : 0;
    }

    //////////////////// DISTRIBUTE ////////////////////

    /// @notice Split yield into senior accrual (`totalValue` + idle) and protocol profit (to `treasury`).
    function distribute(address asset, uint256 yieldAmount) public payable {
        // TODO fix double value [88]
        AssetConfig storage cfg = assets[asset];
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (yieldAmount == 0) revert AmountZero();

        uint256 seniorShare = (yieldAmount * cfg.yieldSplit) / BPS;
        uint256 treasuryShare = yieldAmount - seniorShare;

        if (asset == address(0)) {
            if (msg.value != yieldAmount) revert IGrinders.ValueMismatch();
            if (seniorShare > 0) {
                totalValue += usdValue(asset, seniorShare);
            }
            if (treasuryShare > 0) {
                (bool ok,) = treasury.call{value: treasuryShare}("");
                if (!ok) revert EthTransferFailed();
            }
        } else {
            if (msg.value != 0) revert IGrinders.UnexpectedValue();
            if (seniorShare > 0) {
                IERC20(asset).safeTransferFrom(msg.sender, address(this), seniorShare);
                totalValue += usdValue(asset, seniorShare);
            }
            if (treasuryShare > 0) {
                IERC20(asset).safeTransferFrom(msg.sender, treasury, treasuryShare);
            }
        }

        yieldBy[msg.sender][asset] += yieldAmount;
        emit Distribute(msg.sender, asset, yieldAmount, seniorShare, treasuryShare);
    }

    //////////////////// DEPOSIT ////////////////////

    function deposit(address asset, uint256 amount) public payable nonReentrant returns (uint256 graiOut, uint256 depositValue) {
        if (liquidation) revert LiquidationOpen();
        if (amount == 0) revert AmountZero();
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (assets[asset].paused) revert IGrinders.MintingPaused();

        uint256 received = _deposit(msg.sender, asset, amount);

        (graiOut, depositValue) = previewDeposit(asset, received);
        if (depositValue == 0) revert IGrinders.ValueZero();
        if (graiOut == 0) revert AmountZero();

        totalValue += depositValue;
        _mint(msg.sender, graiOut);
        emit Deposit(msg.sender, graiOut, depositValue);
    }

    /// @inheritdoc IGRAI
    /// @dev GRAI minted and USD value for depositing `amount` of `asset` at current book price.
    function previewDeposit(address asset, uint256 amount) public view returns (uint256 graiOut, uint256 value) {
        value = usdValue(asset, amount);
        uint256 supply = totalSupply();
        if (supply == 0 || totalValue == 0) return (value, value);
        graiOut = (value * supply) / totalValue;
    }

    //////////////////// REDEEM ////////////////////

    function redeem(uint256 graiAmount) public nonReentrant {
        if (graiAmount == 0) revert AmountZero();
        if (graiAmount > balanceOf(msg.sender)) revert AmountExceedsSupply();

        // Cap also acts as the idle-share denominator: redeeming `maxRedeem()` claims 100% of current idle.
        if (graiAmount > maxRedeem()) revert InvalidRedeemAmount();
        if (totalSupply() == 0) revert NoSupply();

        (address[] memory assetOuts, uint256[] memory amounts, uint256 valueOut) = previewRedeem(graiAmount);
        uint256 n = assetOuts.length;
        for (uint256 i; i < n;) {
            _withdraw(msg.sender, assetOuts[i], amounts[i]);
            unchecked { ++i; }
        }

        _burn(msg.sender, graiAmount);
        totalValue -= valueOut;
        emit Redeem(msg.sender, graiAmount, valueOut);
    }


    /// @inheritdoc IGRAI
    /// @dev Idle asset outs and sticky book USD retired for redeeming `graiAmount` (same shares as `redeem`).
    function previewRedeem(uint256 graiAmount)
        public
        view
        returns (address[] memory assetOuts, uint256[] memory amounts, uint256 value)
    {
        uint256 supply = totalSupply();
        if (supply == 0 || graiAmount == 0) {
            return (new address[](0), new uint256[](0), 0);
        }

        value = (graiAmount * totalValue) / supply;

        uint256 cap = maxRedeem();
        if (graiAmount > cap) {
            return (new address[](0), new uint256[](0), value);
        }

        uint256 len = assetList.length;
        assetOuts = new address[](len);
        amounts = new uint256[](len);
        uint256 count;

        for (uint256 i; i < len;) {
            address asset = assetList[i];
            uint256 seniorBalance = balance(asset);
            if (seniorBalance > 0) {
                // Full maxRedeem drains every idle balance; partial is pro-rata of that claim.
                uint256 redeemAmount = graiAmount == cap ? seniorBalance : (graiAmount * seniorBalance) / cap;
                if (redeemAmount > 0) {
                    assetOuts[count] = asset;
                    amounts[count] = redeemAmount;
                    unchecked { ++count; }
                }
            }
            unchecked { ++i; }
        }

        assembly ("memory-safe") {
            mstore(assetOuts, count)
            mstore(amounts, count)
        }
    }

    //////////////////// ASK ////////////////////

    function ask(
        address asset,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) public {
        address seller = msg.sender;
        (uint256 lot, uint256 tax) = previewAsk(seller, maxPayment, minPayment, duration, graiAmount);
        if (tax > 0) _transfer(seller, treasury, tax);

        uint32 id = asks[seller].id;
        if (asks[seller].startTime == 0) {
            id = uint32(asksList.length);
            asksList.push(seller);
        }

        asks[seller] = Ask({
            asset: asset,
            graiRemaining: lot,
            graiInitial: lot,
            maxPayment: maxPayment,
            minPayment: minPayment,
            startTime: block.timestamp,
            duration: duration,
            id: id
        });
        emit AskCreate(seller, asset, graiAmount, maxPayment, minPayment, duration, tax);
    }

    /// @inheritdoc IGRAI
    function previewAsk(
        address seller,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) public view returns (uint256 lot, uint256 tax) {
        if (graiAmount == 0 || maxPayment == 0) revert AmountZero();
        if (duration == 0) revert DurationZero();
        if (minPayment > maxPayment) revert MinAboveMax();
        if (graiAmount > balanceOf(seller)) revert AmountExceedsSupply();

        tax = (graiAmount * ASK_APR_BPS * duration) / (uint256(BPS) * 365 days);
        lot = graiAmount - tax;
    }

    function fulfillAsk(address seller, uint256 graiAmount, uint256 paymentMax) public payable {
        Ask storage entry = asks[seller];
        if (entry.startTime == 0) revert AskNotFound();

        (uint256 graiOut, uint256 payment) = previewFulfillAsk(seller, graiAmount);
        if (graiOut == 0 || payment == 0) revert AmountZero();
        if (payment > paymentMax) revert PaymentExceedsMax();

        address asset = entry.asset;
        uint256 remaining = entry.graiRemaining;
        uint256 newRemaining = remaining - graiOut;
        // Dust vs pre-scale initial; post-scale initial tracks remaining and would make dust unreachable.
        uint256 graiDust = (entry.graiInitial * GRAI_DUST_BPS) / BPS;
        entry.maxPayment = (entry.maxPayment * newRemaining) / remaining;
        entry.minPayment = (entry.minPayment * newRemaining) / remaining;
        entry.graiInitial = (entry.graiInitial * newRemaining) / remaining;
        entry.graiRemaining = newRemaining;
        if (
            newRemaining == 0 || newRemaining <= graiDust || entry.maxPayment == 0 || balanceOf(seller) == 0
        ) {
            _removeAsk(seller);
        }

        _pay(seller, asset, payment);
        _transfer(seller, msg.sender, graiOut);
        emit AskFulfill(msg.sender, seller, asset, graiOut, payment);
    }

    /// @inheritdoc IGRAI
    /// @dev Dutch payment: maxPayment → minPayment over `duration`, scaled by lot size.
    ///      Caps fill to `graiRemaining` and seller balance; returns `(fill, payment)`.
    function previewFulfillAsk(address seller, uint256 graiAmount) public view returns (uint256 graiOut, uint256 payment) {
        Ask storage entry = asks[seller];
        if (entry.startTime == 0) revert AskNotFound();

        if (graiAmount == type(uint256).max) graiAmount = entry.graiRemaining;
        if (graiAmount > entry.graiRemaining) graiAmount = entry.graiRemaining;
        uint256 sellerBal = balanceOf(seller);
        if (graiAmount > sellerBal) graiAmount = sellerBal;
        if (graiAmount == 0) return (0, 0);

        graiOut = graiAmount;
        uint256 maxPayment = entry.maxPayment;
        uint256 minPayment = entry.minPayment;
        uint256 elapsed = block.timestamp - entry.startTime;
        uint256 price = elapsed >= entry.duration
            ? minPayment
            : maxPayment - ((maxPayment - minPayment) * elapsed) / entry.duration;
        payment = (price * graiOut) / entry.graiInitial;
    }

    //////////////////// BID ////////////////////

    /// @inheritdoc IGRAI
    function bid(
        address asset,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) public payable {
        address buyer = msg.sender;
        (uint256 lot, uint256 tax) = previewBid(buyer, asset, maxPayment, minPayment, duration, graiAmount);

        // Listing cost is Harberger tax only (soft bid for the dutch payment).
        if (asset == address(0)) {
            if (msg.value != tax) revert ValueMismatch();
            if (tax > 0) _withdraw(treasury, address(0), tax);
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            if (tax > 0) IERC20(asset).safeTransferFrom(buyer, treasury, tax);
        }

        uint32 id = bids[buyer].id;
        if (bids[buyer].startTime == 0) {
            id = uint32(bidsList.length);
            bidsList.push(buyer);
        }

        uint256 maxNet = maxPayment - tax;
        bids[buyer] = Bid({
            asset: asset,
            graiRemaining: lot,
            graiInitial: lot,
            maxPayment: maxNet,
            minPayment: minPayment,
            startTime: block.timestamp,
            duration: duration,
            id: id
        });
        emit BidCreate(buyer, asset, graiAmount, maxPayment, minPayment, duration, tax);
    }

    /// @inheritdoc IGRAI
    /// @dev Soft bid: Harberger tax paid upfront. ERC20 needs allowance for dutch payment; ETH paid on fulfill.
    function previewBid(
        address buyer,
        address asset,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) public view returns (uint256 lot, uint256 tax) {
        if (graiAmount == 0 || maxPayment == 0) revert AmountZero();
        if (duration == 0) revert DurationZero();
        if (minPayment > maxPayment) revert MinAboveMax();

        tax = (maxPayment * ASK_APR_BPS * duration) / (uint256(BPS) * 365 days);
        if (tax >= maxPayment) revert AmountZero();
        if (minPayment > maxPayment - tax) revert MinAboveMax();

        if (asset == address(0)) {
            // Buyer pays tax via `msg.value` on `bid`; dutch ETH is paid on fulfill.
            if (buyer.balance < maxPayment) revert AmountExceedsSupply();
        } else {
            // Tax + dutch payment covered by soft allowance / balance of `maxPayment`.
            if (IERC20(asset).allowance(buyer, address(this)) < maxPayment) revert InsufficientAllowance();
            if (IERC20(asset).balanceOf(buyer) < maxPayment) revert AmountExceedsSupply();
        }
        lot = graiAmount;
    }

    /// @inheritdoc IGRAI
    /// @dev ERC20 (`msg.value == 0`): seller (`msg.sender`) fills `peer`'s bid.
    ///      ETH (`msg.value > 0`): buyer (`msg.sender`) fills; `peer` is seller. ETH wins when both exist.
    function fulfillBid(address peer, uint256 graiAmount, uint256 paymentMin) public payable {
        address buyer;
        address seller;
        if (msg.value > 0) {
            if (bids[msg.sender].startTime == 0 || bids[msg.sender].asset != address(0)) revert BidNotFound();
            buyer = msg.sender;
            seller = peer;
        } else if (bids[peer].startTime != 0 && bids[peer].asset != address(0)) {
            buyer = peer;
            seller = msg.sender;
        } else {
            revert BidNotFound();
        }

        Bid storage entry = bids[buyer];
        (uint256 graiIn, uint256 payment) = previewFulfillBid(buyer, seller, graiAmount);
        if (graiIn == 0 || payment == 0) revert AmountZero();
        if (payment < paymentMin) revert PaymentBelowMin();

        address asset = entry.asset;
        uint256 remaining = entry.graiRemaining;
        uint256 newRemaining = remaining - graiIn;
        // Dust vs pre-scale initial; post-scale initial tracks remaining and would make dust unreachable.
        uint256 graiDust = (entry.graiInitial * GRAI_DUST_BPS) / BPS;
        entry.maxPayment = (entry.maxPayment * newRemaining) / remaining;
        entry.minPayment = (entry.minPayment * newRemaining) / remaining;
        entry.graiInitial = (entry.graiInitial * newRemaining) / remaining;
        entry.graiRemaining = newRemaining;

        if (newRemaining == 0 || newRemaining <= graiDust || balanceOf(seller) == 0) _removeBid(buyer);
        if (asset == address(0)) {
            if (msg.value != payment) revert ValueMismatch();
            _withdraw(seller, address(0), payment);
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(buyer, seller, payment);
        }
        _transfer(seller, buyer, graiIn);
        emit BidFulfill(seller, buyer, asset, graiIn, payment);
    }

    /// @inheritdoc IGRAI
    /// @dev Dutch payment: maxPayment → minPayment over `duration`, scaled by lot size.
    ///      Caps fill to `graiRemaining` and seller GRAI balance.
    function previewFulfillBid(
        address buyer,
        address seller,
        uint256 graiAmount
    ) public view returns (uint256 graiIn, uint256 payment) {
        Bid storage entry = bids[buyer];
        if (entry.startTime == 0) revert BidNotFound();

        if (graiAmount == type(uint256).max) graiAmount = entry.graiRemaining;
        if (graiAmount > entry.graiRemaining) graiAmount = entry.graiRemaining;
        uint256 sellerBal = balanceOf(seller);
        if (graiAmount > sellerBal) graiAmount = sellerBal;
        if (graiAmount == 0) return (0, 0);

        graiIn = graiAmount;
        uint256 maxPayment = entry.maxPayment;
        uint256 minPayment = entry.minPayment;
        uint256 elapsed = block.timestamp - entry.startTime;
        uint256 price = elapsed >= entry.duration
            ? minPayment
            : maxPayment - ((maxPayment - minPayment) * elapsed) / entry.duration;
        payment = (price * graiIn) / entry.graiInitial;

        // Soft ERC20 clamp to allowance/balance. ETH is paid via `msg.value` on fulfill (no pull).
        if (entry.asset == address(0)) return (graiIn, payment);

        uint256 allowance = IERC20(entry.asset).allowance(buyer, address(this));
        uint256 bal = IERC20(entry.asset).balanceOf(buyer);
        uint256 spendable = allowance < bal ? allowance : bal;
        if (payment > spendable) {
            if (spendable == 0 || price == 0) return (0, 0);
            graiIn = (spendable * entry.graiInitial) / price;
            if (graiIn > graiAmount) graiIn = graiAmount;
            if (graiIn == 0) return (0, 0);
            payment = (price * graiIn) / entry.graiInitial;
            if (payment > spendable) payment = spendable;
        }
    }

    //////////////////// LIQUIDATION ////////////////////

    /// @inheritdoc IGRAI
    function lock(uint256 graiAmount) public {
        if (graiAmount == 0) revert AmountZero();
        if (graiAmount > balanceOf(msg.sender)) revert AmountExceedsSupply();

        _transfer(msg.sender, address(this), graiAmount);
        Lock storage entry = liquidationLocks[msg.sender];
        entry.amount += graiAmount;
        entry.lockedAt = uint48(block.timestamp);
        totalLiquidationLocked += graiAmount;
        emit LiquidationLock(msg.sender, graiAmount, totalLiquidationLocked);
    }

    /// @inheritdoc IGRAI
    function unlock(uint256 graiAmount) public {
        (uint256 net, uint256 fee) = previewUnlock(msg.sender, graiAmount);

        Lock storage entry = liquidationLocks[msg.sender];
        uint256 locked = entry.amount - graiAmount;
        entry.amount = locked;
        totalLiquidationLocked -= graiAmount;
        if (locked == 0) delete liquidationLocks[msg.sender];

        if (fee > 0) _transfer(address(this), treasury, fee);
        if (net > 0) _transfer(address(this), msg.sender, net);
        emit LiquidationUnlock(msg.sender, graiAmount, fee, totalLiquidationLocked);
    }

    /// @inheritdoc IGRAI
    /// @dev Fee = flat `UNLOCK_FEE_BPS` + `UNLOCK_APR_BPS` accrued since the latest `lock`.
    ///      Waived when `hasQuorum()` or `liquidation` so lockers can exit and redeem.
    function previewUnlock(address account, uint256 graiAmount) public view returns (uint256 net, uint256 fee) {
        if (graiAmount == 0) revert AmountZero();
        Lock storage entry = liquidationLocks[account];
        if (graiAmount > entry.amount) revert AmountExceedsSupply();

        if (liquidation) return (graiAmount, 0);

        uint256 flat = (graiAmount * UNLOCK_FEE_BPS) / BPS;
        uint256 lockedAt = entry.lockedAt;
        uint256 elapsed = lockedAt == 0 || block.timestamp <= lockedAt ? 0 : block.timestamp - lockedAt;
        uint256 timeTax = (graiAmount * UNLOCK_APR_BPS * elapsed) / (uint256(BPS) * 365 days);
        fee = flat + timeTax;
        if (fee > graiAmount) fee = graiAmount;
        net = graiAmount - fee;
    }

    //////////////////// INTERNAL HELPERS ////////////////////

    function _pay(address to, address asset, uint256 payment) private {
        if (asset == address(0)) {
            if (msg.value != payment) revert ValueMismatch();
            (bool ok,) = to.call{value: payment}("");
            if (!ok) revert EthTransferFailed();
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(msg.sender, to, payment);
        }
    }

    function _removeAsk(address seller) private {
        uint256 index = asks[seller].id;
        uint256 lastIndex = asksList.length - 1;
        if (index != lastIndex) {
            address moved = asksList[lastIndex];
            asksList[index] = moved;
            // asksList length / index always fit uint32 in practice
            // forge-lint: disable-next-line(unsafe-typecast)
            asks[moved].id = uint32(index);
        }
        asksList.pop();
        delete asks[seller];
    }

    function _removeBid(address buyer) private {
        uint256 index = bids[buyer].id;
        uint256 lastIndex = bidsList.length - 1;
        if (index != lastIndex) {
            address moved = bidsList[lastIndex];
            bidsList[index] = moved;
            // bidsList length / index always fit uint32 in practice
            // forge-lint: disable-next-line(unsafe-typecast)
            bids[moved].id = uint32(index);
        }
        bidsList.pop();
        delete bids[buyer];
    }

    /// @dev Pulls `amount` and returns tokens actually credited (FoT-safe for ERC20).
    function _deposit(address from, address asset, uint256 amount) internal returns (uint256 received) {
        if (asset == address(0)) {
            if (msg.value != amount) revert IGrinders.ValueMismatch();
            return amount;
        }
        if (msg.value != 0) revert IGrinders.UnexpectedValue();
        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        received = IERC20(asset).balanceOf(address(this)) - before;
        if (received == 0) revert AmountZero();
    }

    function _withdraw(address to, address asset, uint256 amount) internal {
        if (asset == address(0)) {
            if (to == address(0)) revert ToZero();
            if (amount == 0) revert AmountZero();
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
