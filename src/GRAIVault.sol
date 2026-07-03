// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SeniorVault} from "./SeniorVault.sol";
import {JuniorVault} from "./JuniorVault.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";
import {IPriceOracleRouter} from "./interfaces/IPriceOracleRouter.sol";

contract GRAIVault is OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000; // 100%
    uint8 public constant USD_DECIMALS = 18;
    uint16 public constant DEFAULT_MINT_SPLIT = 5_000; // 50%
    uint16 public constant DEFAULT_YIELD_SPLIT = 8_000; // 80%

    struct AssetConfig {
        bool exists;
        SeniorVault senior; // (idle reserve)
        JuniorVault junior; //  (active capital)
        address priceFeed; // Chainlink AggregatorV3 (or custom feed) for this asset
        uint16 mintSplit; // bps to senior on mint
        uint16 yieldSplit; // bps to senior on distribute
        bool pausedMinting;
        uint256 totalValue; // cumulative USD value (USD_DECIMALS) attributed to this asset
        uint256 activeAmount; // asset units currently out in custody (sum of allocations)
    }

    mapping(address => AssetConfig) public assets;
    address[] public assetList;

    uint256 public totalValue;
    address public treasury;

    IPriceOracleRouter public oracle;
    IGRAI public grai;

    address public seniorImpl;
    address public juniorImpl;

    /// custody => asset => cumulative units allocated to that custody.
    mapping(address => mapping(address => uint256)) public allocatedAmount;

    /// custody => asset => cumulative yield units returned by that custody.
    mapping(address => mapping(address => uint256)) public yieldReturned;

    /// @dev Storage gap for future upgrades.
    uint256[40] private __gap;

    // ----------------------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------------------

    event TreasuryUpdated(address indexed treasury);
    event AssetAdded(address indexed asset, address senior, address junior, address priceFeed);
    event AssetRemoved(address indexed asset);
    event PriceFeedUpdated(address indexed asset, address feed);
    event PausedMintingUpdated(address indexed asset, bool paused);
    event MintSplitUpdated(address indexed asset, uint16 bps);
    event YieldSplitUpdated(address indexed asset, uint16 bps);
    event Minted(
        address indexed minter, address indexed asset, uint256 amountIn, uint256 graiOut, uint256 depositValue
    );
    event Burned(address indexed burner, uint256 graiAmount, uint256 burnValue);
    event Allocated(address indexed asset, address indexed custody, uint256 amount);
    event Distributed(
        address indexed asset, address indexed custody, uint256 yieldAmount, uint256 seniorYield, uint256 treasuryYield
    );

    // ----------------------------------------------------------------------------------
    // Init
    // ----------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address grai_,
        address oracle_,
        address seniorImpl_,
        address juniorImpl_,
        address treasury_
    ) external initializer {
        require(
            admin != address(0) && grai_ != address(0) && oracle_ != address(0) && seniorImpl_ != address(0)
                && juniorImpl_ != address(0) && treasury_ != address(0),
            "zero addr"
        );
        __Ownable_init(admin);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        grai = IGRAI(grai_);
        oracle = IPriceOracleRouter(oracle_);
        seniorImpl = seniorImpl_;
        juniorImpl = juniorImpl_;
        treasury = treasury_;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "treasury=0");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function addAsset(address asset, address priceFeed) external onlyOwner returns (address senior, address junior) {
        require(asset != address(0), "asset=0");
        require(priceFeed != address(0), "feed=0");
        require(!assets[asset].exists, "exists");

        SeniorVault s = SeniorVault(Clones.clone(seniorImpl));
        JuniorVault j = JuniorVault(Clones.clone(juniorImpl));
        s.initialize(address(this), asset);
        j.initialize(address(this), asset);

        assets[asset] = AssetConfig({
            exists: true,
            senior: s,
            junior: j,
            priceFeed: priceFeed,
            mintSplit: DEFAULT_MINT_SPLIT,
            yieldSplit: DEFAULT_YIELD_SPLIT,
            pausedMinting: false,
            totalValue: 0,
            activeAmount: 0
        });
        assetList.push(asset);

        emit AssetAdded(asset, address(s), address(j), priceFeed);
        return (address(s), address(j));
    }

    function removeAsset(address asset) external onlyOwner {
        AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(a.pausedMinting, "not paused");
        require(a.activeAmount == 0, "active funds");

        uint256 sBal = a.senior.balance();
        if (sBal > 0) a.senior.withdraw(msg.sender, sBal);
        uint256 jBal = a.junior.balance();
        if (jBal > 0) a.junior.withdraw(msg.sender, jBal);

        totalValue -= a.totalValue;

        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            if (assetList[i] == asset) {
                assetList[i] = assetList[len - 1];
                assetList.pop();
                break;
            }
        }
        delete assets[asset];
        emit AssetRemoved(asset);
    }

    function setPriceFeed(address asset, address feed) external onlyOwner {
        require(assets[asset].exists, "unknown asset");
        require(feed != address(0), "feed=0");
        assets[asset].priceFeed = feed;
        emit PriceFeedUpdated(asset, feed);
    }

    function setPaused(address asset, bool paused) external onlyOwner {
        require(assets[asset].exists, "unknown asset");
        assets[asset].pausedMinting = paused;
        emit PausedMintingUpdated(asset, paused);
    }

    function setMintSplit(address asset, uint16 bps) external onlyOwner {
        require(assets[asset].exists, "unknown asset");
        require(bps <= BPS, "bps>max");
        assets[asset].mintSplit = bps;
        emit MintSplitUpdated(asset, bps);
    }

    function setYieldSplit(address asset, uint16 bps) external onlyOwner {
        require(assets[asset].exists, "unknown asset");
        require(bps <= BPS, "bps>max");
        assets[asset].yieldSplit = bps;
        emit YieldSplitUpdated(asset, bps);
    }

    function mint(address asset, uint256 amount) external nonReentrant returns (uint256 graiOut) {
        AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(!a.pausedMinting, "paused");
        require(amount > 0, "amount=0");

        uint256 idle = (amount * a.mintSplit) / BPS; // to senior
        uint256 active = amount - idle; // to junior

        if (idle > 0) IERC20(asset).safeTransferFrom(msg.sender, address(a.senior), idle);
        if (active > 0) IERC20(asset).safeTransferFrom(msg.sender, address(a.junior), active);

        uint256 depositValue = _usdValue(asset, amount);
        require(depositValue > 0, "value=0");

        uint256 supply = grai.totalSupply();
        graiOut = (supply == 0 || totalValue == 0) ? depositValue : (depositValue * supply) / totalValue;
        require(graiOut > 0, "grai=0");

        a.totalValue += depositValue;
        totalValue += depositValue;

        grai.mint(msg.sender, graiOut);
        emit Minted(msg.sender, asset, amount, graiOut, depositValue);
    }

    function burn(uint256 graiAmount) external nonReentrant {
        require(graiAmount > 0, "amount=0");
        uint256 supply = grai.totalSupply();
        require(supply > 0, "no supply");
        require(graiAmount <= supply, "amount>supply");

        uint256 totalValueBefore = totalValue;
        uint256 burnValue = (graiAmount * totalValueBefore) / supply;

        // Burn first (checks-effects-interactions); requires allowance to this vault.
        grai.burnFrom(msg.sender, graiAmount);

        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            AssetConfig storage a = assets[assetList[i]];

            if (totalValueBefore > 0 && a.totalValue > 0) {
                uint256 share = (burnValue * a.totalValue) / totalValueBefore;
                if (share > a.totalValue) share = a.totalValue;
                a.totalValue -= share;
            }

            uint256 idleBal = a.senior.balance();
            if (idleBal == 0) continue;
            uint256 redeem = (graiAmount * idleBal) / supply; // senior idle only
            if (redeem > 0) a.senior.withdraw(msg.sender, redeem);
        }

        totalValue = totalValueBefore - burnValue;
        emit Burned(msg.sender, graiAmount, burnValue);
    }

    function allocate(address asset, address custody, uint256 amount) external onlyOwner nonReentrant {
        AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(custody != address(0), "custody=0");
        require(amount > 0, "amount=0");

        a.activeAmount += amount;
        allocatedAmount[custody][asset] += amount;

        a.junior.withdraw(custody, amount);
        emit Allocated(asset, custody, amount);
    }

    function distribute(address asset, uint256 yieldAmount) external nonReentrant {
        AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(yieldAmount > 0, "amount=0");

        uint256 seniorYield = (yieldAmount * a.yieldSplit) / BPS;
        uint256 treasuryYield = yieldAmount - seniorYield;

        if (seniorYield > 0) IERC20(asset).safeTransferFrom(msg.sender, address(a.senior), seniorYield);
        if (treasuryYield > 0) IERC20(asset).safeTransferFrom(msg.sender, treasury, treasuryYield);

        // Only the senior-credited portion increases NAV (matches Solana distribute).
        uint256 yieldValue = seniorYield > 0 ? _usdValue(asset, seniorYield) : 0;
        a.totalValue += yieldValue;
        totalValue += yieldValue;

        yieldReturned[msg.sender][asset] += yieldAmount;
        emit Distributed(asset, msg.sender, yieldAmount, seniorYield, treasuryYield);
    }

    function nav() external view returns (uint256 total) {
        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            uint256 idleBal = assets[asset].senior.balance();
            if (idleBal > 0) total += _usdValue(asset, idleBal);
        }
    }

    function getAssets() external view returns (address[] memory) {
        return assetList;
    }

    struct VaultSnapshot {
        address asset;
        address senior;
        address junior;
        uint256 seniorBalance;
        uint256 juniorBalance;
        uint256 activeAmount;
    }

    function getVaults() external view returns (VaultSnapshot[] memory snapshot) {
        uint256 len = assetList.length;
        snapshot = new VaultSnapshot[](len);
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            AssetConfig storage a = assets[asset];
            snapshot[i] = VaultSnapshot({
                asset: asset,
                senior: address(a.senior),
                junior: address(a.junior),
                seniorBalance: a.senior.balance(),
                juniorBalance: a.junior.balance(),
                activeAmount: a.activeAmount
            });
        }
    }

    function assetCount() external view returns (uint256) {
        return assetList.length;
    }

    function _usdValue(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        (uint256 price, uint8 pdec) = oracle.getPrice(assets[asset].priceFeed);
        uint8 adec = IERC20Metadata(asset).decimals();
        return (amount * price * (10 ** USD_DECIMALS)) / (10 ** adec) / (10 ** pdec);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
