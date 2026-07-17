// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGRAI, IERC20, IERC20Metadata, IPriceOracleRouter} from "./interfaces/IGRAI.sol";
import {IJuniorPool} from "./interfaces/IJuniorPool.sol";
import {ISeniorPool} from "./interfaces/ISeniorPool.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";
import {PriceOracleRouter} from "./PriceOracleRouter.sol";

/// @title GRAI (implementation)
/// @notice Senior idle reserve plus Grinders Artificial Index ERC20: yield-accruing tranche (~$ NAV, 6 decimals).
/// @dev NAV is priced from the senior asset basket via on-chain oracles. Interact only via the ERC1967Proxy.
contract GRAI is
    IGRAI,
    PriceOracleRouter,
    ERC20Upgradeable,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 100_00; // 100%
    uint16 public constant GRAI_DUST_BPS = 10; // 0.1%

    // bytes32 public constant DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant SENIOR_ROLE = keccak256("SENIOR_ROLE");
    bytes32 public constant JUNIOR_ROLE = keccak256("JUNIOR_ROLE");

    /// @notice Low-risk pool providing liquidation insurance backing for GRAI.
    ISeniorPool public seniorPool;

    /// @notice High-risk pool that generates yield.
    IJuniorPool public juniorPool;

    /// @notice Fee recipient for protocol profit from `distribute`.
    address public treasury;

    address[] public assetList;
    mapping(address asset => AssetConfig) public assets;

    uint256 public totalDeposit;
    uint256 public totalYield;
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

    /// @notice GRAI voted toward liquidation quorum (held by this contract).
    mapping(address account => Vote) public votes;
    /// @notice Accounts with an open vote; `votes[account].id` is the index here.
    address[] public voters;
    uint256 public totalVoted;
    /// @notice True after `openLiquidation` until `closeLiquidation`.
    bool public liquidation;

    /// @notice Ask/bid Harberger APRs, unlock fees, and liquidation quorum threshold.
    ProtocolConfig public config;

    /// @dev Storage gap for future upgrades.
    uint256[25] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) public initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __ERC20_init("Grinders Artificial Index", "GRAI");
        __AccessControlEnumerable_init();
        seniorPool = ISeniorPool(address(this));
        juniorPool = IJuniorPool(address(this));
        treasury = admin_;
        config = ProtocolConfig({
            askAprBps: 1_00,
            bidAprBps: 1_00,
            bribePremiumBps: 2_00,
            liquidationQuorumBps: 66_67
        });
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(ORACLE_ROLE, admin_);
    }

    function setConfig(ProtocolConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cfg.askAprBps > BPS
            || cfg.bidAprBps > BPS
            || cfg.bribePremiumBps > BPS
            || cfg.liquidationQuorumBps > BPS
        ) revert BpsTooHigh();
        config = cfg;
        emit ConfigUpdate(cfg);
    }

    function setSeniorPool(address seniorPool_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (seniorPool_ == address(0)) revert ZeroAddress();
        if (address(ISeniorPool(seniorPool_).grai()) != address(this)) revert GrindersGraiMismatch();

        address previous = address(seniorPool);
        if (previous != address(0)) _revokeRole(SENIOR_ROLE, previous);
        seniorPool = ISeniorPool(seniorPool_);
        _grantRole(SENIOR_ROLE, seniorPool_);
        emit SeniorPoolUpdate(seniorPool_);
    }

    function setJuniorPool(address juniorPool_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (juniorPool_ == address(0)) revert ZeroAddress();
        if (address(IJuniorPool(juniorPool_).grai()) != address(this)) revert GrindersGraiMismatch();

        address previous = address(juniorPool);
        if (previous != address(0)) _revokeRole(JUNIOR_ROLE, previous);
        juniorPool = IJuniorPool(juniorPool_);
        _grantRole(JUNIOR_ROLE, juniorPool_);
        emit JuniorPoolUpdate(juniorPool_);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdate(treasury_);
    }

    function toggleSeniorPool(address seniorPool_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _togglePool(SENIOR_ROLE, seniorPool_);
    }

    function toggleJuniorPool(address juniorPool_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _togglePool(JUNIOR_ROLE, juniorPool_);
    }

    receive() external payable {}

    /// @inheritdoc IGRAI
    function getAssets() public view returns (address[] memory) {
        return assetList;
    }

    function getOrders() public view returns (address[] memory _asks, address[] memory _bids) {
        return (asksList, bidsList);
    }

    function getVoters() public view returns (address[] memory) {
        return voters;
    }

    /// @inheritdoc IERC1046
    function tokenURI() public pure returns (string memory) {
        return "https://grindurus.xyz/metadata.json";
    }

    function decimals() public pure override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return USD_DECIMALS;
    }

    /// @notice Linear Dutch price: decays `maxPayment` → `minPayment` over `duration`; `elapsed` past
    ///         `duration` clamps to `minPayment`.
    function dutchPrice(
        uint256 maxPayment,
        uint256 minPayment,
        uint256 elapsed,
        uint256 duration
    ) public pure returns (uint256) {
        if (elapsed >= duration) return minPayment;
        return maxPayment - ((maxPayment - minPayment) * elapsed) / duration;
    }

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @inheritdoc IGRAI
    /// @dev Fail-closed: any nonzero idle listed balance is priced via oracle. A stale/failed feed on
    ///      one asset reverts the whole NAV and thus blocks `maxRedeem`/`redeem` (intentional stop-the-world).
    // forge-lint: disable-next-line(mixed-case-function)
    function nav() public view returns (uint256 value) {
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
        return supply > 0 && totalVoted * BPS >= supply * config.liquidationQuorumBps;
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
        // Invert of previewRedeem book value: (graiAmount * totalValue) / supply <= nav().
        if (totalValue == 0) return supply;

        uint256 byNav = ((nav() + 1) * supply - 1) / totalValue;
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

    function removeAsset(address asset) external onlyRole(ADMIN_ROLE) {
        uint256 index = assets[asset].id;
        if (index >= assetList.length || assetList[index] != asset) revert AssetUnknown();
        if (!assets[asset].paused) revert NotPaused();
        if (balance(asset) > 0) revert AssetBalanceNonZero();

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
    /// @dev Flips the liquidation flag and pauses/unpauses every asset accordingly. Opening requires quorum.
    function toggleLiquidate() public onlyRole(ADMIN_ROLE) {
        bool opening = !liquidation;
        if (opening && !hasQuorum()) revert LiquidationQuorumNotMet();
        uint256 len = assetList.length;
        for (uint256 i; i < len; ) {
            address asset = assetList[i];
            assets[asset].paused = opening;
            emit AssetConfigUpdate(asset, assets[asset].yieldSplit, opening);
            unchecked { ++i; }
        }
        liquidation = opening;
        emit Liquidate(opening, totalVoted, totalSupply());
    }

    function setAssetConfig(address asset, uint16 yieldSplit, bool paused) external onlyRole(ADMIN_ROLE) {
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (yieldSplit > BPS) revert BpsTooHigh();
        assets[asset].yieldSplit = yieldSplit;
        assets[asset].paused = paused;
        emit AssetConfigUpdate(asset, yieldSplit, paused);
    }

    function put(address asset, uint256 amount) public payable onlyRole(JUNIOR_ROLE) {
        if (amount == 0) revert AmountZero();
        uint256 received = _deposit(msg.sender, address(this), asset, amount);
        uint256 prev = used[asset];
        used[asset] = prev > received ? prev - received : 0;
    }

    //////////////////// DISTRIBUTE ////////////////////

    /// @notice Split yield into senior accrual (`totalValue` + idle) and protocol profit (to `treasury`).
    /// @dev Pull funds, update book, then pay treasury (effects before the outbound call).
    function distribute(address asset, uint256 yieldAmount) public payable {
        AssetConfig storage cfg = assets[asset];
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (yieldAmount == 0) revert AmountZero();

        uint256 received = _deposit(msg.sender, address(this), asset, yieldAmount);
        yieldBy[msg.sender][asset] += received;
        uint256 yieldShare = (received * cfg.yieldSplit) / BPS;
        uint256 treasuryShare = received - yieldShare;
        
        uint256 yieldValue = usdValue(asset, yieldShare);
        totalYield += yieldValue;
        if (yieldShare > 0) totalValue += yieldValue;
        if (treasuryShare > 0) _withdraw(treasury, asset, treasuryShare);
        emit Distribute(msg.sender, asset, received, yieldShare, treasuryShare);
    }

    //////////////////// DEPOSIT ////////////////////

    function deposit(address asset, uint256 amount) public payable returns (uint256 graiOut, uint256 depositValue) {
        if (liquidation) revert LiquidationOpen();
        if (amount == 0) revert AmountZero();
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (assets[asset].paused) revert Paused();

        uint256 received = _deposit(msg.sender, address(juniorPool), asset, amount);

        (graiOut, depositValue) = previewDeposit(asset, received);
        if (depositValue == 0) revert AmountZero();
        if (graiOut == 0) revert AmountZero();

        totalDeposit += depositValue;
        if (address(seniorPool) == address(juniorPool)) totalValue += depositValue;
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

    function redeem(uint256 graiAmount) public {
        if (graiAmount == 0) revert AmountZero();
        if (graiAmount > balanceOf(msg.sender)) revert InvalidAmount();

        // Cap also acts as the idle-share denominator: redeeming `maxRedeem()` claims 100% of current idle.
        if (graiAmount > maxRedeem()) revert InvalidAmount();
        if (totalSupply() == 0) revert AmountZero();

        (address[] memory assetOuts, uint256[] memory amounts, uint256 valueOut) = previewRedeem(graiAmount);
        _burn(msg.sender, graiAmount);
        totalValue -= valueOut;

        uint256 n = assetOuts.length;
        for (uint256 i; i < n;) {
            _withdraw(msg.sender, assetOuts[i], amounts[i]);
            unchecked { ++i; }
        }
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
        if (supply == 0 || graiAmount == 0) return (new address[](0), new uint256[](0), 0);

        value = (graiAmount * totalValue) / supply;

        uint256 cap = maxRedeem();
        if (graiAmount > cap) return (new address[](0), new uint256[](0), value);
        uint256 len = assetList.length;
        assetOuts = new address[](len);
        amounts = new uint256[](len);
        uint256 count;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            uint256 _balance = balance(asset);
            if (_balance > 0) {
                // Full maxRedeem drains every idle balance; partial is pro-rata of that claim.
                uint256 redeemAmount = graiAmount == cap ? _balance : (graiAmount * _balance) / cap;
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
        // Listing cost is Harberger tax
        if (tax > 0) _transfer(seller, treasury, tax);
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
        if (duration == 0) revert AmountZero();
        if (minPayment > maxPayment) revert InvalidAmount();
        if (graiAmount > balanceOf(seller)) revert InvalidAmount();

        tax = (graiAmount * config.askAprBps * duration) / (uint256(BPS) * 365 days);
        lot = graiAmount - tax;
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
        uint256 price = dutchPrice(entry.maxPayment, entry.minPayment, block.timestamp - entry.startTime, entry.duration);
        payment = (price * graiOut) / entry.graiInitial;
    }

    function fulfillAsk(address seller, uint256 graiAmount, uint256 paymentMax) public payable {
        address buyer = msg.sender;
        Ask storage entry = asks[seller];
        if (entry.startTime == 0) revert AskNotFound();

        (uint256 graiOut, uint256 payment) = previewFulfillAsk(seller, graiAmount);
        if (graiOut == 0 || payment == 0) revert AmountZero();
        if (payment > paymentMax) revert InvalidAmount();

        address asset = entry.asset;
        uint256 remaining = entry.graiRemaining;
        uint256 newRemaining = remaining - graiOut;
        // Dust vs pre-scale initial; post-scale initial tracks remaining and would make dust unreachable.
        uint256 graiDust = (entry.graiInitial * GRAI_DUST_BPS) / BPS;
        entry.maxPayment = (entry.maxPayment * newRemaining) / remaining;
        entry.minPayment = (entry.minPayment * newRemaining) / remaining;
        entry.graiInitial = (entry.graiInitial * newRemaining) / remaining;
        entry.graiRemaining = newRemaining;
        if (newRemaining <= graiDust || balanceOf(seller) <= graiOut) _removeAsk(seller);

        _transfer(seller, buyer, graiOut);
        _pay(seller, asset, payment);
        emit AskFulfill(buyer, seller, asset, graiOut, payment);
    }

    //////////////////// BID ////////////////////

    /// @inheritdoc IGRAI
    function bid(
        address asset,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) public {
        address buyer = msg.sender;
        (uint256 lot, uint256 tax) = previewBid(buyer, asset, maxPayment, minPayment, duration, graiAmount);

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
        // Listing cost is Harberger tax only (soft bid for the dutch payment).
        if (tax > 0) IERC20(asset).safeTransferFrom(buyer, treasury, tax);
        emit BidCreate(buyer, asset, graiAmount, maxPayment, minPayment, duration, tax);
    }

    /// @inheritdoc IGRAI
    /// @dev Soft bid: Harberger tax paid upfront. ERC20 needs allowance for dutch payment
    function previewBid(
        address buyer,
        address asset,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) public view returns (uint256 lot, uint256 tax) {
        if (asset == address(0)) revert EthBidsDisabled();
        if (graiAmount == 0 || maxPayment == 0) revert AmountZero();
        if (duration == 0) revert AmountZero();
        if (minPayment > maxPayment) revert InvalidAmount();

        tax = (maxPayment * config.bidAprBps * duration) / (uint256(BPS) * 365 days);
        if (tax >= maxPayment) revert AmountZero();
        if (minPayment > maxPayment - tax) revert InvalidAmount();

        // Tax + dutch payment covered by soft allowance / balance of `maxPayment`.
        if (IERC20(asset).allowance(buyer, address(this)) < maxPayment) revert InvalidAmount();
        if (IERC20(asset).balanceOf(buyer) < maxPayment) revert InvalidAmount();
        lot = graiAmount;
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
        uint256 price = dutchPrice(entry.maxPayment, entry.minPayment, block.timestamp - entry.startTime, entry.duration);
        payment = (price * graiIn) / entry.graiInitial;

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

    /// @inheritdoc IGRAI
    /// @dev ERC20 only: seller (`msg.sender`) fills `buyer`'s bid; payment is pulled from buyer allowance.
    function fulfillBid(address buyer, uint256 graiAmount, uint256 paymentMin) public {
        address seller = msg.sender;
        Bid storage entry = bids[buyer];
        (uint256 graiIn, uint256 payment) = previewFulfillBid(buyer, seller, graiAmount);
        
        if (graiIn == 0 || payment == 0) revert AmountZero();
        if (payment < paymentMin) revert InvalidAmount();

        address asset = entry.asset;
        uint256 remaining = entry.graiRemaining;
        uint256 newRemaining = remaining - graiIn;
        // Dust vs pre-scale initial; post-scale initial tracks remaining and would make dust unreachable.
        uint256 graiDust = (entry.graiInitial * GRAI_DUST_BPS) / BPS;
        entry.maxPayment = (entry.maxPayment * newRemaining) / remaining;
        entry.minPayment = (entry.minPayment * newRemaining) / remaining;
        entry.graiInitial = (entry.graiInitial * newRemaining) / remaining;
        entry.graiRemaining = newRemaining;
        if (newRemaining <= graiDust) _removeBid(buyer);

        _transfer(seller, buyer, graiIn);
        _pay(buyer, asset, payment);
        emit BidFulfill(seller, buyer, asset, graiIn, payment);
    }

    //////////////////// LIQUIDATION ////////////////////

    /// @inheritdoc IGRAI
    function vote(uint256 graiAmount) public {
        address voter = msg.sender;
        if (graiAmount == 0) revert AmountZero();
        if (graiAmount > balanceOf(voter)) revert InvalidAmount();

        _transfer(voter, address(this), graiAmount);
        Vote storage entry = votes[voter];
        uint32 id = entry.id;
        if (entry.amount == 0) {
            id = uint32(voters.length);
            voters.push(voter);
        }
        entry.amount += graiAmount;
        entry.lockedAt = uint48(block.timestamp);
        entry.id = id;
        totalVoted += graiAmount;
        emit Voted(voter, graiAmount, totalVoted);
    }

    /// @inheritdoc IGRAI
    /// @dev Briber (`msg.sender`) buys out `voter`'s vote of `graiAmount`: pays book value + premium to the voter
    ///      in the senior asset, then receives the escrowed GRAI.
    function bribe(address voter, uint256 graiAmount) public payable {
        address briber = msg.sender;
        (address asset, uint256 bribeAmount, uint256 premium) = previewBribe(voter, graiAmount);
        uint256 total = bribeAmount + premium;

        Vote storage entry = votes[voter];
        uint256 locked = entry.amount - graiAmount;
        entry.amount = locked;
        totalVoted -= graiAmount;
        if (locked == 0) _removeVoter(voter);

        // Voter receives book value; premium is routed to the senior pool.
        if (asset == address(0)) {
            if (msg.value != total) revert ValueMismatch();
            if (bribeAmount > 0) _withdraw(voter, asset, bribeAmount);
            if (premium > 0) _withdraw(address(seniorPool), asset, premium);
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            if (bribeAmount > 0) IERC20(asset).safeTransferFrom(briber, voter, bribeAmount);
            if (premium > 0) IERC20(asset).safeTransferFrom(briber, address(seniorPool), premium);
        }

        // Escrowed GRAI is released to the briber.
        _transfer(address(this), briber, graiAmount);
        emit Bribe(briber, voter, graiAmount, total, totalVoted);
    }

    /// @inheritdoc IGRAI
    /// @dev Book value of `graiAmount` = `graiAmount * (totalDeposit + totalYield) / totalSupply`, priced in USD
    ///      and converted to the senior asset (`seniorPool.hedgeAsset()`).
    function previewBribe(
        address voter,
        uint256 graiAmount
    ) public view returns (address asset, uint256 bribeAmount, uint256 premium) {
        if (graiAmount == 0) revert AmountZero();
        Vote storage entry = votes[voter];
        if (graiAmount > entry.amount) revert InvalidAmount();

        asset = seniorPool.hedgeAsset();
        uint256 supply = totalSupply();
        bribeAmount = supply == 0 ? 0 : (graiAmount * (totalDeposit + totalYield)) / supply;
        premium = (bribeAmount * config.bribePremiumBps) / BPS;
    }

    //////////////////// INTERNAL HELPERS ////////////////////

    function _pay(address to, address asset, uint256 payment) private {
        // address payer = msg.sender
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

    function _removeVoter(address voter) private {
        uint256 index = votes[voter].id;
        uint256 lastIndex = voters.length - 1;
        if (index != lastIndex) {
            address moved = voters[lastIndex];
            voters[index] = moved;
            // voters length / index always fit uint32 in practice
            // forge-lint: disable-next-line(unsafe-typecast)
            votes[moved].id = uint32(index);
        }
        voters.pop();
        delete votes[voter];
    }

    /// @dev Pulls `amount` and returns tokens actually credited (FoT-safe for ERC20).
    function _deposit(address from, address to, address asset, uint256 amount) internal returns (uint256 received) {
        if (asset == address(0)) {
            if (msg.value != amount) revert ValueMismatch();
            return amount;
        }
        if (msg.value > 0) revert UnexpectedValue();
        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(from, to, amount);
        received = IERC20(asset).balanceOf(to) - before;
        if (received == 0) revert AmountZero();
    }

    function _withdraw(address to, address asset, uint256 amount) internal {
        if (asset == address(0)) {
            if (to == address(0)) revert ZeroAddress();
            if (amount == 0) revert AmountZero();
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    /// @dev Grants `role` to `pool` (or revokes if already held); on grant, requires `pool.grai() == this`.
    function _togglePool(bytes32 role, address pool) internal {
        if (pool == address(0)) revert ZeroAddress();
        if (hasRole(role, pool)) {
            _revokeRole(role, pool);
            emit PoolToggle(role, pool, false);
        } else {
            if (address(ISeniorPool(pool).grai()) != address(this)) revert GrindersGraiMismatch();
            _grantRole(role, pool);
            emit PoolToggle(role, pool, true);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
