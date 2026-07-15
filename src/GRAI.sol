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

    uint16 internal constant BPS = 100_00;
    /// @notice Harberger tax rate on listed GRAI, annualized (1% / year).
    uint16 public constant APR_BPS = 100;

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
    mapping(address seller => AuctionLot) public asks;

    /// @dev Storage gap for future upgrades.
    uint256[33] private _gap;

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
    function seniorNAV() public view returns (uint256 value) {
        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            uint256 bal = balance(asset);
            if (bal > 0) value += usdValue(asset, bal);
        }
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

        uint256 scale = 10 ** decimals();
        // Exact invert of: nav >= (graiAmount * ((totalValue * scale) / supply)) / scale
        if ((totalValue * scale) / supply == 0) return supply;

        uint256 byNav = ((seniorNAV() + 1) * scale - 1) / ((totalValue * scale) / supply);
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
            assets[moved].id = uint32(index);
        }
        assetList.pop();
        delete assets[asset];
        delete feeds[asset];
        emit AssetRemove(asset);
    }

    function setPaused(address asset, bool paused) external onlyRole(ADMIN_ROLE) {
        if (feeds[asset].feedType == FEED_NONE) revert AssetUnknown();
        assets[asset].paused = paused;
        emit MintingPauseUpdate(asset, paused);
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

    function deposit(address asset, uint256 amount) public payable returns (uint256 graiOut, uint256 depositValue) {
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

    function ask(
        address asset,
        uint256 maxPayment,
        uint256 minPayment,
        uint256 duration,
        uint256 graiAmount
    ) public {
        if (asks[msg.sender].startTime != 0) revert AskExists();
        if (graiAmount == 0 || maxPayment == 0) revert AmountZero();
        if (duration == 0) revert DurationZero();
        if (minPayment > maxPayment) revert MinAboveMax();
        if (graiAmount > balanceOf(msg.sender)) revert AmountExceedsSupply();

        uint256 tax = previewTax(graiAmount, duration);
        if (tax > 0) _transfer(msg.sender, treasury, tax);

        uint256 lot = graiAmount - tax;
        asks[msg.sender] = AuctionLot({
            asset: asset,
            graiRemaining: lot,
            graiInitial: lot,
            maxPayment: maxPayment,
            minPayment: minPayment,
            startTime: block.timestamp,
            duration: duration
        });
        emit Ask(msg.sender, asset, graiAmount, maxPayment, minPayment, duration, tax);
    }

    /// @inheritdoc IGRAI
    function previewTax(uint256 graiAmount, uint256 duration) public pure returns (uint256) {
        return (graiAmount * APR_BPS * duration) / (uint256(BPS) * 365 days);
    }

    function bid(address seller, uint256 graiAmount) public payable {
        AuctionLot storage entry = asks[seller];
        if (entry.startTime == 0) revert AuctionNotFound();

        if (graiAmount == type(uint256).max) graiAmount = entry.graiRemaining;
        if (graiAmount == 0 || graiAmount > entry.graiRemaining) revert InvalidBidAmount();
        if (graiAmount > balanceOf(seller)) revert AmountExceedsSupply();

        uint256 bidAmount = previewBid(seller, graiAmount);
        if (bidAmount == 0) revert AmountZero();

        address asset = entry.asset;
        _pay(seller, asset, bidAmount);
        // `_update` shrinks / clears `asks[seller]` for this outbound transfer.
        _transfer(seller, msg.sender, graiAmount);
        emit Bid(msg.sender, seller, asset, graiAmount, bidAmount);
    }

    /// @inheritdoc IGRAI
    /// @dev Dutch payment for `graiAmount`: maxPayment → minPayment over `duration`, scaled by lot size.
    function previewBid(address seller, uint256 graiAmount) public view returns (uint256) {
        AuctionLot storage entry = asks[seller];
        if (entry.startTime == 0) revert AuctionNotFound();

        uint256 maxPayment = entry.maxPayment;
        uint256 minPayment = entry.minPayment;
        uint256 elapsed = block.timestamp - entry.startTime;
        uint256 price = elapsed >= entry.duration
            ? minPayment
            : maxPayment - ((maxPayment - minPayment) * elapsed) / entry.duration;
        return (price * graiAmount) / entry.graiInitial;
    }

    /// @dev Outbound GRAI (transfer / burn) shrinks an open ask pro-rata; full drain deletes it.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && value != 0) {
            AuctionLot storage entry = asks[from];
            uint256 remaining = entry.graiRemaining;
            if (entry.startTime != 0) {
                if (value >= remaining) {
                    delete asks[from];
                } else {
                    uint256 newRemaining = remaining - value;
                    entry.maxPayment = (entry.maxPayment * newRemaining) / remaining;
                    entry.minPayment = (entry.minPayment * newRemaining) / remaining;
                    // Keep dutch scale consistent with `previewBid` (price * amount / graiInitial).
                    entry.graiInitial = (entry.graiInitial * newRemaining) / remaining;
                    entry.graiRemaining = newRemaining;
                }
            }
        }
        super._update(from, to, value);
    }

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
