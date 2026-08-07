// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGRAI, IERC20, IERC20Metadata, IPriceOracleRouter} from "./interfaces/IGRAI.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IGrinders} from "./interfaces/IGrinders.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";
import {PriceOracleRouter} from "./PriceOracleRouter.sol";

/// @title GRinders Artificial Index (GRAI)
/// @author Chikhladze Vakhtanh (GH: @Pozzitron1337)
/// @notice Condition-redeemable fund-share ERC20. Roles:
///         holder → `lock` (dividends) and/or `vote` (quorum; auto-locks wallet shortfall) → voter;
///         `buyback` locks+votes payment GRAI on the buyer; anyone may `bribe` to buy out a vote.
///         Yield splits per `config` cuts.
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
    using SafeERC20 for IWETH;

    uint16 public constant BPS = 100_00; // 100%
    uint256 private constant PRECISION = 1e18;

    /// @notice Canonical WETH used when a native ETH push is rejected by the recipient.
    IWETH public weth;

    /// @notice Linked Grinders pool: custodian vaults that hold deposited assets and produce
    ///         yield pulled into GRAI via `distribute`.
    IGrinders public grinders;

    /// @notice Linked Treasury: fee sink, sticky referrer NFTs, and claim-time affiliate / beneficiar split.
    ITreasury public treasury;

    /// @notice Listed assets eligible for deposit, yield distribution, and liquidation redemption.
    address[] public assetList;

    /// @notice Per-asset listing + dividend state (`id` / `accShare` / `totalClaimable`).
    /// @dev Deposit pause lives on `feeds[asset].paused` (gates deposits only — not buyback,
    ///      distribute, or claim).
    mapping(address asset => AssetConfig) public assets;

    /// @notice One open Dutch auction per sold asset (`remaining` = asset qty; payment = GRAI).
    mapping(address asset => DutchAuction) public auctions;

    /// @notice Accounts with `escrows[locker].locked > 0`; `lockerId` is the index here.
    /// @dev Full unlock clears list membership only — escrow storage is kept.
    address[] public lockers;

    /// @notice Accounts with an open liquidation vote; `escrows[locker].voterId` is the index here.
    address[] public voters;

    /// @notice Deposit whitelist: only `true` addresses may call `deposit`.
    mapping(address depositor => bool) public isDepositor;

    /// @notice Per-locker lock + liquidation vote (GRAI held by this contract while locked).
    mapping(address locker => Escrow) public escrows;

    /// @notice Per-locker, per-asset ledger: locker dividends (`debt`/`claimable`), custodian yield (`yielded`).
    mapping(address locker => mapping(address asset => Position)) public positions;

    /// @notice Count of addresses with `isDepositor == true`. When `0`, deposit is open (no whitelist).
    uint256 public totalDepositors;

    /// @notice Sum of GRAI escrowed in all active locks (`escrows[locker].locked`).
    uint256 public totalLocked;

    /// @notice Sum of GRAI committed toward liquidation quorum (`escrows[locker].voted`; ≤ `totalLocked`).
    uint256 public totalVoted;

    /// @notice Book NAV in `USD_DECIMALS` (6); mint rate = `value * totalSupply / totalValue`. Moves on
    ///         `deposit`, redeem burn, and `resettle`; excludes yield inventory on this contract.
    uint256 public totalValue;

    /** SLOT BEGIN */

    /// @notice Asset used for bribe payments.
    /// @dev If zero address, native ETH; otherwise an ERC20. Must not be fee-on-transfer:
    ///      `bribe` requires exact `_pay` credit (`received == bribeAmount`) and releases the full
    ///      escrowed GRAI. Owner must only set a non-FoT listed feed asset via `setBribeAsset`.
    address public bribeAsset;

    /// @notice Owner confirmation for non-owner open (2-of-2). Owner toggles via `liquidate` when no quorum;
    ///         cleared on open. Owner with quorum opens without needing this flag.
    bool public confirmed;

    /// @notice True after liquidation opens until `resettle` closes it.
    bool public liquidation;

    /// @notice Timestamp when the current liquidation opened; zero while liquidation is closed.
    uint48 public liquidationAt;

    /** SLOT end 20 + 1 + 1 + 6 */

    /// @notice Bribe premium, liquidation quorum, unlock fee, and timing.
    Config public config;

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
        treasury = ITreasury(admin_);
        config = Config({
            buybackCutBps: 33_33, // 33.33%
            dividendCutBps: 33_34, // 33.34%
            treasuryCutBps: 33_33, // 33.33%
            revenueShareBps: 3_33, // 3.33% of yield from treasury income → affiliates on claim
            claimTipBps: 1_00, // 1%
            quorumBps: 66_67, // 66.67% ~ 2/3
            bribePremiumBps: 2_00, // 2%; also Dutch buyback max discount (floor = BPS − this)
            unlockFeeBps: 10_00, // 10% at lock time
            unlockPenaltyPeriod: uint32(24 hours),
            buybackPeriod: uint32(7 days),
            liquidationPeriod: uint32(24 hours),
            redeemPeriod: uint32(7 days)
        });
    }

    /// @inheritdoc OwnableUpgradeable
    function owner() public view override(OwnableUpgradeable, IGRAI) returns (address) {
        return OwnableUpgradeable.owner();
    }

    /// @dev Owner feed waterfall on `feeds[asset]`:
    ///      - Not listed (`feedType == NONE`): writes `feed` and appends to `assetList` (list).
    ///      - Listed + unpaused: only `feed.paused` is applied; oracle fields are ignored.
    ///      - Listed + paused + `feedType != NONE`: full oracle replace via `_writeFeed` (may set
    ///        `paused: false` in the same call to go live on the new feed).
    ///      - Listed + paused + `feedType == NONE`: delist (`_removeAsset`; requires zero balance).
    ///
    ///      To replace an oracle while deposits stay blocked:
    ///        1) `setFeed` with current (or any) feed and `paused: true`;
    ///        2) `setFeed` with the new oracle fields (`feedType` / `source` / `data` / …) and
    ///           `paused: true` or `false` as desired.
    ///      To delist: pause → drain balance → `setFeed` with `feedType: NONE`.
    function setFeed(address asset, Feed calldata feed) public override(IPriceOracleRouter, PriceOracleRouter) onlyOwner {
        Feed storage f = feeds[asset];
        if (f.feedType == FeedType.NONE) {
            // list asset
            _writeFeed(asset, feed);
            _addAsset(asset);
        } else if (!f.paused) {
            // pause / unpause
            f.paused = feed.paused;
        } else if (feed.feedType == FeedType.NONE) {
            // remove (delist)
            _removeAsset(asset);
        } else {
            // replace oracle
            _writeFeed(asset, feed);
        }
    }

    /// @inheritdoc IGRAI
    /// @dev `id` selects the field(s); `data` is the packed value(s). `ConfigId.FULL` packs the whole slot.
    ///      `DISTRIBUTE_CUTS` is a no-op — yield cuts are set at initialize / via `FULL` only.
    function setConfig(ConfigId id, uint256 data) external onlyOwner {
        // Live redeem/resettle clocks; freeze both windows for the whole liquidation.
        _requireNotLiquidation();

        Config memory cfg = config;
        // Narrowing is intentional: each ConfigId writes a fixed-width field window.
        // forge-lint: disable-start(unsafe-typecast)
        if (id == ConfigId.FULL) {
            cfg = _unpackConfig(data);
        } else if (id == ConfigId.REVENUE_SHARE) {
            cfg.revenueShareBps = uint16(data);
        } else if (id == ConfigId.CLAIM_TIP) {
            cfg.claimTipBps = uint16(data);
        } else if (id == ConfigId.BRIBE_PREMIUM) {
            cfg.bribePremiumBps = uint16(data);
        } else if (id == ConfigId.QUORUM) {
            cfg.quorumBps = uint16(data);
        } else if (id == ConfigId.UNLOCK_FEE) {
            cfg.unlockFeeBps = uint16(data);
        } else if (id == ConfigId.BUYBACK_PERIOD) {
            cfg.buybackPeriod = uint32(data);
        } else if (id == ConfigId.LIQUIDATION_PERIOD) {
            cfg.liquidationPeriod = uint32(data);
        } else if (id == ConfigId.REDEEM_PERIOD) {
            cfg.redeemPeriod = uint32(data);
        } else if (id == ConfigId.UNLOCK_PENALTY_PERIOD) {
            cfg.unlockPenaltyPeriod = uint32(data);
        }
        // forge-lint: disable-end(unsafe-typecast)
        // ConfigId.DISTRIBUTE_CUTS: intentionally ignored (cuts via initialize / FULL).

        _requireValidConfig(cfg);
        config = cfg;
    }

    /// @notice Grant or revoke permission to call `deposit`.
    function setDepositor(address depositor, bool isDepositor_) external onlyOwner {
        if (isDepositor[depositor] == isDepositor_) return;
        isDepositor[depositor] = isDepositor_;
        unchecked {
            if (isDepositor_) ++totalDepositors;
            else --totalDepositors;
        }
    }

    function setGrinders(address grinders_) external onlyOwner {
        _requireNotLiquidation();
        _requireGraiMatch(grinders_);
        grinders = IGrinders(grinders_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        _requireNotGRAI(treasury_);
        _requireGraiMatch(treasury_);
        treasury = ITreasury(treasury_);
    }

    /// @notice Set the asset used for bribe payments.
    /// @dev Requires a price feed. Must not be fee-on-transfer (see `bribeAsset` / `bribe`).
    ///      Auctions price in GRAI, so open lots / locks do not block the switch.
    function setBribeAsset(address bribeAsset_) external onlyOwner {
        _requireNotGRAI(bribeAsset_);
        _requireListed(bribeAsset_);
        bribeAsset = bribeAsset_;
    }

    receive() external payable {}

    //////////////////// GETTERS ////////////////////

    /// @inheritdoc IGRAI
    function beneficiar() public view returns (address) {
        try treasury.beneficiar() returns (address beneficiar_) {
            return beneficiar_;
        } catch {
            return address(treasury);
        }
    }

    /// @inheritdoc IGRAI
    function getAssets() external view returns (DutchAuction[] memory list) {
        list = new DutchAuction[](assetList.length);
        for (uint256 i; i < assetList.length;) {
            address asset = assetList[i];
            DutchAuction storage entry = auctions[asset];
            if (entry.startTime != 0) {
                list[i] = entry;
            } else {
                list[i].asset = asset;
            }
            unchecked { ++i; }
        }
    }

    /// @inheritdoc IGRAI
    /// @dev `voters_ == false` → `lockers`; `true` → `voters`.
    function getEscrows(
        bool voters_, 
        uint256 fromId,
        uint256 toId
    ) external view returns (Escrow[] memory escrowList) {
        address[] storage accounts = voters_ ? voters : lockers;
        if (fromId >= toId) revert InvalidRange(fromId, toId);
        if (toId > accounts.length) toId = accounts.length;
        uint256 len = toId - fromId;
        escrowList = new Escrow[](len);
        for (uint256 i; i < len;) {
            escrowList[i] = escrows[accounts[fromId + i]];
            unchecked { ++i; }
        }
    }

    /// @inheritdoc IGRAI
    /// @dev Full basket snapshot in `assetList` order (includes zero balances). Excludes dividend
    ///      `totalClaimable` from each amount. Only while liquidation is open.
    function getRedeemables() external view returns (address[] memory assetOuts, uint256[] memory amounts) {
        _requireLiquidation();
        assetOuts = new address[](assetList.length);
        amounts = new uint256[](assetList.length);
        for (uint256 i; i < assetList.length;) {
            address asset = assetList[i];
            assetOuts[i] = asset;
            amounts[i] = _redeemable(asset);
            unchecked { ++i; }
        }
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
        _requireNotGRAI(asset);
        _requireListed(asset);
        _requireNotZeroAmount(yieldAmount);

        (uint256 received, uint256 refund) = _pay(msg.sender, address(this), asset, yieldAmount, false);
        positions[msg.sender][asset].yielded += received;

        uint256 treasuryCut = (received * config.treasuryCutBps) / BPS;
        uint256 dividendCut = (received * config.dividendCutBps) / BPS;
        uint256 buybackCut = received - treasuryCut - dividendCut;

        _place(asset, buybackCut);
        _distribute(asset, dividendCut);
        _withdraw(address(treasury), asset, treasuryCut);
        _sendEth(msg.sender, refund);

        emit Distribute(msg.sender, asset, received, buybackCut, dividendCut, treasuryCut);
    }

    //////////////////// DEPOSIT ////////////////////

    /// @inheritdoc IGRAI
    function deposit(
        address asset,
        uint256 amount,
        bool lock_,
        address referrer
    ) public payable returns (uint256 graiOut, uint256 value) {
        _requireNotLiquidation();
        _requireNotGRAI(asset);
        _requireListed(asset);
        _requireNotZeroAmount(amount);
        if (totalDepositors > 0 && !isDepositor[msg.sender]) revert NotDepositor();
        if (feeds[asset].paused) revert Paused();

        (uint256 received, uint256 refund) = _pay(msg.sender, address(grinders), asset, amount, false);
        (value, graiOut) = previewDeposit(asset, received);
        _requireNotZeroAmount(value);
        _requireNotZeroAmount(graiOut);

        totalValue += value;
        _mint(msg.sender, graiOut);
        try treasury.mint(msg.sender, referrer) {} catch {}
        if (lock_) lock(graiOut);
        _sendEth(msg.sender, refund);
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

    //////////////////// LOCK ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Escrows GRAI for dividend eligibility on the unvoted portion (`locked - voted`).
    ///      Not required before `vote` — `vote` locks any shortfall itself. Exit locked (unvoted) GRAI via `unlock`.
    function lock(uint256 graiAmount) public {
        _requireNotLiquidation();
        _requireNotZeroAmount(graiAmount);
        address locker = msg.sender;
        Escrow storage entry = escrows[locker];

        if (graiAmount > balanceOf(locker)) revert InvalidAmount();
        _accrueDividends(locker);
        totalLocked += graiAmount;
        if (entry.locked == 0) _addAccount(locker, false);
        entry.locked += graiAmount;
        entry.lockedAt = uint48(block.timestamp);
        _syncDividendDebts(locker);

        _transfer(locker, address(this), graiAmount);
        emit Lock(locker, graiAmount, totalLocked);
    }

    //////////////////// UNLOCK ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Accrues lock dividends, takes decaying unlock penalty (→ `treasury`), clamps excess votes, and
    ///      returns `graiAmount - penalty` to wallet. Dust partial / fee floor rules live in `previewUnlock`.
    ///      Yield claims are separate (`claim` / `claimAll`).
    function unlock(uint256 graiAmount) public {
        _requireNotLiquidation();
        address account = msg.sender;
        Escrow storage entry = escrows[account];
        _requireNotZeroAmount(graiAmount);
        if (graiAmount > entry.locked) revert InvalidAmount();

        _accrueDividends(account);

        (uint256 unlockAmount, ) = previewUnlock(account, graiAmount, block.timestamp);

        totalLocked -= graiAmount;
        entry.locked -= graiAmount;
        _clampVote(account);
        _syncDividendDebts(account);

        if (unlockAmount > 0) _transfer(address(this), account, unlockAmount);
        if (entry.locked == 0) _removeAccount(account, false);
        emit Unlock(account, graiAmount, totalLocked);
    }

    /// @inheritdoc IGRAI
    /// @dev Linear decay of `unlockFeeBps` → 0 over `unlockPenaltyPeriod` since `lockedAt` at `timestamp`.
    ///      Returns `unlockAmount = graiAmount - penalty` (GRAI returned to wallet) and `penalty` (→ `treasury`).
    ///      While live `penaltyBps > 0`, partial unlocks below `ceil(BPS / penaltyBps)` revert (`InvalidAmount`);
    ///      full-escrow exit is always allowed.
    function previewUnlock(address account, uint256 graiAmount, uint256 timestamp)
        public
        view
        returns (uint256 unlockAmount, uint256 penalty)
    {
        if (config.unlockFeeBps == 0 || config.unlockPenaltyPeriod == 0 || graiAmount == 0) {
            unlockAmount = graiAmount;
            penalty = 0;
        } else {
            uint256 lockedAt = escrows[account].lockedAt;
            uint256 elapsed = timestamp > lockedAt ? timestamp - lockedAt : 0;
            if (elapsed >= config.unlockPenaltyPeriod) {
                unlockAmount = graiAmount;
                penalty = 0;
            } else {
                uint256 penaltyBps =
                    (uint256(config.unlockFeeBps) * (config.unlockPenaltyPeriod - elapsed)) / config.unlockPenaltyPeriod;
                if (penaltyBps > 0) {
                    uint256 minUnlock = (uint256(BPS) + penaltyBps - 1) / penaltyBps;
                    // Partial dust unlocks floor fee to 0; full exit of a sub-min bag is allowed.
                    if (graiAmount < minUnlock && graiAmount < escrows[account].locked) revert InvalidAmount();
                }
                penalty = (graiAmount * penaltyBps) / BPS;
                unlockAmount = graiAmount - penalty;
            }
        }
    }

    //////////////////// CLAIM ////////////////////

    /// @inheritdoc IGRAI
    /// @dev `type(uint256).max` claims the full accrued balance; otherwise claims `min(amount, claimable)`.
    ///      Pays tip to `msg.sender`, remainder to `locker` (locker claim is not cut for affiliates).
    ///
    ///      Claim-time treasury income (allocation key = `claimed` share of the dividend slice):
    ///      `netProfitShare = claimed * treasuryCutBps / dividendCutBps` (full treasury / net-profit slice),
    ///      `revenueShare   = claimed * revenueShareBps / dividendCutBps` (≤ that slice → affiliates).
    ///      `treasury.distribute` pays referrers from `revenueShareInfo`, remainder of `netProfitShare`
    ///      → `Treasury.beneficiar`. Wrapped in
    ///      try/catch so a missing/reverting treasury does not block locker/tip payouts.
    function claim(address locker, address asset, uint256 amount) public returns (uint256 claimed) {
        _requireNotGRAI(asset);
        _accrueDividend(locker, asset);
        uint256 claimable = positions[locker][asset].claimable;
        if (claimable == 0) return 0;
        claimed = amount == type(uint256).max || amount >= claimable ? claimable : amount;
        positions[locker][asset].claimable -= claimed;
        uint256 tip = (claimed * config.claimTipBps) / BPS;
        uint256 toLocker = claimed - tip;

        uint256 netProfitShare = (claimed * config.treasuryCutBps) / config.dividendCutBps;
        uint256 revenueShare = (claimed * config.revenueShareBps) / config.dividendCutBps;
        try treasury.distribute(asset, locker, netProfitShare, revenueShare) {} catch {}
        _withdraw(locker, asset, toLocker);
        _withdraw(msg.sender, asset, tip);
        assets[asset].totalClaimable -= claimed;
        emit Claim(locker, asset, claimed);
    }

    /// @inheritdoc IGRAI
    /// @dev Pending = stored `claimable` plus unrealized accrual vs `assets[asset].accShare` on unvoted lock
    ///      (`locked - voted`). `type(uint256).max` = full pending; otherwise `min(amount, pending)`.
    function previewClaim(address locker, address asset, uint256 amount) public view returns (uint256) {
        _requireNotGRAI(asset);
        Position storage pos = positions[locker][asset];
        uint256 accumulated = (_unvoted(locker) * assets[asset].accShare) / PRECISION;
        uint256 pending = pos.claimable + accumulated - pos.debt;
        if (amount == type(uint256).max || amount >= pending) return pending;
        return amount;
    }

    //////////////////// CLAIM ALL ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Pays every listed-asset dividend for `locker`.
    function claimAll(address locker) public {
        uint256 len = assetList.length;
        for (uint256 i; i < len;) {
            claim(locker, assetList[i], type(uint256).max);
            unchecked { ++i; }
        }
    }

    /// @inheritdoc IGRAI
    /// @dev One entry per listed asset in `assetList` order (amount may be 0).
    function previewClaimAll(address locker) public view returns (address[] memory claimAssets, uint256[] memory amounts) {
        claimAssets = new address[](assetList.length);
        amounts = new uint256[](assetList.length);
        for (uint256 i; i < assetList.length;) {
            address asset = assetList[i];
            claimAssets[i] = asset;
            amounts[i] = previewClaim(locker, asset, type(uint256).max);
            unchecked { ++i; }
        }
    }

    //////////////////// BUYBACK ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Buyer pays GRAI (Dutch ask) and receives the listed asset; `graiIn` is escrowed and voted
    ///      toward liquidation on the buyer (refund via `bribe` or `unlock` with unlock penalty).
    ///      Requires `graiIn > 0` and `amountOut > 0` (no free / zero fills — blocks chunked floor-drain).
    ///      Full-lot ask decays to `(BPS - bribePremiumBps)` of mint (not free clearance unless
    ///      premium is `BPS`). Orphan GRAI (`balanceOf(this) - totalLocked`) is credited to the buyer
    ///      then `lock`+`vote`d with the Dutch payment.
    function buyback(address asset, uint256 amount) public {
        _requireNotLiquidation();
        address buyer = msg.sender;

        // Dead GRAI (direct transfers, not via `lock`) → buyer wallet, then lock+vote with graiIn.
        uint256 dead = 0;
        uint256 bal = balanceOf(address(this));
        if (bal > totalLocked) {
            dead = bal - totalLocked;
            _transfer(address(this), buyer, dead);
        }

        (uint256 graiIn, uint256 amountOut) = previewBuyback(asset, amount, block.timestamp);
        _requireNotZeroAmount(graiIn);
        _requireNotZeroAmount(amountOut);

        DutchAuction storage entry = auctions[asset];
        if (entry.remaining > amountOut) {
            entry.remaining -= amountOut;
        } else {
            delete auctions[asset];
        }

        // `lock` pulls GRAI from the buyer; `vote` commits it (unvoted share stays 0 → no dividends).
        lock(graiIn + dead);
        vote(graiIn + dead);
        _withdraw(buyer, asset, amountOut);
        emit Buyback(buyer, asset, graiIn, amountOut);
    }

    /// @inheritdoc IGRAI
    /// @dev Dutch GRAI ask: `maxPayment` → `minPayment` over `entry.period` (snapshotted from
    ///      `config.buybackPeriod` at `_place`), scaled by buy size. Caps to auction remaining.
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
        uint256 ask = _dutchAmount(entry.maxPayment, entry.minPayment, elapsed, entry.period);
        graiIn = entry.initial > 0 ? (ask * amountOut) / entry.initial : 0;
    }

    //////////////////// VOTE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev No prior `lock` needed: locks any shortfall from the wallet, then commits toward quorum.
    ///      Voted GRAI leaves the dividend base (`locked - voted`) and is buyable via `bribe`;
    ///      exit also via `unlock` (clamps vote, unlock penalty).
    function vote(uint256 graiAmount) public {
        _requireNotLiquidation();
        _requireNotZeroAmount(graiAmount);
        address voter = msg.sender;
        Escrow storage entry = escrows[voter];

        uint256 needLocked = entry.voted + graiAmount;
        if (entry.locked < needLocked) lock(needLocked - entry.locked);

        _accrueDividends(voter);
        if (entry.voted == 0) _addAccount(voter, true);
        totalVoted += graiAmount;
        entry.voted += graiAmount;
        entry.votedAt = uint48(block.timestamp);
        _syncDividendDebts(voter);

        emit Vote(voter, graiAmount, totalVoted);
    }

    //////////////////// BRIBE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Briber buys out voted GRAI for dynamic `previewBribe` in `bribeAsset` (non-FoT only).
    ///      Premium leg: ask = book × (BPS + adj) / BPS. Discount leg: fullAsk = book × (BPS − adj) /
    ///      BPS (0 if `adj ≥ BPS`), then ask = book − (book − fullAsk) / 2. `adj` is linear in
    ///      distance from half-quorum with slope `bribePremiumBps` per half-quorum of vote-share —
    ///      equals `bribePremiumBps` at 0 votes and at quorum, and may exceed it above quorum.
    ///      Requires exact `_pay` credit (`received == bribeAmount`); FoT `bribeAsset` reverts.
    ///      Premium: voter gets book + half premium, remaining premium → cuts. Discount: half of
    ///      full gap stays in the ask (briber saving), other half → cuts; voter keeps the rest of
    ///      `received`. Par: all to voter.
    function bribe(address voter, uint256 graiAmount) public payable {
        _requireNotLiquidation();
        address briber = msg.sender;
        // Snapshot ask before escrow reserve changes `totalVoted` (drives dynamic premium).
        (uint256 bribeAmount, uint256 premium, uint256 discount) = previewBribe(voter, graiAmount);

        Escrow storage entry = escrows[voter];
        _accrueDividends(voter);

        // Reserve escrow before `_pay` so a reentrant bribe cannot double-spend the same voter.
        // Keep `totalLocked`/`totalVoted` unchanged until `graiOut` leaves: otherwise mid-`_pay` /
        // payout hooks can `buyback` and book in-flight GRAI to the buyer as "dead".
        entry.voted -= graiAmount;
        entry.locked -= graiAmount;
        totalVoted -= graiAmount;
        totalLocked -= graiAmount;
        _syncDividendDebts(voter);
        _transfer(address(this), briber, graiAmount);
        (uint256 received, uint256 refund) = _pay(briber, address(this), bribeAsset, bribeAmount, false);

        if (received != bribeAmount) revert InvalidAmount();
        if (entry.voted == 0) _removeAccount(voter, true);
        if (entry.locked == 0) _removeAccount(voter, false);

        uint256 cutPool;
        if (premium > 0) {
            uint256 bribeBody = bribeAmount - premium;
            // Half premium stays with voter; the other half → cutPool.
            cutPool = (received - (received * bribeBody) / bribeAmount) / 2;
        } else {
            cutPool = (received * discount) / bribeAmount;
        }
        uint256 voterCut = received - cutPool;
        uint256 treasuryCut = (cutPool * config.treasuryCutBps) / BPS;
        uint256 dividendCut = (cutPool * config.dividendCutBps) / BPS;
        uint256 buybackCut = cutPool - treasuryCut - dividendCut;
        _place(bribeAsset, buybackCut);
        _distribute(bribeAsset, dividendCut);
        _withdraw(address(treasury), bribeAsset, treasuryCut);
        _withdraw(voter, bribeAsset, voterCut);
        _sendEth(briber, refund);
        emit Bribe(briber, voter, bribeAsset, graiAmount, received, totalVoted);
    }

    /// @inheritdoc IGRAI
    /// @dev Returns ask plus absolute premium/discount in `bribeAsset` (mutually exclusive; both 0 at
    ///      par). `premium > 0` ⇒ scarce votes (vote incentive); `discount > 0` ⇒ excess votes (bribe
    ///      incentive). `adj = bribePremiumBps * |voteBps − halfBps| / halfBps` (span floors to 1 if
    ///      half is 0): `bribePremiumBps` is the slope scale — `|adj| = bribePremiumBps` at 0 votes and
    ///      at quorum; above quorum discount `adj` keeps growing (may hit `BPS` → `fullAsk = 0`).
    ///      Discount regime: ask applies only half the book−fullAsk gap (`discount = gap / 2`,
    ///      `bribeAmount = book - discount`); the other half is carved to cuts in `bribe`.
    function previewBribe(address voter, uint256 graiAmount) public view returns (uint256 bribeAmount, uint256 premium, uint256 discount) {
        _requireListed(bribeAsset);
        _requireNotZeroAmount(graiAmount);
        Escrow storage entry = escrows[voter];
        if (graiAmount > entry.voted) revert InvalidAmount();

        uint256 supply = totalSupply();
        uint256 value = supply > 0 ? (graiAmount * totalValue) / supply : 0;
        uint256 book = _bribeAssetAmount(value);

        uint256 halfBps = uint256(config.quorumBps) / 2;
        uint256 voteBps = supply > 0 ? (totalVoted * BPS) / supply : 0;
        uint256 span = halfBps > 0 ? halfBps : 1;
        uint256 maxAdj = config.bribePremiumBps;

        if (voteBps < halfBps) {
            uint256 adj = (maxAdj * (halfBps - voteBps)) / span;
            bribeAmount = (book * (BPS + adj)) / BPS;
            premium = bribeAmount - book;
        } else {
            uint256 adj = (maxAdj * (voteBps - halfBps)) / span;
            uint256 fullAsk = adj >= BPS ? 0 : (book * (BPS - adj)) / BPS;
            discount = (book - fullAsk) / 2;
            bribeAmount = book - discount;
        }
        _requireNotZeroAmount(bribeAmount);
    }

    //////////////////// LIQUIDATE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev 2-of-2 with vote quorum. Owner: toggle `confirmed` when no quorum; with
    ///      quorum, this call is consent and opens. Non-owner: open when `confirmed &&
    ///      hasQuorum()`, else revert.
    function liquidate() public {
        _requireNotLiquidation();
        if (msg.sender == owner()) {
            if (!hasQuorum()) {
                confirmed = !confirmed;
                return;
            }
        } else {
            if (!confirmed) revert LiquidationNotConfirmed();
            if (!hasQuorum()) revert LiquidationQuorumNotMet();
        }
        uint256 len = assetList.length;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            if (auctions[asset].startTime != 0) {
                delete auctions[asset];
                emit AuctionUpdate(asset, 0, 0, 0);
            }
            unchecked { ++i; }
        }
        liquidation = true;
        liquidationAt = uint48(block.timestamp);
        emit Liquidate(liquidation);
    }

    //////////////////// REDEEM ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Pays the frozen `previewRedeem` vector after burns/`totalValue` cut. `nonReentrant` is
    ///      required: without it, an ETH/ERC777 callback mid-loop can nest `redeem` and skim later
    ///      assets above that snapshot (and over-claim the callback asset itself).
    function redeem(uint256 graiAmount) public nonReentrant {
        address holder = msg.sender;
        _requireLiquidation();

        (address[] memory assetOuts, uint256[] memory amounts) = previewRedeem(holder, graiAmount);
        uint256 supply = totalSupply();
        uint256 value = supply > 0 ? (totalValue * graiAmount) / supply : 0;
        _requireNotZeroAmount(value);

        uint256 walletAmount = balanceOf(holder);
        _accrueDividends(holder);
        uint256 walletBurn = graiAmount < walletAmount ? graiAmount : walletAmount;
        if (walletBurn > 0) _burn(holder, walletBurn);

        uint256 escrowBurn = graiAmount - walletBurn;
        if (escrowBurn > 0) {
            Escrow storage entry = escrows[holder];
            if (escrowBurn > entry.locked) revert InvalidAmount();
            totalLocked -= escrowBurn;
            entry.locked -= escrowBurn;
            _clampVote(holder);
            _syncDividendDebts(holder);
            _burn(address(this), escrowBurn);
            if (entry.locked == 0) _removeAccount(holder, false);
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
        _requireLiquidation();
        /// @dev Consolidation window: when liquidation opens, backing is still on Grinders and
        ///      custodians, while `redeem` pays only from tokens already held here. Blocking
        ///      claims until `liquidationPeriod` elapses gives keepers time to run permissionless
        ///      `Grinders.liquidate` sweeps; without it, early redeemers could burn shares and cut
        ///      `totalValue` while `previewRedeem` returns zero assets, forfeiting backing to
        ///      later claimants.
        if (block.timestamp < liquidationAt + config.liquidationPeriod) revert LiquidationDelay();
        uint256 supply = totalSupply();
        Escrow storage entry = escrows[holder];
        uint256 holderAmount = balanceOf(holder) + entry.locked;
        if (graiAmount == 0 || graiAmount > holderAmount) revert InvalidAmount();

        uint256 len = assetList.length;
        assetOuts = new address[](len);
        amounts = new uint256[](len);
        uint256 count;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            uint256 assetBalance = _redeemable(asset);
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
    ///      balances to Grinders and clear the claim clock so the fund can accept deposits again
    ///      (`_requireNotLiquidation` lifts). Per-asset `paused` flags are left as the owner set them.
    ///      With leftover shares, marks `totalValue = totalNAV` only when that raises mint price
    ///      (`totalNAV >= totalValue`); otherwise keeps book `totalValue` and still clears
    ///      liquidation (underwater reopen is allowed). Dividend inventory in
    ///      `assets[asset].totalClaimable` is left on GRAI for post-resettle `claim`. If no
    ///      shares remain, book is cleared to zero even if dust NAV is swept to Grinders.
    function resettle() public {
        _requireLiquidation();
        if (liquidationAt == 0) revert LiquidationClosed();
        if (block.timestamp < uint256(liquidationAt) + config.liquidationPeriod + config.redeemPeriod) {
            revert RedeemPeriodActive();
        }
        uint256 nav = 0;
        uint256 len = assetList.length;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            uint256 redeemable = _redeemable(asset);
            if (redeemable > 0) {
                nav += usdValue(asset, redeemable);
                _withdraw(address(grinders), asset, redeemable);
            }
            unchecked { ++i; }
        }
        uint256 supply = totalSupply();
        if (supply > 0) {
            // Raise mint price only; underwater reopen keeps book totalValue.
            if (nav >= totalValue) totalValue = nav;
        } else {
            totalValue = 0;
        }
        liquidation = false;
        liquidationAt = 0;
        confirmed = false;
        emit Liquidate(liquidation);
    }

    ////////////////////////////// INTERNAL HELPERS //////////////////////////////

    function _requireListed(address asset) internal view {
        if (feeds[asset].feedType == FeedType.NONE) revert AssetUnknown();
    }

    function _requireLiquidation() internal view {
        if (!liquidation) revert LiquidationClosed();
    }

    function _requireNotLiquidation() internal view {
        if (liquidation) revert LiquidationOpen();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _requireNotGRAI(address asset) internal view {
        if (asset == address(this)) revert AssetUnknown();
    }

    /// @dev `target.grai()` must be this contract (`IGrinders` / `ITreasury` share the selector).
    function _requireGraiMatch(address target) internal view {
        if (target == address(0)) revert ZeroAddress();
        if (address(ITreasury(target).grai()) != address(this)) revert GraiMismatch();
    }

    function _requireNotZeroAmount(uint256 amount) internal pure {
        if (amount == 0) revert InvalidAmount();
    }

    function _requireValidConfig(Config memory cfg) internal pure {
        if (cfg.buybackCutBps > BPS) revert BpsTooHigh();
        if (cfg.dividendCutBps > BPS) revert BpsTooHigh();
        if (cfg.treasuryCutBps > BPS) revert BpsTooHigh();
        if (cfg.revenueShareBps > cfg.treasuryCutBps) revert BpsTooHigh();
        if (cfg.claimTipBps > 20_00) revert BpsTooHigh(); // max 20%
        if (2 * cfg.bribePremiumBps > BPS) revert BpsTooHigh();
        if (cfg.quorumBps > BPS) revert BpsTooHigh();
        if (cfg.unlockFeeBps > BPS) revert BpsTooHigh();
        if (cfg.dividendCutBps == 0) revert InvalidCuts();
        if (uint256(cfg.buybackCutBps) + cfg.dividendCutBps + cfg.treasuryCutBps != BPS) revert InvalidCuts();
        if (cfg.buybackPeriod < 7 days) revert BuybackPeriodTooShort();
        if (cfg.liquidationPeriod == 0 || cfg.redeemPeriod == 0) revert PeriodZero();
    }

    /// @dev Packing matches Solidity's single-slot `Config` layout (low bits first).
    function _unpackConfig(uint256 data) internal pure returns (Config memory cfg) {
        // Each field is a fixed bit window of `data`; high bits outside that window are discarded.
        // forge-lint: disable-start(unsafe-typecast)
        cfg.buybackCutBps = uint16(data);
        cfg.dividendCutBps = uint16(data >> 16);
        cfg.treasuryCutBps = uint16(data >> 32);
        cfg.revenueShareBps = uint16(data >> 48);
        cfg.claimTipBps = uint16(data >> 64);
        cfg.bribePremiumBps = uint16(data >> 80);
        cfg.quorumBps = uint16(data >> 96);
        cfg.unlockFeeBps = uint16(data >> 112);
        cfg.buybackPeriod = uint32(data >> 128);
        cfg.liquidationPeriod = uint32(data >> 160);
        cfg.redeemPeriod = uint32(data >> 192);
        cfg.unlockPenaltyPeriod = uint32(data >> 224);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice Contract balance of `asset` (`address(0)` = native ETH).
    function _balance(address asset) internal view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @dev Lock dividends accrue only on unvoted escrow: `locked - voted`. Fully voted locks earn none.
    function _unvoted(address account) internal view returns (uint256) {
        Escrow storage entry = escrows[account];
        return entry.locked - entry.voted;
    }

    /// @notice Balance available to liquidation redeem / resettle (excludes dividend claim reserve).
    function _redeemable(address asset) internal view returns (uint256) {
        uint256 bal = _balance(asset);
        uint256 reserved = assets[asset].totalClaimable;
        return bal > reserved ? bal - reserved : 0;
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
    ///      Decays to `(BPS - bribePremiumBps)` of that mint ask over `buybackPeriod`. Clock restart on
    ///      every merge (including dust) is intentional: the protocol prefers frequent re-lists at the
    ///      live mint ask over preserving Dutch elapsed across top-ups.
    function _place(address asset, uint256 amount) internal {
        if (amount == 0) return;
        _requireNotGRAI(asset);
        _requireListed(asset);

        DutchAuction storage entry = auctions[asset];
        entry.remaining += amount;
        (uint256 value, uint256 graiAmount) = previewDeposit(asset, entry.remaining);
        if (value == 0 || graiAmount == 0) return; // dust: don't list, don't revert distribute

        entry.asset = asset;
        entry.initial = entry.remaining;
        entry.maxPayment = graiAmount;
        entry.minPayment = (graiAmount * (BPS - config.bribePremiumBps)) / BPS;
        entry.startTime = uint48(block.timestamp);
        entry.period = config.buybackPeriod;
        emit AuctionUpdate(asset, entry.remaining, graiAmount, block.timestamp);
    }

    //////////////////// DIVIDENTS ////////////////////

    function _distribute(address asset, uint256 amount) internal {
        if (amount == 0) return;
        uint256 eligible = totalLocked - totalVoted;
        uint256 indexIncrease = eligible > 0 ? (amount * PRECISION) / eligible : 0;
        if (indexIncrease == 0) {
            _place(asset, amount);
        } else {
            AssetConfig storage div = assets[asset];
            div.accShare += indexIncrease;
            div.totalClaimable += amount;
        }
    }

    function _accrueDividends(address account) internal {
        uint256 len = assetList.length;
        for (uint256 i; i < len;) {
            _accrueDividend(account, assetList[i]);
            unchecked { ++i; }
        }
    }

    function _accrueDividend(address account, address asset) internal {
        Position storage pos = positions[account][asset];
        uint256 accumulated = (_unvoted(account) * assets[asset].accShare) / PRECISION;
        pos.claimable += accumulated - pos.debt;
        pos.debt = accumulated;
    }

    function _syncDividendDebts(address account) internal {
        uint256 len = assetList.length;
        uint256 unvoted = _unvoted(account);
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            positions[account][asset].debt = (unvoted * assets[asset].accShare) / PRECISION;
            unchecked { ++i; }
        }
    }

    function _addAsset(address asset) internal {
        if (asset == address(this)) return;
        uint256 existingId = assets[asset].id;
        if (existingId < assetList.length && assetList[existingId] == asset) return;

        uint32 id = uint32(assetList.length);
        assets[asset] = AssetConfig({asset: asset, id: id, accShare: 0, totalClaimable: 0});
        assetList.push(asset);
        emit AssetUpdate(asset, true);
    }

    function _removeAsset(address asset) internal {
        uint256 index = assets[asset].id;
        if (index >= assetList.length || assetList[index] != asset) revert AssetUnknown();
        if (!feeds[asset].paused) revert NotPaused();
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

    function _addAccount(address account, bool asVoter) internal {
        Escrow storage e = escrows[account];
        if (asVoter) {
            // forge-lint: disable-next-line(unsafe-typecast)
            e.voterId = uint32(voters.length);
            voters.push(account);
        } else {
            e.account = account;
            // forge-lint: disable-next-line(unsafe-typecast)
            e.lockerId = uint32(lockers.length);
            lockers.push(account);
        }
    }

    function _removeAccount(address account, bool asVoter) internal {
        if (!asVoter) _clampVote(account);
        Escrow storage e = escrows[account];
        address[] storage list = asVoter ? voters : lockers;
        uint256 index = asVoter ? e.voterId : e.lockerId;
        if (index >= list.length || list[index] != account) return;
        uint256 lastIndex = list.length - 1;
        if (index != lastIndex) {
            address moved = list[lastIndex];
            list[index] = moved;
            // list length / index always fit uint32 in practice
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 id = uint32(index);
            if (asVoter) escrows[moved].voterId = id;
            else escrows[moved].lockerId = id;
        }
        list.pop();
        // Keep escrow storage; only clear list membership.
        if (asVoter) e.voterId = 0;
        else e.lockerId = 0;
    }

    /// @dev Ensure `escrows[account].voted` never exceeds `locked` after reductions.
    function _clampVote(address account) internal {
        Escrow storage entry = escrows[account];
        uint256 voted = entry.voted;
        if (voted == 0) return;
        uint256 locked = entry.locked;
        if (voted <= locked) return;
        totalVoted -= voted - locked;
        entry.voted = locked;
        if (locked == 0) _removeAccount(account, true);
    }

    /// @dev Pulls `amount` from `from` to `to` and returns tokens actually credited (FoT-safe for ERC20)
    ///      plus any ETH excess (`refund`). ETH is funded by `msg.value`; when `toRefund` is true the
    ///      excess is sent to `msg.sender`, otherwise the caller must send `refund` later.
    ///      A rejected ETH payment or refund is redirected to `treasury`.
    ///      Stray `msg.value` on an ERC20 path is forwarded to `treasury` (not parked on GRAI).
    function _pay(address from, address to, address asset, uint256 amount, bool toRefund) internal returns (uint256 paid, uint256 refund) {
        if (asset == address(0)) {
            if (msg.value < amount) revert ValueMismatch();
            refund = msg.value - amount;
            if (to != address(this)) _sendEth(to, amount);
            if (toRefund) _sendEth(msg.sender, refund);
            paid = amount;
        } else {
            _sendEth(beneficiar(), msg.value);
            uint256 before = IERC20(asset).balanceOf(to);
            IERC20(asset).safeTransferFrom(from, to, amount);
            paid = IERC20(asset).balanceOf(to) - before;
        }
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) {
            try weth.deposit{value: amount}() {
                weth.safeTransfer(to, amount);
            } catch {
                (bool treasuryOk,) = payable(beneficiar()).call{value: amount}("");
                if (!treasuryOk) revert EthTransferFailed();
            }
        }
    }

    /// @dev Native ETH is pushed first. If the recipient rejects it (no payable fallback), wrap via
    ///      `weth` and ERC20-transfer so bribes / liquidations / treasury cuts still settle.
    function _withdraw(address to, address asset, uint256 amount) internal {
        if (amount == 0) return;
        if (asset == address(0)) {
            if (to == address(0)) revert ZeroAddress();
            _sendEth(to, amount);
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
