// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SeniorVault} from "./SeniorVault.sol";
import {JuniorVault} from "./JuniorVault.sol";
import {IPriceOracleRouter} from "./interfaces/IPriceOracleRouter.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";

contract GRAI is
    IGRAI,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 100_00; // 100%
    uint8 public constant USD_DECIMALS = 18;
    uint16 public constant DEFAULT_MINT_SPLIT = 50_00; // 50%
    uint16 public constant DEFAULT_YIELD_SPLIT = 80_00; // 80%

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    mapping(address => IGRAI.AssetConfig) public assets;
    address[] public assetList;

    uint256 public totalValue;
    address public treasury;

    IPriceOracleRouter public oracle;
    SeniorVault public seniorVault;
    JuniorVault public juniorVault;

    /// custody => asset => cumulative units allocated to that custody.
    mapping(address custody => mapping(address asset => uint256)) public allocatedAmount;

    /// custody => asset => cumulative yield units returned by that custody.
    mapping(address custody => mapping(address asset => uint256)) public yieldReturned;

    string private _tokenURI;

    /// @dev Storage gap for future upgrades.
    uint256[39] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address oracle_, address treasury_) external initializer {
        require(admin != address(0) && oracle_ != address(0) && treasury_ != address(0), "zero addr");
        __ERC20_init("Grinders Artificial Index", "GRAI");
        _tokenURI = "https://grindurus.xyz/metadata.json";
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        oracle = IPriceOracleRouter(oracle_);
        treasury = treasury_;

        SeniorVault s = new SeniorVault(address(this));
        JuniorVault j = new JuniorVault(address(this));
        seniorVault = s;
        juniorVault = j;
    }

    function tokenURI() external view returns (string memory) {
        return _tokenURI;
    }

    function setTokenURI(string calldata tokenURI_) external onlyRole(ADMIN_ROLE) {
        _tokenURI = tokenURI_;
        emit TokenURIUpdate(tokenURI_);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        require(newTreasury != address(0), "treasury=0");
        treasury = newTreasury;
        emit TreasuryUpdate(newTreasury);
    }

    function addAsset(address asset) external onlyRole(ADMIN_ROLE) {
        require(!assets[asset].exists, "exists");

        assets[asset] = IGRAI.AssetConfig({
            exists: true,
            mintSplit: DEFAULT_MINT_SPLIT,
            yieldSplit: DEFAULT_YIELD_SPLIT,
            pausedMinting: false,
            totalValue: 0,
            activeAmount: 0
        });
        assetList.push(asset);

        if (asset != address(0)) {
            IERC20(asset).forceApprove(address(seniorVault), type(uint256).max);
            IERC20(asset).forceApprove(address(juniorVault), type(uint256).max);
        }

        emit AssetAdd(asset);
    }

    function removeAsset(address asset) external onlyRole(ADMIN_ROLE) {
        IGRAI.AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(a.pausedMinting, "not paused");

        uint256 sBal = seniorVault.balance(asset);
        if (sBal > 0) seniorVault.withdraw(asset, msg.sender, sBal);
        uint256 jBal = juniorVault.balance(asset);
        if (jBal > 0) juniorVault.withdraw(asset, msg.sender, jBal);

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
        emit AssetRemove(asset);
    }

    function setPaused(address asset, bool paused) external onlyRole(ADMIN_ROLE) {
        require(assets[asset].exists, "unknown asset");
        assets[asset].pausedMinting = paused;
        emit MintingPauseUpdate(asset, paused);
    }

    function setMintSplit(address asset, uint16 bps) external onlyRole(ADMIN_ROLE) {
        require(assets[asset].exists, "unknown asset");
        require(bps <= BPS, "bps>max");
        assets[asset].mintSplit = bps;
        emit MintSplitUpdate(asset, bps);
    }

    function setYieldSplit(address asset, uint16 bps) external onlyRole(ADMIN_ROLE) {
        require(assets[asset].exists, "unknown asset");
        require(bps <= BPS, "bps>max");
        assets[asset].yieldSplit = bps;
        emit YieldSplitUpdate(asset, bps);
    }

    function mint(address asset, uint256 amount) external payable nonReentrant returns (uint256 graiOut) {
        IGRAI.AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(!a.pausedMinting, "paused");
        require(amount > 0, "amount=0");

        uint256 idle = (amount * a.mintSplit) / BPS; // to senior
        uint256 active = amount - idle; // to junior

        if (asset == address(0)) {
            require(msg.value == amount, "value mismatch");
            if (idle > 0) seniorVault.deposit{value: idle}(address(0), idle);
            if (active > 0) juniorVault.deposit{value: active}(address(0), active);
        } else {
            require(msg.value == 0, "unexpected value");
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            if (idle > 0) seniorVault.deposit(asset, idle);
            if (active > 0) juniorVault.deposit(asset, active);
        }

        uint256 depositValue = _usdValue(asset, amount);
        require(depositValue > 0, "value=0");

        uint256 supply = totalSupply();
        graiOut = (supply == 0 || totalValue == 0) ? depositValue : (depositValue * supply) / totalValue;
        require(graiOut > 0, "grai=0");

        a.totalValue += depositValue;
        totalValue += depositValue;

        _mint(msg.sender, graiOut);
        emit Mint(msg.sender, asset, amount, graiOut, depositValue);
    }

    function burn(uint256 graiAmount) public override nonReentrant {
        require(graiAmount > 0, "amount=0");
        uint256 supply = totalSupply();
        require(supply > 0, "no supply");
        require(graiAmount <= supply, "amount>supply");

        uint256 totalValueBefore = totalValue;
        uint256 burnValue = (graiAmount * totalValueBefore) / supply;

        _burn(msg.sender, graiAmount);

        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            IGRAI.AssetConfig storage a = assets[asset];

            if (totalValueBefore > 0 && a.totalValue > 0) {
                uint256 share = (burnValue * a.totalValue) / totalValueBefore;
                if (share > a.totalValue) share = a.totalValue;
                a.totalValue -= share;
            }

            uint256 idleBal = seniorVault.balance(asset);
            if (idleBal == 0) continue;
            uint256 redeem = (graiAmount * idleBal) / supply; // senior idle only
            if (redeem > 0) seniorVault.withdraw(asset, msg.sender, redeem);
        }

        totalValue = totalValueBefore - burnValue;
        emit Burn(msg.sender, graiAmount, burnValue);
    }

    function allocate(address asset, address custody, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        IGRAI.AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(custody != address(0), "custody=0");
        require(amount > 0, "amount=0");

        a.activeAmount += amount;
        allocatedAmount[custody][asset] += amount;

        juniorVault.withdraw(asset, custody, amount);
        emit Allocate(asset, custody, amount);
    }

    function distribute(address asset, uint256 yieldAmount) external payable nonReentrant {
        IGRAI.AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(yieldAmount > 0, "amount=0");

        uint256 seniorYield = (yieldAmount * a.yieldSplit) / BPS;
        uint256 treasuryYield = yieldAmount - seniorYield;

        if (asset == address(0)) {
            require(msg.value == yieldAmount, "value mismatch");
            if (seniorYield > 0) seniorVault.deposit{value: seniorYield}(address(0), seniorYield);
            if (treasuryYield > 0) {
                (bool ok,) = treasury.call{value: treasuryYield}("");
                require(ok, "eth transfer failed");
            }
        } else {
            require(msg.value == 0, "unexpected value");
            if (seniorYield > 0) {
                IERC20(asset).safeTransferFrom(msg.sender, address(this), seniorYield);
                seniorVault.deposit(asset, seniorYield);
            }
            if (treasuryYield > 0) IERC20(asset).safeTransferFrom(msg.sender, treasury, treasuryYield);
        }

        // Only the senior-credited portion increases NAV (matches Solana distribute).
        uint256 yieldValue = seniorYield > 0 ? _usdValue(asset, seniorYield) : 0;
        a.totalValue += yieldValue;
        totalValue += yieldValue;

        yieldReturned[msg.sender][asset] += yieldAmount;
        emit Distribute(asset, msg.sender, yieldAmount, seniorYield, treasuryYield);
    }

    function nav() external view returns (uint256 total) {
        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            uint256 idleBal = seniorVault.balance(asset);
            if (idleBal > 0) total += _usdValue(asset, idleBal);
        }
    }

    function getAssets() external view returns (address[] memory) {
        return assetList;
    }

    function getVaults() external view returns (IGRAI.VaultSnapshot[] memory snapshot) {
        uint256 len = assetList.length;
        snapshot = new IGRAI.VaultSnapshot[](len);
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            IGRAI.AssetConfig storage a = assets[asset];
            snapshot[i] = IGRAI.VaultSnapshot({
                asset: asset,
                seniorBalance: seniorVault.balance(asset),
                juniorBalance: juniorVault.balance(asset),
                activeAmount: a.activeAmount
            });
        }
    }

    function assetCount() external view returns (uint256) {
        return assetList.length;
    }

    function _usdValue(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        (uint256 price, uint8 pdec) = oracle.getPrice(asset);
        uint8 adec = asset == address(0) ? 18 : IERC20Metadata(asset).decimals();
        return (amount * price * (10 ** USD_DECIMALS)) / (10 ** adec) / (10 ** pdec);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
