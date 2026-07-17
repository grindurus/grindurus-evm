// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGRAI, IERC20, IERC20Metadata, IPriceOracleRouter} from "./interfaces/IGRAI.sol";
import {IGrinders} from "./interfaces/IGrinders.sol";
import {IsGRAI} from "./interfaces/IsGRAI.sol";
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
    bytes32 public constant GRINDERS_ROLE = keccak256("GRINDERS_ROLE");

    /// @notice Low-risk pool providing liquidation insurance backing for GRAI.
    IsGRAI public sgrai;

    /// @notice High-risk pool that generates yield.
    IGrinders public grinders;

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
        sgrai = IsGRAI(address(this));
        grinders = IGrinders(address(this));
        treasury = admin_;
        config = ProtocolConfig({
            askAprBps: 1_00,
            bidAprBps: 1_00,
            bribePremiumBps: 2_00,
            liquidationQuorumBps: 66_67
        });
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
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

    function setSGRAI(address sgrai_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (sgrai_ == address(0)) revert ZeroAddress();
        if (address(IsGRAI(sgrai_).grai()) != address(this)) revert GrindersGraiMismatch();
        sgrai = IsGRAI(sgrai_);
    }

    function setGrinders(address grinders_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (grinders_ == address(0)) revert ZeroAddress();
        if (address(IGrinders(grinders_).grai()) != address(this)) revert GrindersGraiMismatch();

        address previous = address(grinders);
        if (previous != address(0)) _revokeRole(GRINDERS_ROLE, previous);
        grinders = IGrinders(grinders_);
        _grantRole(GRINDERS_ROLE, grinders_);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdate(treasury_);
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
    /// @notice Max GRAI that can be redeemed against idle assets right now.
    /// @dev `redeem(maxRedeem())` takes all idle; leftover GRAI stays as a claim on future yield.
    ///      Partial redeems split idle by `graiAmount / maxRedeem` (first-come-first-served).
    function maxRedeem() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        // Invert of previewRedeem book value: (graiAmount * totalDeposit) / supply <= nav().
        if (totalDeposit + totalYield == 0) return supply;

        uint256 byNav = ((nav() + 1) * supply - 1) / (totalDeposit + totalYield);
        return byNav < supply ? byNav : supply;
    }

    /// @dev Setting a real feed (feedType != FEED_NONE) lists the asset; clearing it (FEED_NONE) delists it.
    ///      Delisting inherits the guards of asset removal (must be paused with zero balance).
    function setFeed(address asset, Feed calldata feed) public override(IPriceOracleRouter, PriceOracleRouter) onlyRole(ADMIN_ROLE) {
        if (feed.feedType == FEED_NONE) {
            _removeAsset(asset);
        } else {
            super.setFeed(asset, feed);
            _addAsset(asset);
        }
    }

    function _addAsset(address asset) internal {
        // Already listed: setFeed only updated the feed, so keep the existing config (id/yieldSplit/paused).
        uint256 existingId = assets[asset].id;
        if (existingId < assetList.length && assetList[existingId] == asset) return;

        uint32 id = uint32(assetList.length);
        // Preserve a previously configured yield split; defaults to 0 for a new asset (set via setAssetConfig).
        assets[asset] = AssetConfig({asset: asset, yieldSplit: assets[asset].yieldSplit, paused: false, id: id});
        assetList.push(asset);
        emit AssetAdd(asset);
    }

    function _removeAsset(address asset) internal {
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

    /// @dev `cfg.asset` and `cfg.id` are ignored: the `asset` param is authoritative and the `assetList` index is managed internally.
    function setAssetConfig(address asset, AssetConfig calldata cfg) external onlyRole(ADMIN_ROLE) {
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (cfg.yieldSplit > BPS) revert BpsTooHigh();
        assets[asset].yieldSplit = cfg.yieldSplit;
        assets[asset].paused = cfg.paused;
        emit AssetConfigUpdate(asset, assets[asset]);
    }

    function put(address asset, uint256 amount) public payable onlyRole(GRINDERS_ROLE) {
        if (amount == 0) revert AmountZero();
        uint256 received = _deposit(msg.sender, address(this), asset, amount);
        uint256 prev = used[asset];
        used[asset] = prev > received ? prev - received : 0;
    }

    //////////////////// DISTRIBUTE ////////////////////

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

        uint256 received = _deposit(msg.sender, address(grinders), asset, amount);

        (graiOut, depositValue) = previewDeposit(asset, received);
        if (depositValue == 0) revert AmountZero();
        if (graiOut == 0) revert AmountZero();

        totalDeposit += depositValue;
        if (address(grinders) == address(this)) totalValue += depositValue;
        _mint(msg.sender, graiOut);
        emit Deposit(msg.sender, graiOut, depositValue);
    }

    /// @inheritdoc IGRAI
    /// @dev GRAI minted and USD value for depositing `amount` of `asset` at current book price.
    function previewDeposit(address asset, uint256 amount) public view returns (uint256 graiOut, uint256 value) {
        value = usdValue(asset, amount);
        uint256 supply = totalSupply();
        if (supply == 0 || totalDeposit == 0) return (value, value);
        graiOut = (value * supply) / (totalDeposit + totalYield);
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
        // tax is based on Harberger`s tax
        tax = (graiAmount * config.askAprBps * duration) / (uint256(BPS) * 365 days);
        lot = graiAmount - tax;
    }

    //////////////////// FILL ASK ////////////////////

    function fillAsk(
        address seller,
        uint256 graiAmount,
        uint256 paymentMax
    ) public payable {
        address buyer = msg.sender;
        Ask storage entry = asks[seller];
        if (entry.startTime == 0) revert AskNotFound();

        (uint256 graiOut, uint256 payment) = previewFillAsk(seller, graiAmount, block.timestamp);
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
        _pay(buyer, seller, asset, payment);
        emit AskFill(buyer, seller, asset, graiOut, payment);
    }

    /// @inheritdoc IGRAI
    /// @dev Dutch payment: maxPayment → minPayment over `duration`, scaled by lot size.
    ///      Caps fill to `graiRemaining` and seller balance; returns `(fill, payment)`.
    ///      `timestamp` is the reference time for the dutch price (pass `block.timestamp` for the live price).
    function previewFillAsk(
        address seller,
        uint256 graiAmount,
        uint256 timestamp
    ) public view returns (uint256 graiOut, uint256 payment) {
        Ask storage entry = asks[seller];
        if (entry.startTime == 0) revert AskNotFound();

        if (graiAmount == type(uint256).max) graiAmount = entry.graiRemaining;
        if (graiAmount > entry.graiRemaining) graiAmount = entry.graiRemaining;
        if (graiAmount > balanceOf(seller)) graiAmount = balanceOf(seller);
        if (graiAmount == 0) return (0, 0);

        graiOut = graiAmount;
        uint256 elapsed = timestamp > entry.startTime ? timestamp - entry.startTime : 0;
        uint256 price = dutchPrice(entry.maxPayment, entry.minPayment, elapsed, entry.duration);
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
    ) public {
        address buyer = msg.sender;
        (uint256 lot, uint256 tax) = previewBid(buyer, asset, maxPayment, minPayment, duration, graiAmount);
        uint32 id = bids[buyer].id;
        if (bids[buyer].startTime == 0) {
            id = uint32(bidsList.length);
            bidsList.push(buyer);
        }
        bids[buyer] = Bid({
            asset: asset,
            graiRemaining: lot,
            graiInitial: lot,
            maxPayment: maxPayment,
            minPayment: minPayment,
            startTime: block.timestamp,
            duration: duration,
            id: id
        });
        // Listing cost is Harberger tax charged on top of the dutch payment.
        if (tax > 0) _pay(buyer, treasury, asset, tax);
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
        // Harberger tax is charged on top of the dutch payment.
        tax = (maxPayment * config.bidAprBps * duration) / (uint256(BPS) * 365 days);

        // Dutch payment (up to `maxPayment`) plus `tax` must be covered by soft allowance / balance.
        uint256 total = maxPayment + tax;
        if (IERC20(asset).allowance(buyer, address(this)) < total) revert InvalidAmount();
        if (IERC20(asset).balanceOf(buyer) < total) revert InvalidAmount();
        lot = graiAmount;
    }

    //////////////////// FILL BID ////////////////////

    /// @inheritdoc IGRAI
    /// @dev ERC20 only: seller (`msg.sender`) fills `buyer`'s bid; payment is pulled from buyer allowance.
    function fillBid(address buyer, uint256 graiAmount, uint256 paymentMin) public {
        address seller = msg.sender;
        Bid storage entry = bids[buyer];
        (uint256 graiIn, uint256 payment) = previewFillBid(buyer, seller, graiAmount, block.timestamp);
        
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
        _pay(buyer, seller, asset, payment);
        emit BidFill(seller, buyer, asset, graiIn, payment);
    }

    /// @inheritdoc IGRAI
    /// @dev Dutch payment: maxPayment → minPayment over `duration`, scaled by lot size.
    ///      Caps fill to `graiRemaining` and seller GRAI balance.
    ///      `timestamp` is the reference time for the dutch price (pass `block.timestamp` for the live price).
    function previewFillBid(
        address buyer,
        address seller,
        uint256 graiAmount,
        uint256 timestamp
    ) public view returns (uint256 graiIn, uint256 payment) {
        Bid storage entry = bids[buyer];
        if (entry.startTime == 0) revert BidNotFound();

        if (graiAmount == type(uint256).max) graiAmount = entry.graiRemaining;
        if (graiAmount > entry.graiRemaining) graiAmount = entry.graiRemaining;
        uint256 sellerBal = balanceOf(seller);
        if (graiAmount > sellerBal) graiAmount = sellerBal;
        if (graiAmount == 0) return (0, 0);

        graiIn = graiAmount;
        uint256 elapsed = timestamp > entry.startTime ? timestamp - entry.startTime : 0;
        uint256 price = dutchPrice(entry.maxPayment, entry.minPayment, elapsed, entry.duration);
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

    //////////////////// VOTE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev `vote(0)` withdraws all of the caller's escrowed GRAI (full unvote).
    function vote(uint256 graiAmount) public {
        address voter = msg.sender;
        Vote storage entry = votes[voter];

        if (graiAmount == 0) {
            uint256 locked = entry.amount;
            if (locked == 0) revert AmountZero();
            totalVoted -= locked;
            _removeVoter(voter);
            _transfer(address(this), voter, locked);
            emit Voted(voter, 0, totalVoted);
            return;
        }

        if (graiAmount > balanceOf(voter)) revert InvalidAmount();

        _transfer(voter, address(this), graiAmount);
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

    //////////////////// BRIBE ////////////////////

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
            if (premium > 0) _withdraw(address(sgrai), asset, premium);
        } else {
            if (bribeAmount > 0) _pay(briber, voter, asset, bribeAmount);
            if (premium > 0) _pay(briber, address(sgrai), asset, premium);
        }

        // Escrowed GRAI is released to the briber.
        _transfer(address(this), briber, graiAmount);
        emit Bribe(briber, voter, graiAmount, total, totalVoted);
    }

    /// @inheritdoc IGRAI
    /// @dev Book value of `graiAmount` = `graiAmount * (totalDeposit + totalYield) / totalSupply`, priced in USD
    ///      and converted to the senior asset (`sgrai.hedgeAsset()`).
    function previewBribe(
        address voter,
        uint256 graiAmount
    ) public view returns (address asset, uint256 bribeAmount, uint256 premium) {
        if (graiAmount == 0) revert AmountZero();
        Vote storage entry = votes[voter];
        if (graiAmount > entry.amount) revert InvalidAmount();

        asset = sgrai.hedgeAsset();
        uint256 supply = totalSupply();
        bribeAmount = supply == 0 ? 0 : (graiAmount * (totalDeposit + totalYield)) / supply;
        premium = (bribeAmount * config.bribePremiumBps) / BPS;
    }

    //////////////////// LIQUIDATE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Flips the liquidation flag and pauses/unpauses every asset accordingly. Opening requires quorum.
    function liquidate() public onlyRole(ADMIN_ROLE) {
        bool opening = !liquidation;
        if (opening && !hasQuorum()) revert LiquidationQuorumNotMet();
        if (opening) {
            uint256 len = assetList.length;
            for (uint256 i; i < len; ) {
                address asset = assetList[i];
                assets[asset].paused = opening;
                emit AssetConfigUpdate(asset, assets[asset]);
                unchecked { ++i; }
            }
            totalValue += totalDeposit;
            totalDeposit = 0;
        }
        liquidation = opening;
        emit Liquidate(opening, totalVoted, totalSupply());
    }

    //////////////////// INTERNAL HELPERS ////////////////////

    /// @dev `from` is the logical payer. ETH cannot be pulled from a third party: it must be funded
    ///      by the caller's `msg.value` and is forwarded from this contract, so `from` is ignored for ETH.
    ///      ERC20 is pulled directly from `from` via `safeTransferFrom`.
    function _pay(address from, address to, address asset, uint256 payment) private {
        if (asset == address(0)) {
            if (msg.value != payment) revert ValueMismatch();
            (bool ok,) = to.call{value: payment}("");
            if (!ok) revert EthTransferFailed();
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(from, to, payment);
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
            if (to != address(this)) {
                (bool ok,) = payable(to).call{value: amount}("");
                if (!ok) revert EthTransferFailed();
            }
            received = amount;
        } else {
            if (msg.value > 0) revert UnexpectedValue();
            uint256 before = IERC20(asset).balanceOf(to);
            IERC20(asset).safeTransferFrom(from, to, amount);
            received = IERC20(asset).balanceOf(to) - before;
        }
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

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
