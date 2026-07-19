// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGRAI, IERC20, IERC20Metadata, IPriceOracleRouter} from "./interfaces/IGRAI.sol";
import {IGrinders} from "./interfaces/IGrinders.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";
import {PriceOracleRouter} from "./PriceOracleRouter.sol";

/// @title GRAI (implementation)
/// @notice Condition-redeemable fund-share ERC20: deposits issue GRAI at book value into Grinders; distributed yield is
///         Dutch-auctioned into `settlementAsset`.
/// @dev Interact only via the ERC1967Proxy.
contract GRAI is IGRAI, PriceOracleRouter, ERC20Upgradeable, AccessControlEnumerableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 100_00; // 100%

    // bytes32 public constant DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GRINDERS_ROLE = keccak256("GRINDERS_ROLE");

    /// @notice High-risk pool that generates yield.
    IGrinders public grinders;

    /// @notice Fee recipient for protocol profit from `distribute`.
    address public treasury;

    address[] public assetList;

    mapping(address asset => AssetConfig) public assets;

    /// @notice One open Dutch auction of distributed yield per sold asset.
    mapping(address asset => DutchAuction) public auctions;

    mapping(address custodian => mapping(address asset => uint256)) public yieldBy;

    /// @notice GRAI voted toward liquidation quorum (held by this contract).
    mapping(address account => VoteEscrow) public votes;

    /// @notice Accounts with an open vote; `votes[account].id` is the index here.
    address[] public voters;

    uint256 public totalVoted;

    uint256 public totalValue;

    /** SLOT BEGIN */

    /// @notice Asset used for dutch auction settlement and bribes.
    /// @dev If zero address, asset is the native token (ETH); otherwise, it's an ERC20.
    address public settlementAsset;

    /// @notice True after `liquidate` opens until it closes.
    bool public liquidation;

    /// @notice Timestamp when the current liquidation opened; zero while liquidation is closed.
    uint48 public liquidationAt;

    /** SLOT end 20 + 1 + 6 */

    /// @notice Bribe premium, liquidation quorum, and timing.
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
        grinders = IGrinders(address(this));
        treasury = admin_;
        config = ProtocolConfig({
            bribePremiumBps: 2_00, // 2%
            liquidationQuorumBps: 66_67, // 66.67%
            auctionDuration: uint32(365 days),
            liquidationPeriod: uint32(24 hours),
            redeemPeriod: uint32(7 days)
        });
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    function setProtocolConfig(ProtocolConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cfg.bribePremiumBps > BPS || cfg.liquidationQuorumBps > BPS) {
            revert BpsTooHigh();
        }
        if (cfg.auctionDuration <= 7 days) revert AuctionDurationTooShort();
        config = cfg;
        emit ConfigUpdate(cfg);
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

    function setSettlementAsset(address settlementAsset_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeds[settlementAsset_].feedType == FEED_NONE) revert AssetUnknown();
        if (getAuctions().length != 0) revert AuctionsOpen();
        settlementAsset = settlementAsset_;
        emit SettlementAssetUpdate(settlementAsset_);
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
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }
        assembly ("memory-safe") {
            mstore(list, count)
        }
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
    function hasQuorum() public view returns (bool) {
        uint256 supply = totalSupply();
        return supply > 0 && totalVoted * BPS >= supply * config.liquidationQuorumBps;
    }

    /// @notice Convert a USD amount (`USD_DECIMALS`) into `settlementAsset` base units via oracle.
    function settlementAmount(uint256 usdAmount) public view returns (uint256) {
        (uint256 price, uint8 pdec) = getPrice(settlementAsset);
        uint8 adec = settlementAsset == address(0) ? 18 : IERC20Metadata(settlementAsset).decimals();
        return (usdAmount * (10 ** adec) * (10 ** pdec)) / (price * (10 ** USD_DECIMALS));
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
        uint256 existingId = assets[asset].id;
        if (existingId < assetList.length && assetList[existingId] == asset) return;

        uint32 id = uint32(assetList.length);
        // Preserve a previously configured yield split; defaults to 0 for a new asset.
        assets[asset] = AssetConfig({
            asset: asset,
            id: id,
            paused: false,
            treasuryShare: assets[asset].treasuryShare
        });
        assetList.push(asset);
        emit AssetUpdate(asset, true);
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
        emit AssetUpdate(asset, false);
    }

    /// @dev `cfg.asset` and `cfg.id` are ignored: the `asset` param is authoritative and the `assetList` index is managed internally.
    function setAssetConfig(address asset, AssetConfig calldata cfg) external onlyRole(ADMIN_ROLE) {
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (cfg.treasuryShare > BPS) revert BpsTooHigh();
        assets[asset].treasuryShare = cfg.treasuryShare;
        assets[asset].paused = cfg.paused;
        emit AssetConfigUpdate(asset, assets[asset]);
    }

    //////////////////// DISTRIBUTE ////////////////////

    /// @notice Pull yield, send `treasuryShare` to treasury, and auction (or retain) `yieldShare`.
    /// @dev If `asset == settlementAsset`, yield accrues directly on GRAI. Otherwise the
    ///      yield lot is merged into a 1-year Dutch auction restarting at current oracle fair value.
    function distribute(address asset, uint256 yieldAmount) public payable {
        if (liquidation) revert LiquidationOpen();
        AssetConfig storage cfg = assets[asset];
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (yieldAmount == 0) revert AmountZero();

        uint256 received = _pay(msg.sender, address(this), asset, yieldAmount);
        yieldBy[msg.sender][asset] += received;
        uint256 treasuryShare = (received * cfg.treasuryShare) / BPS;
        uint256 yieldShare = received - treasuryShare;

        if (treasuryShare > 0) _withdraw(treasury, asset, treasuryShare);
        if (yieldShare > 0 && asset != settlementAsset) _put(asset, yieldShare);

        emit Distribute(msg.sender, asset, received, yieldShare, treasuryShare);
    }

    //////////////////// DEPOSIT ////////////////////

    function deposit(address asset, uint256 amount) public payable returns (uint256 graiOut, uint256 value) {
        if (liquidation) revert LiquidationOpen();
        if (amount == 0) revert AmountZero();
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        if (assets[asset].paused) revert Paused();

        uint256 received = _pay(msg.sender, address(grinders), asset, amount);

        (value, graiOut) = previewDeposit(asset, received);
        if (value == 0) revert AmountZero();
        if (graiOut == 0) revert AmountZero();

        totalValue += value;
        _mint(msg.sender, graiOut);
        emit Deposit(msg.sender, graiOut, asset, received, value);
    }

    /// @inheritdoc IGRAI
    /// @dev Mints shares at total value. Yield held by GRAI is not included because it is an extra
    ///      reward for buying GRAI and voting for liquidation. The first deposit mints 1:1.
    function previewDeposit(address asset, uint256 amount) public view returns (uint256 value, uint256 graiOut) {
        value = usdValue(asset, amount);
        uint256 supply = totalSupply();
        if (supply == 0) {
            graiOut = value;
        } else {
            if (totalValue == 0) revert InvalidAmount();
            graiOut = (value * supply) / totalValue;
        }
    }

    //////////////////// AUCTION FILL ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Buyer pays `settlementAsset` into this contract and receives the yield asset.
    function fill(address asset, uint256 amount, uint256 paymentMax) public payable {
        if (liquidation) revert LiquidationOpen();
        address buyer = msg.sender;
        DutchAuction storage entry = auctions[asset];
        if (entry.startTime == 0) revert AuctionNotFound();

        (uint256 amountOut, uint256 payment) = previewFill(asset, amount, block.timestamp);
        if (amountOut == 0) revert AmountZero();
        if (payment > paymentMax) revert Slippage();

        uint256 remaining = entry.remaining;
        uint256 newRemaining = remaining - amountOut;
        if (newRemaining == 0) {
            delete auctions[asset];
        } else {
            entry.remaining = newRemaining;
        }
        if (payment > 0) _pay(buyer, address(this), settlementAsset, payment);
        _withdraw(buyer, asset, amountOut);
        emit AuctionFill(buyer, asset, amountOut, payment);
    }

    /// @inheritdoc IGRAI
    /// @dev Dutch payment in `settlementAsset`: `maxPayment` → `minPayment` over `config.auctionDuration`,
    ///      scaled by fill size. Caps fill to auction remaining.
    function previewFill(
        address asset,
        uint256 amount, 
        uint256 timestamp
    ) public view returns (uint256 amountOut, uint256 payment) {
        DutchAuction storage entry = auctions[asset];
        if (entry.startTime == 0) revert AuctionNotFound();

        if (amount == type(uint256).max) amount = entry.remaining;
        if (amount > entry.remaining) amount = entry.remaining;
        if (amount == 0) return (0, 0);

        amountOut = amount;
        uint256 elapsed = timestamp > entry.startTime ? timestamp - entry.startTime : 0;
        uint256 price = dutchPrice(entry.maxPayment, entry.minPayment, elapsed, config.auctionDuration);
        payment = entry.initial == 0 ? 0 : (price * amountOut) / entry.initial;
    }

    //////////////////// BUYBACK ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Approves the full ERC20 settlement balance (or forwards the full native balance), executes the
    ///      DEX calldata, clears approval, verifies GRAI output, and burns the received GRAI.
    function buyback(
        address target,
        bytes calldata data,
        uint256 graiMin
    ) public onlyRole(ADMIN_ROLE) returns (uint256 payment, uint256 graiOut) {
        if (liquidation) revert LiquidationOpen();
        if (target == address(0)) revert TargetZero();
        if (data.length == 0) revert DataEmpty();

        uint256 settlementBefore = balance(settlementAsset);
        if (settlementBefore == 0) revert AmountZero();
        uint256 graiBefore = balanceOf(address(this));

        bool ok;
        if (settlementAsset == address(0)) {
            (ok,) = target.call{value: settlementBefore}(data);
        } else {
            IERC20 settlement = IERC20(settlementAsset);
            settlement.forceApprove(target, settlementBefore);
            (ok,) = target.call(data);
            settlement.forceApprove(target, 0);
        }
        if (!ok) revert SwapFailed();

        uint256 settlementAfter = balance(settlementAsset);
        if (settlementAfter >= settlementBefore) revert SwapFailed();
        payment = settlementBefore - settlementAfter;
        graiOut = balanceOf(address(this)) - graiBefore;
        if (graiOut < graiMin || graiOut == 0) revert Slippage();

        _burn(address(this), graiOut);
        emit Buyback(target, payment, graiOut);
    }

    //////////////////// VOTE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev `vote(0)` withdraws all of the caller's escrowed GRAI (full unvote).
    function vote(uint256 graiAmount) public {
        address voter = msg.sender;
        VoteEscrow storage entry = votes[voter];

        if (graiAmount == 0) {
            uint256 voted = entry.amount;
            if (voted == 0) revert AmountZero();
            totalVoted -= voted;
            _removeVoter(voter);
            _transfer(address(this), voter, voted);
            emit Vote(voter, 0, totalVoted);
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
        entry.votedAt = uint48(block.timestamp);
        entry.id = id;
        totalVoted += graiAmount;
        emit Vote(voter, graiAmount, totalVoted);
    }

    //////////////////// BRIBE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Briber (`msg.sender`) buys out `voter`'s vote of `graiAmount`: pays book value + premium to the voter
    ///      in `settlementAsset`, then receives the escrowed GRAI.
    function bribe(address voter, uint256 graiAmount) public payable {
        address briber = msg.sender;
        (address asset, uint256 bribeAmount, uint256 premium) = previewBribe(voter, graiAmount);
        uint256 total = bribeAmount + premium;

        VoteEscrow storage entry = votes[voter];
        uint256 voted = entry.amount - graiAmount;
        entry.amount = voted;
        totalVoted -= graiAmount;
        if (voted == 0) _removeVoter(voter);

        // Voter receives book value; premium stays in this contract.
        if (asset == address(0)) {
            if (msg.value != total) revert ValueMismatch();
            if (bribeAmount > 0) _withdraw(voter, asset, bribeAmount);
            // premium stays in this contract (already held via msg.value).
        } else {
            if (bribeAmount > 0) _pay(briber, voter, asset, bribeAmount);
            if (premium > 0) _pay(briber, address(this), asset, premium);
        }

        // Escrowed GRAI is released to the briber.
        _transfer(address(this), briber, graiAmount);
        emit Bribe(briber, voter, graiAmount, total, totalVoted);
    }

    /// @inheritdoc IGRAI
    /// @dev Book value of `graiAmount` = `graiAmount * totalValue / totalSupply`, converted to `settlementAsset`.
    ///      Pricing intentionally excludes yield inventory held by GRAI. When its market value exceeds book value,
    ///      holders are incentivized to vote for liquidation, while a briber can buy out those votes at book value
    ///      plus the configured premium and assume the corresponding GRAI position.
    function previewBribe(address voter, uint256 graiAmount) public view returns (address asset, uint256 bribeAmount, uint256 premium) {
        if (graiAmount == 0) revert AmountZero();
        VoteEscrow storage entry = votes[voter];
        if (graiAmount > entry.amount) revert InvalidAmount();
        if (feeds[settlementAsset].feedType == FEED_NONE) revert SettlementAssetUnset();

        asset = settlementAsset;
        uint256 supply = totalSupply();
        uint256 bookUsd = supply == 0 ? 0 : (graiAmount * totalValue) / supply;
        bribeAmount = settlementAmount(bookUsd);
        premium = (bribeAmount * config.bribePremiumBps) / BPS;
    }

    //////////////////// LIQUIDATE ////////////////////

    /// @inheritdoc IGRAI
    /// @dev Flips the liquidation flag and pauses/unpauses every asset accordingly. Opening requires quorum.
    ///      Closing returns any unredeemed basket balances to Grinders; unredeemed shares retain their book value.
    function liquidate() public onlyRole(ADMIN_ROLE) {
        uint256 len = assetList.length;
        if (liquidation) {
            if (block.timestamp < liquidationAt + config.liquidationPeriod + config.redeemPeriod) {
                revert RedeemPeriodActive();
            }
            for (uint256 i; i < len;) {
                address asset = assetList[i];
                assets[asset].paused = false;
                uint256 remaining = balance(asset);
                if (remaining > 0) _withdraw(address(grinders), asset, remaining);
                emit AssetConfigUpdate(asset, assets[asset]);
                unchecked {
                    ++i;
                }
            }
            liquidation = false;
            liquidationAt = 0;
        } else {
            if (!hasQuorum()) revert LiquidationQuorumNotMet();
            for (uint256 i; i < len;) {
                address asset = assetList[i];
                // Auction inventory becomes part of the pro-rata liquidation basket.
                if (auctions[asset].startTime != 0) {
                    delete auctions[asset];
                    emit AuctionUpdate(asset, 0, 0, 0);
                }
                assets[asset].paused = true;
                emit AssetConfigUpdate(asset, assets[asset]);
                unchecked {
                    ++i;
                }
            }
            liquidation = true;
            liquidationAt = uint48(block.timestamp);
        }
        emit Liquidate(liquidation, totalVoted, totalSupply());
    }

    //////////////////// REDEMPTION ////////////////////

    /// @inheritdoc IGRAI
    function redeem(uint256 graiAmount) external {
        if (!liquidation) revert LiquidationClosed();
        if (block.timestamp < liquidationAt + config.liquidationPeriod) revert LiquidationDelay();
        if (graiAmount == 0 || graiAmount > balanceOf(msg.sender)) revert InvalidAmount();

        uint256 supply = totalSupply();
        (address[] memory assetOuts, uint256[] memory amounts) = previewRedeem(graiAmount);
        uint256 depositValue = graiAmount == supply ? totalValue : (totalValue * graiAmount) / supply;

        _burn(msg.sender, graiAmount);
        totalValue -= depositValue;

        uint256 len = assetOuts.length;
        for (uint256 i; i < len;) {
            _withdraw(msg.sender, assetOuts[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
        emit Redeem(msg.sender, graiAmount, depositValue);
    }

    /// @inheritdoc IGRAI
    function previewRedeem(uint256 graiAmount) public view returns (address[] memory assetOuts, uint256[] memory amounts) {
        if (!liquidation) revert LiquidationClosed();
        if (block.timestamp < liquidationAt + config.liquidationPeriod) revert LiquidationDelay();
        uint256 supply = totalSupply();
        if (graiAmount == 0 || graiAmount > supply) revert InvalidAmount();

        uint256 len = assetList.length;
        assetOuts = new address[](len);
        amounts = new uint256[](len);
        uint256 count;
        for (uint256 i; i < len;) {
            address asset = assetList[i];
            uint256 assetBalance = balance(asset);
            if (assetBalance > 0) {
                uint256 amount = graiAmount == supply ? assetBalance : (assetBalance * graiAmount) / supply;
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

    //////////////////// INTERNAL HELPERS ////////////////////

    /// @dev Merge `amount` into the asset auction and restart the Dutch clock at current oracle fair value.
    ///      This is intentional: it incentivizes frequent `distribute` calls, while the protocol benefits
    ///      from selling accumulated yield as close to market value as possible.
    function _put(address asset, uint256 amount) internal {
        if (feeds[settlementAsset].feedType == FEED_NONE) revert SettlementAssetUnset();

        DutchAuction storage entry = auctions[asset];
        uint256 remaining = entry.remaining + amount;
        uint256 maxPayment = settlementAmount(usdValue(asset, remaining));
        if (maxPayment == 0) revert AmountZero();

        entry.asset = asset;
        entry.remaining = remaining;
        entry.initial = remaining;
        entry.maxPayment = maxPayment;
        entry.minPayment = 0;
        entry.startTime = block.timestamp;
        emit AuctionUpdate(asset, remaining, maxPayment, block.timestamp);
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

    /// @dev Pulls `amount` from `from` to `to` and returns tokens actually credited (FoT-safe for ERC20).
    ///      ETH cannot be pulled from a third party: funded by `msg.value` and forwarded from this contract
    ///      when `to != address(this)`.
    function _pay(address from, address to, address asset, uint256 amount) internal returns (uint256 received) {
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
