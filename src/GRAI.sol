// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";
import {IGrinders} from "./interfaces/IGrinders.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";
import {IPriceOracleRouter} from "./interfaces/IPriceOracleRouter.sol";
import {PriceOracleRouter} from "./PriceOracleRouter.sol";

/// @title GRAI (implementation)
/// @notice Senior idle reserve plus Grinders Artificial Index ERC20: yield-accruing tranche (~$ NAV, 6 decimals).
/// @dev NAV is priced from the senior asset basket via on-chain oracles. Interact only via the ERC1967Proxy.
contract GRAI is IGRAI, PriceOracleRouter, ERC20Upgradeable, AccessControlEnumerableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint16 internal constant BPS = 100_00;
    /// @notice Harberger tax rate on listed GRAI, annualized (1% / year).
    uint16 public constant HARBERGER_BPS = 100;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant GRINDERS_ROLE = keccak256("GRINDERS_ROLE");

    /// @notice Fee recipient for protocol profit from `distribute`.
    address public treasury;

    mapping(address asset => AssetConfig) public assets;
    address[] public assetList;

    uint256 public nextAuctionId;
    uint256 public totalValue;
    mapping(address asset => uint256) public taken;
    mapping(uint256 auctionId => AuctionLot) public auctions;
    /// @notice Active auction ids (moderated on ask / full fill / seller reclaim).
    uint256[] public auctionIds;

    /// @dev Storage gap for future upgrades.
    uint256[32] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) public initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __ERC20_init("Grinders Artificial Index", "GRAI");
        __AccessControlEnumerable_init();
        treasury = admin_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(ORACLE_ROLE, admin_);
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

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function decimals() public pure override returns (uint8) {
        return USD_DECIMALS;
    }

    /// @inheritdoc IGRAI
    function totalNAV() public view returns (uint256 value) {
        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            uint256 bal = balance(asset);
            if (bal > 0) value += usdValue(asset, bal);
        }
    }

    /// @inheritdoc IGRAI
    /// @dev USD value per 1 GRAI (6 decimals). Parity ($1) when supply is zero.
    function mintPrice() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 10 ** decimals();
        return (totalValue * (10 ** decimals())) / supply;
    }

    /// @inheritdoc IGRAI
    /// @dev Max GRAI redeemable against idle NAV (protocol-wide, not per account).
    function maxRedeem() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;

        uint256 price = mintPrice();
        if (price == 0) return supply;

        // Exact invert of: nav >= (graiAmount * price) / 10^decimals
        uint256 byNav = ((totalNAV() + 1) * (10 ** decimals()) - 1) / price;
        return byNav < supply ? byNav : supply;
    }

    /// @inheritdoc IERC1046
    function tokenURI() public pure returns (string memory) {
        return "https://grindurus.xyz/metadata.json";
    }

    function setFeed(address asset, Feed calldata feed) public override(IPriceOracleRouter, PriceOracleRouter) onlyRole(ORACLE_ROLE) {
        super.setFeed(asset, feed);
    }

    function addAsset(address asset, uint16 yieldSplit) external onlyRole(ADMIN_ROLE) {
        if (assets[asset].exists) revert AssetExists();
        if (feeds[asset].feedType == FEED_NONE) revert FeedNotSet();
        if (yieldSplit > BPS) revert BpsTooHigh();

        AssetConfig storage cfg = assets[asset];
        cfg.exists = true;
        cfg.yieldSplit = yieldSplit;
        cfg.pausedMinting = false;
        assetList.push(asset);

        emit AssetAdd(asset);
    }

    function removeAsset(address asset, uint256 hintId) external onlyRole(ADMIN_ROLE) {
        if (!assets[asset].exists) revert AssetUnknown();
        if (!assets[asset].pausedMinting) revert NotPaused();

        uint256 len = assetList.length;
        if (hintId >= len) revert BadHint();
        if (assetList[hintId] != asset) revert HintMismatch();

        uint256 index = hintId;
        uint256 lastIndex = assetList.length - 1;
        if (index != lastIndex) {
            assetList[index] = assetList[lastIndex];
        }
        assetList.pop();
        delete assets[asset];
        delete feeds[asset];
        emit AssetRemove(asset);
    }

    function setPaused(address asset, bool paused) external onlyRole(ADMIN_ROLE) {
        if (!assets[asset].exists) revert AssetUnknown();
        assets[asset].pausedMinting = paused;
        emit MintingPauseUpdate(asset, paused);
    }

    function setYieldSplit(address asset, uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (!assets[asset].exists) revert AssetUnknown();
        if (bps > BPS) revert BpsTooHigh();
        assets[asset].yieldSplit = bps;
        emit YieldSplitUpdate(asset, bps);
    }

    /// @notice Split yield into senior accrual (stays in GRAI) and protocol profit (to `treasury`).
    function distribute(address asset, uint256 yieldAmount) public payable {
        AssetConfig storage cfg = assets[asset];
        if (!cfg.exists) revert AssetUnknown();
        if (yieldAmount == 0) revert AmountZero();

        uint256 seniorShare = (yieldAmount * cfg.yieldSplit) / BPS;
        uint256 treasuryShare = yieldAmount - seniorShare;

        emit Distribute(msg.sender, asset, yieldAmount, seniorShare, treasuryShare);

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
    }

    function deposit(address asset, uint256 amount) public payable returns (uint256 depositValue) {
        AssetConfig storage cfg = assets[asset];
        if (!cfg.exists) revert AssetUnknown();
        if (cfg.pausedMinting) revert IGrinders.MintingPaused();
        if (amount == 0) revert AmountZero();

        if (asset == address(0)) {
            if (msg.value != amount) revert IGrinders.ValueMismatch();
        } else {
            if (msg.value != 0) revert IGrinders.UnexpectedValue();
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }

        depositValue = usdValue(asset, amount);
        if (depositValue == 0) revert IGrinders.ValueZero();

        uint256 supply = totalSupply();
        uint256 value = totalValue;
        uint256 graiOut;
        if (supply == 0 || value == 0) {
            graiOut = depositValue;
        } else {
            graiOut = (depositValue * supply) / value;
        }
        if (graiOut == 0) revert AmountZero();

        totalValue += depositValue;
        _mint(msg.sender, graiOut);
        emit Mint(msg.sender, graiOut, depositValue);
    }

    function redeem(uint256 graiAmount) public {
        if (graiAmount == 0) revert AmountZero();
        if (graiAmount > balanceOf(msg.sender)) revert AmountExceedsSupply();
        if (graiAmount > maxRedeem()) revert InvalidRedeemAmount();
        if (totalSupply() == 0) revert NoSupply();

        uint256 supply = totalSupply();
        uint256 valueOut = (graiAmount * totalValue) / supply;

        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            uint256 seniorBalance = balance(asset);
            if (seniorBalance == 0) continue;
            uint256 redeemAmount = (graiAmount * seniorBalance) / supply;
            if (redeemAmount == 0) continue;
            _withdrawAsset(asset, msg.sender, redeemAmount);
        }

        _burn(msg.sender, graiAmount);
        totalValue -= valueOut;
        emit Burn(msg.sender, graiAmount, valueOut);
    }

    function ask(address asset, uint256 maxPayment, uint256 minPayment, uint256 duration, uint256 graiAmount)
        public
        returns (uint256 auctionId)
    {
        if (graiAmount == 0 || maxPayment == 0) revert AmountZero();
        if (duration == 0) revert DurationZero();
        if (minPayment > maxPayment) revert MinAboveMax();

        uint256 taxGrai = harbergerTax(graiAmount, duration);
        if (graiAmount + taxGrai > balanceOf(msg.sender)) revert AmountExceedsSupply();

        if (taxGrai > 0) _transfer(msg.sender, treasury, taxGrai);

        auctionId = ++nextAuctionId;
        auctions[auctionId] = AuctionLot({
            seller: msg.sender,
            asset: asset,
            graiRemaining: graiAmount,
            graiInitial: graiAmount,
            maxPayment: maxPayment,
            minPayment: minPayment,
            startTime: block.timestamp,
            duration: duration,
            listIndex: auctionIds.length
        });
        auctionIds.push(auctionId);

        emit Ask(auctionId, msg.sender, asset, graiAmount, maxPayment, minPayment, duration, taxGrai);
    }

    function bid(uint256 auctionId, uint256 graiAmount) public payable {
        AuctionLot storage entry = auctions[auctionId];
        if (entry.seller == address(0)) revert AuctionNotFound();

        // After listing duration, seller cancels residual lot with `bid(id, 0)`.
        if (graiAmount == 0) {
            if (block.timestamp < entry.startTime + entry.duration) revert AuctionNotExpired();
            if (msg.sender != entry.seller) revert NotSeller();
            if (msg.value != 0) revert UnexpectedValue();

            uint256 residual = entry.graiRemaining;
            address seller_ = entry.seller;
            _removeAuction(auctionId);
            emit Unplace(auctionId, seller_, residual);
            return;
        }

        if (graiAmount == type(uint256).max) graiAmount = entry.graiRemaining;
        if (graiAmount > entry.graiRemaining) revert InvalidBidAmount();

        uint256 payment = (auctionPrice(auctionId) * graiAmount) / entry.graiInitial;
        if (payment == 0) revert AmountZero();

        address seller = entry.seller;
        address asset = entry.asset;

        if (asset == address(0)) {
            if (msg.value != payment) revert ValueMismatch();
            (bool ok,) = seller.call{value: payment}("");
            if (!ok) revert EthTransferFailed();
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(msg.sender, seller, payment);
        }

        if (graiAmount > balanceOf(seller)) revert AmountExceedsSupply();

        uint256 remaining = entry.graiRemaining - graiAmount;
        if (remaining == 0) {
            _removeAuction(auctionId);
        } else {
            entry.graiRemaining = remaining;
        }

        _transfer(seller, msg.sender, graiAmount);
        emit Bid(auctionId, msg.sender, seller, asset, graiAmount, payment, remaining);
    }

    /// @inheritdoc IGRAI
    /// @dev Dutch ask for the full initial lot: maxPayment → minPayment over `duration`.
    function auctionPrice(uint256 auctionId) public view returns (uint256) {
        AuctionLot storage entry = auctions[auctionId];
        if (entry.seller == address(0)) revert AuctionNotFound();

        uint256 maxPayment = entry.maxPayment;
        uint256 minPayment = entry.minPayment;
        uint256 elapsed = block.timestamp - entry.startTime;
        if (elapsed >= entry.duration) return minPayment;
        return maxPayment - ((maxPayment - minPayment) * elapsed) / entry.duration;
    }

    /// @inheritdoc IGRAI
    /// @dev Prepaid Harberger tax in GRAI for listing `graiAmount` over `duration` at `HARBERGER_BPS` / year.
    function harbergerTax(uint256 graiAmount, uint256 duration) public pure returns (uint256) {
        return (graiAmount * HARBERGER_BPS * duration) / (uint256(BPS) * 365 days);
    }

    function withdraw(address asset, address to, uint256 amount) public onlyRole(GRINDERS_ROLE) {
        taken[asset] += amount;
        _withdrawAsset(asset, to, amount);
    }

    function _withdrawAsset(address asset, address to, uint256 amount) internal {
        if (asset == address(0)) {
            if (to == address(0)) revert ToZero();
            if (amount == 0) revert AmountZero();
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _removeAuction(uint256 auctionId) internal {
        uint256 index = auctions[auctionId].listIndex;
        uint256 lastIndex = auctionIds.length - 1;
        if (index != lastIndex) {
            uint256 lastId = auctionIds[lastIndex];
            auctionIds[index] = lastId;
            auctions[lastId].listIndex = index;
        }
        auctionIds.pop();
        delete auctions[auctionId];
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
