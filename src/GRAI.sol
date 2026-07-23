// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGRAI, IERC20, IERC20Metadata, IPriceOracleRouter} from "./interfaces/IGRAI.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IGrinders} from "./interfaces/IGrinders.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";
import {PriceOracleRouter} from "./PriceOracleRouter.sol";

/// @title GRAI (implementation)
/// @author Chikhladze Vakhtanh (GH: @Pozzitron1337)
/// @notice Condition-redeemable fund-share ERC20. Roles:
///         holder → `lock` (dividends) and/or `vote` (quorum; auto-locks wallet shortfall) → voter;
///         anyone may `bribe` to buy out a voter's vote. Yield splits per `config` cuts.
/// @dev Interact only via the ERC1967Proxy. Admin authority is Ownable2Step `owner`.
contract GRAI is
    IGRAI,
    PriceOracleRouter,
    ERC20Upgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 100_00; // 100%
    uint256 private constant REWARD_PRECISION = 1e18;

    /// @notice Canonical WETH used when a native ETH push is rejected by the recipient.
    IWETH public weth;

    /// @notice High-risk pool that generates yield.
    IGrinders public grinders;

    /// @notice Fee recipient for protocol profit from `distribute`.
    address public treasury;

    /// @notice Listed assets eligible for deposit, yield distribution, and liquidation redemption.
    address[] public assetList;

    /// @notice Per-asset listing config (`id` indexes `assetList`, `paused` gates user flows).
    mapping(address asset => AssetConfig) public assets;

    /// @notice One open Dutch auction per sold asset (`remaining` = asset qty; payment = GRAI).
    mapping(address asset => DutchAuction) public auctions;

    mapping(address custodian => mapping(address asset => uint256)) public yieldBy;

    /// @notice Per-user lock + liquidation vote (GRAI held by this contract while locked).
    mapping(address account => Escrow) public escrows;

    /// @notice Accounts with an open escrow; `escrows[account].accountId` is the index here.
    address[] public accounts;

    /// @notice Accounts with an open liquidation vote; `escrows[account].voterId` is the index here.
    address[] public voters;

    /// @notice Cumulative yield dividend of `asset` per actively locked GRAI, scaled by 1e18.
    /// @dev Buyback GRAI vote-reward index is `accDividendShare[address(this)]` (per voted share).
    mapping(address asset => uint256) public accDividendShare;

    /// @notice Yield / vote-reward index already accounted for an account.
    /// @dev Buyback GRAI vote rewards use `asset = address(this)` and track against `voted`.
    mapping(address account => mapping(address asset => uint256)) public dividendDebt;

    /// @notice Yield dividends (or buyback GRAI) accrued but not yet claimed.
    /// @dev Buyback GRAI vote rewards use `asset = address(this)`.
    mapping(address account => mapping(address asset => uint256)) public claimableDividend;

    /// @notice Buyback GRAI parked when `totalVoted == 0` or too small to move the index.
    /// @dev Tokens stay on this contract until a later distribution with active votes.
    uint256 public pendingVoteRewards;

    uint256 public totalLocked;

    uint256 public totalVoted;

    uint256 public totalValue;

    /** SLOT BEGIN */

    /// @notice Asset used for bribe payments.
    /// @dev If zero address, asset is the native token (ETH); otherwise, it's an ERC20.
    ///      SHOULD NOT (RFC 2119) be a fee-on-transfer or otherwise deflationary token:
    ///      `bribe` prices from the nominal `_pay` amount, not the credited balance delta
    ///      (unlike `deposit` / `distribute`).
    address public bribeAsset;

    /// @notice True after `liquidate` opens until `resettle` closes it.
    bool public liquidation;

    /// @notice Timestamp when the current liquidation opened; zero while liquidation is closed.
    uint48 public liquidationAt;

    /** SLOT end 20 + 1 + 6 */

    /// @notice Bribe premium, liquidation quorum, unlock fee, and timing.
    ProtocolConfig public config;

    /// @dev Storage gap for future upgrades.
    uint256[21] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, address weth_) public initializer {
        if (admin_ == address(0) || weth_ == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __ERC20_init("Grinders Artificial Index", "GRAI");
        __Ownable_init(admin_);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        weth = IWETH(weth_);
        grinders = IGrinders(admin_);
        treasury = admin_;
        config = ProtocolConfig({
            auctionCutBps: 50_00, // 50%
            dividendCutBps: 30_00, // 30%
            treasuryCutBps: 20_00, // 20%
            bribePremiumBps: 2_00, // 2%
            quorumBps: 66_67, // 66.67%
            auctionFloorBps: 20_00, // 20% of mint ask (−80% max discount)
            unlockFeeBps: 10_00, // 10% at lock time
            auctionDuration: uint32(365 days),
            liquidationPeriod: uint32(24 hours),
            redeemPeriod: uint32(7 days),
            unlockFeeDuration: uint32(24 hours)
        });
    }

    function setProtocolConfig(ProtocolConfig calldata cfg) external onlyOwner {
        if (
            cfg.auctionCutBps > BPS
            || cfg.dividendCutBps > BPS
            || cfg.treasuryCutBps > BPS
            || cfg.bribePremiumBps > BPS
            || cfg.quorumBps > BPS
            || cfg.auctionFloorBps > BPS
            || cfg.unlockFeeBps > BPS
        ) revert BpsTooHigh();
        if (uint256(cfg.auctionCutBps) + cfg.dividendCutBps + cfg.treasuryCutBps != BPS) {
            revert InvalidCuts();
        }
        if (cfg.auctionDuration <= 7 days) revert AuctionDurationTooShort();
        config = cfg;
        emit ConfigUpdate(cfg);
    }

    function setGrinders(address grinders_) external onlyOwner {
        if (grinders_ == address(0)) revert ZeroAddress();
        if (address(IGrinders(grinders_).grai()) != address(this)) revert GrindersGraiMismatch();
        grinders = IGrinders(grinders_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
    }

    /// @notice Set the asset used for bribe payments.
    /// @dev Requires a price feed. Auctions price in GRAI, so open lots / locks do not block the switch.
    function setBribeAsset(address bribeAsset_) external onlyOwner {
        if (feeds[bribeAsset_].feedType == FEED_NONE) revert AssetUnknown();
        bribeAsset = bribeAsset_;
    }

    /// @dev Setting a real feed (feedType != FEED_NONE) lists the asset; clearing it (FEED_NONE) delists it.
    ///      Delisting inherits the guards of asset removal (must be paused with zero balance).
    function setFeed(address asset, Feed calldata feed) public override(IPriceOracleRouter, PriceOracleRouter) onlyOwner {
        if (feed.feedType == FEED_NONE) {
            _removeAsset(asset);
        } else {
            super.setFeed(asset, feed);
            _addAsset(asset);
        }
    }

    /// @dev `cfg.asset` and `cfg.id` are ignored: the `asset` param is authoritative and the `assetList` index is managed internally.
    function setAssetConfig(address asset, AssetConfig calldata cfg) external onlyOwner {
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        assets[asset].paused = cfg.paused;
        emit AssetConfigUpdate(asset, assets[asset]);
    }

    receive() external payable {}

    /// @inheritdoc IGRAI
    function getAssets() public view returns (address[] memory) {
        return assetList;
    }

    /// @inheritdoc IGRAI
    function getAuctions() public view returns (address[] memory list) {
        uint256 len = assetList.length;
        list = new address[](len);
        uint256 count;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            if (auctions[asset].startTime != 0) {
                list[count] = asset;
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
        assembly ("memory-safe") {
            mstore(list, count)
        }
    }

    function getAccounts() public view returns (address[] memory) {
        return accounts;
    }

    function getVoters() external view returns (address[] memory) {
        return voters;
    }

    /// @inheritdoc IERC1046
    function tokenURI() public pure returns (string memory) {
        return "https://grindurus.xyz/metadata.json";
    }

    function decimals() public pure override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return USD_DECIMALS;
    }

    /// @inheritdoc IGRAI
    /// @dev Quorum intentionally uses the live supply. Deposits add new backing and unvoted GRAI,
    ///      reducing liquidation support until voters again reach the configured share of supply.
    function hasQuorum() public view returns (bool) {
        return totalVoted * BPS >= totalSupply() * config.quorumBps;
    }

    //////////////////// DISTRIBUTE ////////////////////

    /// @notice Pull yield and split per `config` auction / dividend / treasury cuts.
    function distribute(address asset, uint256 yieldAmount) public payable {
        _requireNotLiquidation();
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (yieldAmount == 0) revert AmountZero();

        uint256 received = _pay(msg.sender, address(this), asset, yieldAmount);
        yieldBy[msg.sender][asset] += received;

        uint256 treasuryCut = (received * config.treasuryCutBps) / BPS;
        uint256 dividendCut = (received * config.dividendCutBps) / BPS;
        uint256 auctionCut = received - treasuryCut - dividendCut;

        if (treasuryCut > 0) _withdraw(treasury, asset, treasuryCut);
        if (dividendCut > 0) _distributeDividend(asset, dividendCut);
        if (auctionCut > 0) _place(asset, auctionCut);

        emit Distribute(msg.sender, asset, received, auctionCut, dividendCut, treasuryCut);
    }

    //////////////////// DEPOSIT ////////////////////

    /// @inheritdoc IGRAI
    function deposit(address asset, uint256 amount, bool lock_) public payable returns (uint256 graiOut, uint256 value) {
        _requireNotLiquidation();
        if (amount == 0) revert AmountZero();
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (assets[asset].paused) revert Paused();

        uint256 received = _pay(msg.sender, address(grinders), asset, amount);

        (value, graiOut) = previewDeposit(asset, received);
        if (value == 0) revert AmountZero();
        if (graiOut == 0) revert AmountZero();

        totalValue += value;
        _mint(msg.sender, graiOut);
        if (lock_) lock(graiOut);
        emit Deposit(msg.sender, graiOut, asset, received, value);
    }

    /// @inheritdoc IGRAI
    /// @dev Mints shares at book value: `graiOut = value * totalSupply / totalValue`, or `value` when
    ///      `totalValue == 0` (bootstrap). While `totalSupply == totalValue`, that is 1 GRAI per $1 book
    ///      (USD_DECIMALS). Yield held by GRAI is excluded from `totalValue` — it is a separate pool for
    ///      `buyback` / dividends / liquidation upside, not part of the deposit exchange rate.
    function previewDeposit(address asset, uint256 amount) public view returns (uint256 value, uint256 graiOut) {
        value = usdValue(asset, amount);
        graiOut = totalValue > 0 ? (value * totalSupply()) / totalValue : value;
    }

    //////////////////// AUCTION BUY ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Buyer pays GRAI (Dutch ask) and receives the listed asset; GRAI in funds voter rewards.
    ///      `graiIn` can still floor to 0 on dust fills; full-lot ask decays to `auctionFloorBps` of mint,
    ///      not to free clearance (unless floor is configured to 0).
    function buyback(address asset, uint256 amount) public {
        _requireNotLiquidation();
        address buyer = msg.sender;

        (uint256 graiIn, uint256 amountOut) = previewBuyback(asset, amount, block.timestamp);

        DutchAuction storage entry = auctions[asset];
        if (entry.remaining > amountOut) {
            entry.remaining -= amountOut;
        } else {
            delete auctions[asset];
        }

        // graiIn may be 0 once the Dutch ask has decayed — still deliver amountOut.
        if (graiIn > 0) {
            _transfer(buyer, address(this), graiIn);
            _distributeVoteRewards(graiIn);
        }
        _withdraw(buyer, asset, amountOut);
        emit Buyback(buyer, asset, graiIn, amountOut);
    }

    /// @inheritdoc IGRAI
    /// @dev Dutch GRAI ask: `maxPayment` → `minPayment` over `entry.duration` (snapshotted from
    ///      `config.auctionDuration` at `_place`), scaled by buy size. Caps to auction remaining.
    function previewBuyback(
        address asset,
        uint256 amount,
        uint256 timestamp
    ) public view returns (uint256 graiIn, uint256 amountOut) {
        DutchAuction storage entry = auctions[asset];
        if (entry.startTime == 0) revert AuctionNotFound();

        if (amount == type(uint256).max) amount = entry.remaining;
        if (amount > entry.remaining) amount = entry.remaining;
        if (amount == 0) return (0, 0);

        amountOut = amount;
        uint256 elapsed = timestamp > entry.startTime ? timestamp - entry.startTime : 0;
        uint256 ask = _dutchAmount(entry.maxPayment, entry.minPayment, elapsed, entry.duration);
        graiIn = entry.initial > 0 ? (ask * amountOut) / entry.initial : 0;
    }

    //////////////////// LOCK ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Escrows GRAI for dividend eligibility. Not required before `vote` — `vote` locks any
    ///      shortfall itself. Exit locked (unvoted) GRAI via `unlock`.
    function lock(uint256 graiAmount) public {
        _requireNotLiquidation();
        if (graiAmount == 0) revert AmountZero();
        address account = msg.sender;
        Escrow storage entry = escrows[account];

        if (graiAmount > balanceOf(account)) revert InvalidAmount();
        _accrueDividends(account);
        totalLocked += graiAmount;
        if (entry.amount == 0) _addAccount(account);
        entry.amount += graiAmount;
        entry.lockedAt = uint48(block.timestamp);
        _syncDividendDebts(account);

        _transfer(account, address(this), graiAmount);
        emit Locked(account, graiAmount, totalLocked);
    }

    //////////////////// UNLOCK ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Accrues residual lock rewards/dividends, takes decaying unlock fee → vote rewards, clamps
    ///      excess votes, and returns `graiAmount - fee` to wallet. `graiAmount == 0` is allowed for
    ///      claim-only (accrue + optional `claimAll_`, no unlock). Optional `claimAll_` pays all
    ///      listed-asset dividends to `msg.sender` after accrual.
    function unlock(uint256 graiAmount, bool claimAll_) public {
        _requireNotLiquidation();
        address account = msg.sender;
        Escrow storage entry = escrows[account];
        if (graiAmount > entry.amount) revert InvalidAmount();

        _accrueDividends(account);
        _accrueVoteReward(account);
        _payVoteReward(account);

        if (graiAmount > 0) {
            (uint256 net, uint256 fee) = previewUnlock(account, graiAmount, block.timestamp);

            totalLocked -= graiAmount;
            entry.amount -= graiAmount;
            _clampVote(account);
            _syncDividendDebts(account);
            _syncVoteRewardDebt(account);

            if (fee > 0) _distributeVoteRewards(fee);
            if (net > 0) _transfer(address(this), account, net);
            emit Unlock(account, graiAmount, totalLocked);
            if (entry.amount == 0) _removeAccount(account);
        }

        if (claimAll_) claimAll(account);
    }

    /// @inheritdoc IGRAI
    /// @dev Linear decay of `unlockFeeBps` → 0 over `unlockFeeDuration` since `lockedAt` at `timestamp`.
    ///      Returns `net = graiAmount - fee` (GRAI returned to wallet) and `fee` (→ vote rewards).
    function previewUnlock(address account, uint256 graiAmount, uint256 timestamp)
        public
        view
        returns (uint256 net, uint256 fee)
    {
        if (config.unlockFeeBps == 0 || config.unlockFeeDuration == 0 || graiAmount == 0) {
            return (graiAmount, 0);
        }
        uint256 lockedAt = escrows[account].lockedAt;
        uint256 elapsed = timestamp > lockedAt ? timestamp - lockedAt : 0;
        if (elapsed >= config.unlockFeeDuration) {
            return (graiAmount, 0);
        }
        uint256 feeBps = (uint256(config.unlockFeeBps) * (config.unlockFeeDuration - elapsed)) / config.unlockFeeDuration;
        fee = (graiAmount * feeBps) / BPS;
        net = graiAmount - fee;
    }

    //////////////////// CLAIM ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Pending = stored `claimableDividend` plus unrealized accrual vs `accDividendShare`.
    function previewClaim(address holder, address asset) public view returns (uint256 amount) {
        if (asset == address(this)) revert AssetUnknown();
        uint256 accumulated = (escrows[holder].amount * accDividendShare[asset]) / REWARD_PRECISION;
        amount = claimableDividend[holder][asset] + accumulated - dividendDebt[holder][asset];
    }

    /// @inheritdoc IGRAI
    function claim(address holder, address asset) public returns (uint256 amount) {
        _requireNotLiquidation();
        if (asset == address(this)) revert AssetUnknown();
        _accrueDividend(holder, asset);
        amount = claimableDividend[holder][asset];
        if (amount == 0) return 0;
        claimableDividend[holder][asset] = 0;
        _withdraw(holder, asset, amount);
        emit Dividend(holder, asset, amount);
    }

    /// @inheritdoc IGRAI
    /// @dev One entry per listed asset in `assetList` order (amount may be 0).
    function previewClaimAll(address holder)
        public
        view
        returns (address[] memory claimAssets, uint256[] memory amounts)
    {
        uint256 len = assetList.length;
        claimAssets = new address[](len);
        amounts = new uint256[](len);
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            claimAssets[i] = asset;
            amounts[i] = previewClaim(holder, asset);
            unchecked { ++i; }
        }
    }

    /// @inheritdoc IGRAI
    /// @dev Pays every listed-asset dividend for `holder` (skips buyback GRAI vote-reward key).
    function claimAll(address holder) public {
        uint256 len = assetList.length;
        for (uint256 i; i < len;) {
            claim(holder, assetList[i]);
            unchecked { ++i; }
        }
    }

    //////////////////// VOTE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev No prior `lock` needed: locks any shortfall from the wallet, then commits toward quorum.
    ///      Voted GRAI earns buyback rewards and is buyable via `bribe`.
    function vote(uint256 graiAmount) public {
        _requireNotLiquidation();
        if (graiAmount == 0) revert AmountZero();
        address voter = msg.sender;
        Escrow storage entry = escrows[voter];

        uint256 needLocked = entry.voted + graiAmount;
        if (entry.amount < needLocked) lock(needLocked - entry.amount);

        _accrueVoteReward(voter);
        if (entry.voted == 0) _addVoter(voter);
        totalVoted += graiAmount;
        entry.voted += graiAmount;
        entry.votedAt = uint48(block.timestamp);
        _syncVoteRewardDebt(voter);

        // Rewards accrued while there were no voters go to the first active vote(s).
        if (pendingVoteRewards > 0) {
            _distributeVoteRewards(0);
            _accrueVoteReward(voter);
        }

        emit Vote(voter, graiAmount, totalVoted);
    }

    //////////////////// BRIBE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Briber (anyone) buys out `voter`'s voted GRAI for `previewBribe` in `bribeAsset`.
    ///      `bribeBody` goes to the voter; `bribePremium` splits like yield. Briber receives the escrowed GRAI
    ///      (vote + lock reduced together). Self-bribe costs only the premium.
    function bribe(address voter, uint256 graiAmount) public payable {
        _requireNotLiquidation();
        address briber = msg.sender;

        uint256 bribeAmount = previewBribe(voter, graiAmount);
        uint256 bribeBody = (bribeAmount * BPS) / (BPS + config.bribePremiumBps);
        uint256 bribePremium = bribeAmount - bribeBody;

        uint256 treasuryCut = (bribePremium * config.treasuryCutBps) / BPS;
        uint256 dividendCut = (bribePremium * config.dividendCutBps) / BPS;
        uint256 auctionAmount = bribePremium - treasuryCut - dividendCut;

        Escrow storage entry = escrows[voter];
        _accrueDividends(voter);
        _accrueVoteReward(voter);
        _payVoteReward(voter);

        totalVoted -= graiAmount;
        totalLocked -= graiAmount;
        entry.voted -= graiAmount;
        entry.amount -= graiAmount;
        _syncDividendDebts(voter);
        _syncVoteRewardDebt(voter);
        if (entry.voted == 0) _removeVoter(voter);
        if (entry.amount == 0) _removeAccount(voter);

        _transfer(address(this), briber, graiAmount);
        _pay(briber, address(this), bribeAsset, bribeAmount);

        if (auctionAmount > 0) _place(bribeAsset, auctionAmount);
        if (dividendCut > 0) _distributeDividend(bribeAsset, dividendCut);
        if (treasuryCut > 0) _withdraw(treasury, bribeAsset, treasuryCut);
        if (bribeBody > 0) _withdraw(voter, bribeAsset, bribeBody);

        emit Bribe(briber, voter, bribeAsset, graiAmount, bribeAmount, totalVoted);
    }

    /// @inheritdoc IGRAI
    /// @dev `bribePremiumBps` of the book value of voted `graiAmount`, converted to `bribeAsset`.
    function previewBribe(address voter, uint256 graiAmount) public view returns (uint256 bribeAmount) {
        if (feeds[bribeAsset].feedType == FEED_NONE) revert BribeAssetUnset();
        if (graiAmount == 0) revert AmountZero();
        Escrow storage entry = escrows[voter];
        if (graiAmount > entry.voted) revert InvalidAmount();

        uint256 supply = totalSupply();
        uint256 value = supply > 0 ? (graiAmount * totalValue) / supply : 0;
        bribeAmount = _bribeAssetAmount(value) * (BPS + config.bribePremiumBps) / BPS;
        if (bribeAmount == 0) revert AmountZero();
    }

    //////////////////// LIQUIDATE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Opens liquidation after vote quorum: cancel open yield auctions into the redeem basket,
    ///      pause every listed asset, and start the claim clock at `liquidationAt`.
    function liquidate() public onlyOwner {
        _requireNotLiquidation();
        if (!hasQuorum()) revert LiquidationQuorumNotMet();

        uint256 len = assetList.length;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            if (auctions[asset].startTime != 0) {
                delete auctions[asset];
                emit AuctionUpdate(asset, 0, 0, 0);
            }
            assets[asset].paused = true;
            emit AssetConfigUpdate(asset, assets[asset]);
            unchecked { ++i; }
        }
        liquidation = true;
        liquidationAt = uint48(block.timestamp);
        emit Liquidate(liquidation);
    }

    //////////////////// REDEEM ////////////////////

    /// @inheritdoc IGRAI
    function redeem(uint256 graiAmount) external nonReentrant {
        address holder = msg.sender;
        if (!liquidation) revert LiquidationClosed();

        (address[] memory assetOuts, uint256[] memory amounts) = previewRedeem(holder, graiAmount);
        uint256 supply = totalSupply();
        uint256 value = supply > 0 ? (totalValue * graiAmount) / supply : 0;

        uint256 walletAmount = balanceOf(holder);
        _accrueDividends(holder);
        _accrueVoteReward(holder);
        _payVoteReward(holder);
        uint256 walletBurn = graiAmount < walletAmount ? graiAmount : walletAmount;
        if (walletBurn > 0) _burn(holder, walletBurn);

        uint256 escrowBurn = graiAmount - walletBurn;
        if (escrowBurn > 0) {
            Escrow storage entry = escrows[holder];
            if (escrowBurn > entry.amount) revert InvalidAmount();
            totalLocked -= escrowBurn;
            entry.amount -= escrowBurn;
            _syncDividendDebts(holder);
            _clampVote(holder);
            _syncVoteRewardDebt(holder);
            _burn(address(this), escrowBurn);
            if (entry.amount == 0) _removeAccount(holder);
        }
        totalValue -= value;

        uint256 len = assetOuts.length;
        for (uint256 i; i < len;) {
            _withdraw(holder, assetOuts[i], amounts[i]);
            unchecked { ++i; }
        }
        emit Redeem(holder, graiAmount, value);
    }

    /// @inheritdoc IGRAI
    function previewRedeem(
        address holder,
        uint256 graiAmount
    ) public view returns (address[] memory assetOuts, uint256[] memory amounts) {
        if (!liquidation) revert LiquidationClosed();
        /// @dev Consolidation window: when liquidation opens, backing is still on Grinders and
        ///      custodians, while `redeem` pays only from tokens already held here. Blocking
        ///      claims until `liquidationPeriod` elapses gives keepers time to run permissionless
        ///      `Grinders.liquidate` sweeps; without it, early redeemers could burn shares and cut
        ///      `totalValue` while `previewRedeem` returns zero assets, forfeiting backing to
        ///      later claimants.
        if (block.timestamp < liquidationAt + config.liquidationPeriod) revert LiquidationDelay();
        uint256 supply = totalSupply();
        Escrow storage entry = escrows[holder];
        uint256 holderAmount = balanceOf(holder) + entry.amount;
        if (graiAmount == 0 || graiAmount > holderAmount) revert InvalidAmount();

        uint256 len = assetList.length;
        assetOuts = new address[](len);
        amounts = new uint256[](len);
        uint256 count;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            uint256 assetBalance = _balance(asset);
            if (assetBalance > 0) {
                uint256 amount = (assetBalance * graiAmount) / supply;
                if (amount > 0) {
                    assetOuts[count] = asset;
                    amounts[count] = amount;
                    unchecked {
                        ++count;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }
        assembly ("memory-safe") {
            mstore(assetOuts, count)
            mstore(amounts, count)
        }
    }

    //////////////////// RESETTLE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Permissionless after `liquidationPeriod + redeemPeriod`: return unredeemed basket
    ///      balances to Grinders, unpause every listed asset, and clear the claim clock so the fund
    ///      can accept deposits again. Sets `totalValue` to leftover basket NAV (up or down).
    ///      If no shares remain, book is cleared to zero even if dust NAV is swept to Grinders.
    function resettle() public {
        if (!liquidation || liquidationAt == 0) revert LiquidationClosed();
        if (block.timestamp < uint256(liquidationAt) + config.liquidationPeriod + config.redeemPeriod) {
            revert RedeemPeriodActive();
        }
        uint256 totalNAV = 0;
        uint256 len = assetList.length;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            assets[asset].paused = false;
            uint256 remaining = _balance(asset);
            if (remaining > 0) {
                totalNAV += usdValue(asset, remaining);
                _withdraw(address(grinders), asset, remaining);
            }
            emit AssetConfigUpdate(asset, assets[asset]);
            unchecked { ++i; }
        }
        // Avoid orphan book with zero supply (would break the next deposit: graiOut = 0).
        totalValue = totalSupply() > 0 ? totalNAV : 0;

        liquidation = false;
        liquidationAt = 0;
        emit Liquidate(liquidation);
    }

    ////////////////////////////// INTERNAL HELPERS //////////////////////////////

    function _requireNotLiquidation() internal view {
        if (liquidation) revert LiquidationOpen();
    }

    /// @notice Contract balance of `asset` (`address(0)` = native ETH).
    function _balance(address asset) internal view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice Linear Dutch amount: decays `maxAmount` → `minAmount` over `duration`; `elapsed` past
    ///         `duration` clamps to `minAmount`.
    function _dutchAmount(
        uint256 maxAmount,
        uint256 minAmount,
        uint256 elapsed,
        uint256 duration
    ) internal pure returns (uint256) {
        if (elapsed >= duration) return minAmount;
        return maxAmount - ((maxAmount - minAmount) * elapsed) / duration;
    }

    /// @notice Convert a USD amount (`USD_DECIMALS`) into `bribeAsset` base units via oracle.
    function _bribeAssetAmount(uint256 usdAmount) internal view returns (uint256) {
        (uint256 price, uint8 pdec) = getPrice(bribeAsset);
        uint8 adec = bribeAsset == address(0) ? 18 : IERC20Metadata(bribeAsset).decimals();
        return (usdAmount * (10 ** adec) * (10 ** pdec)) / (price * (10 ** USD_DECIMALS));
    }

    /// @dev Merge `amount` into the asset auction and restart the Dutch clock. Payment is always the
    ///      current mint-price GRAI for the full lot (`previewDeposit`) — no average of a stale ask.
    ///      Decays to `auctionFloorBps` of that mint ask over `auctionDuration`. Clock restart is
    ///      intentional: each `_place` rebuilds `maxPayment` at the live mint ask.
    function _place(address asset, uint256 amount) internal {
        if (asset == address(this)) revert AssetUnknown();
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();

        DutchAuction storage entry = auctions[asset];
        uint256 remaining = entry.remaining + amount;
        (, uint256 maxPayment) = previewDeposit(asset, remaining);
        if (maxPayment == 0) revert AmountZero();

        entry.asset = asset;
        entry.remaining = remaining;
        entry.initial = remaining;
        entry.maxPayment = maxPayment;
        entry.minPayment = (maxPayment * config.auctionFloorBps) / BPS;
        entry.startTime = block.timestamp;
        entry.duration = config.auctionDuration;
        emit AuctionUpdate(asset, remaining, maxPayment, block.timestamp);
    }

    //////////////////// DIVIDENTS ////////////////////

    function _distributeVoteRewards(uint256 amount) internal {
        uint256 rewards = pendingVoteRewards + amount;
        if (rewards == 0) return;
        if (totalVoted == 0) {
            pendingVoteRewards = rewards;
            return;
        }

        uint256 indexIncrease = (rewards * REWARD_PRECISION) / totalVoted;
        if (indexIncrease == 0) {
            pendingVoteRewards = rewards;
            return;
        }

        uint256 distributed = (indexIncrease * totalVoted) / REWARD_PRECISION;
        pendingVoteRewards = rewards - distributed;
        accDividendShare[address(this)] += indexIncrease;
    }

    function _distributeDividend(address asset, uint256 amount) internal {
        if (amount == 0) return;
        if (totalLocked == 0) {
            _place(asset, amount);
            return;
        }

        uint256 indexIncrease = (amount * REWARD_PRECISION) / totalLocked;
        if (indexIncrease == 0) {
            _place(asset, amount);
            return;
        }

        accDividendShare[asset] += indexIncrease;
    }

    function _accrueDividends(address account) internal {
        uint256 len = assetList.length;
        for (uint256 i; i < len;) {
            _accrueDividend(account, assetList[i]);
            unchecked { ++i; }
        }
    }

    function _accrueDividend(address account, address asset) internal {
        Escrow storage entry = escrows[account];
        uint256 accumulated = (entry.amount * accDividendShare[asset]) / REWARD_PRECISION;
        claimableDividend[account][asset] += accumulated - dividendDebt[account][asset];
        dividendDebt[account][asset] = accumulated;
    }

    function _syncDividendDebts(address account) internal {
        Escrow storage entry = escrows[account];
        uint256 len = assetList.length;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            dividendDebt[account][asset] = (entry.amount * accDividendShare[asset]) / REWARD_PRECISION;
            unchecked { ++i; }
        }
    }

    //////////////////// VOTE REWARDS ////////////////////

    function _accrueVoteReward(address account) internal {
        Escrow storage entry = escrows[account];
        uint256 accumulated = (entry.voted * accDividendShare[address(this)]) / REWARD_PRECISION;
        claimableDividend[account][address(this)] += accumulated - dividendDebt[account][address(this)];
        dividendDebt[account][address(this)] = accumulated;
    }

    function _syncVoteRewardDebt(address account) internal {
        dividendDebt[account][address(this)] =
            (escrows[account].voted * accDividendShare[address(this)]) / REWARD_PRECISION;
    }

    function _payVoteReward(address account) internal returns (uint256 reward) {
        reward = claimableDividend[account][address(this)];
        if (reward == 0) return 0;

        claimableDividend[account][address(this)] = 0;
        _transfer(address(this), account, reward);
        emit VoteReward(account, reward);
    }

    function _addAsset(address asset) internal {
        uint256 existingId = assets[asset].id;
        if (existingId < assetList.length && assetList[existingId] == asset) return;

        uint32 id = uint32(assetList.length);
        assets[asset] = AssetConfig({asset: asset, id: id, paused: false});
        assetList.push(asset);
        emit AssetUpdate(asset, true);
    }

    function _removeAsset(address asset) internal {
        uint256 index = assets[asset].id;
        if (index >= assetList.length || assetList[index] != asset) revert AssetUnknown();
        if (!assets[asset].paused) revert NotPaused();
        if (_balance(asset) > 0) revert AssetBalanceNonZero();

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
        emit AssetUpdate(asset, false);
    }

    function _addAccount(address account) internal {
        escrows[account].account = account;
        escrows[account].accountId = uint32(accounts.length);
        accounts.push(account);
    }

    function _removeAccount(address account) internal {
        _accrueVoteReward(account);
        _payVoteReward(account);
        _clampVote(account);
        dividendDebt[account][address(this)] = 0;
        uint256 index = escrows[account].accountId;
        uint256 lastIndex = accounts.length - 1;
        if (index != lastIndex) {
            address moved = accounts[lastIndex];
            accounts[index] = moved;
            // accounts length / index always fit uint32 in practice
            // forge-lint: disable-next-line(unsafe-typecast)
            escrows[moved].accountId = uint32(index);
        }
        accounts.pop();
        delete escrows[account];
    }

    function _addVoter(address voter) internal {
        escrows[voter].voterId = uint32(voters.length);
        voters.push(voter);
    }

    function _removeVoter(address voter) internal {
        uint256 index = escrows[voter].voterId;
        uint256 lastIndex = voters.length - 1;
        if (index != lastIndex) {
            address moved = voters[lastIndex];
            voters[index] = moved;
            // voters length / index always fit uint32 in practice
            // forge-lint: disable-next-line(unsafe-typecast)
            escrows[moved].voterId = uint32(index);
        }
        voters.pop();
        escrows[voter].voterId = 0;
    }

    /// @dev Ensure `escrows[account].voted` never exceeds locked `amount` after reductions.
    function _clampVote(address account) internal {
        Escrow storage entry = escrows[account];
        uint256 voted = entry.voted;
        if (voted == 0) return;
        uint256 locked = entry.amount;
        if (voted <= locked) return;
        totalVoted -= voted - locked;
        entry.voted = locked;
        if (locked == 0) _removeVoter(account);
    }

    /// @dev Pulls `amount` from `from` to `to` and returns tokens actually credited (FoT-safe for ERC20).
    ///      ETH is funded by `msg.value`; any excess is refunded to `msg.sender`.
    ///      A rejected ETH payment or refund is redirected to `treasury`.
    function _pay(address from, address to, address asset, uint256 amount) internal returns (uint256 paid) {
        if (asset == address(0)) {
            if (msg.value < amount) revert ValueMismatch();
            uint256 refund = msg.value - amount;
            if (to != address(this)) _sendEth(to, amount);
            if (refund > 0) _sendEth(msg.sender, refund);
            paid = amount;
        } else {
            uint256 before = IERC20(asset).balanceOf(to);
            IERC20(asset).safeTransferFrom(from, to, amount);
            paid = IERC20(asset).balanceOf(to) - before;
        }
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) {
            try weth.deposit{value: amount}() {
                weth.transfer(to, amount);
            } catch {
                (bool treasuryOk,) = payable(treasury).call{value: amount}("");
                if (!treasuryOk) revert EthTransferFailed();
            }
        }
    }

    /// @dev Native ETH is pushed first. If the recipient rejects it (no payable fallback), wrap via
    ///      `weth` and ERC20-transfer so bribes / liquidations / treasury cuts still settle.
    function _withdraw(address to, address asset, uint256 amount) internal {
        if (asset == address(0)) {
            if (to == address(0)) revert ZeroAddress();
            if (amount == 0) revert AmountZero();
            _sendEth(to, amount);
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
