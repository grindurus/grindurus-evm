// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SeniorVault} from "./SeniorVault.sol";
import {JuniorVault} from "./JuniorVault.sol";
import {IPriceOracleRouter} from "./interfaces/IPriceOracleRouter.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";

/// @title GRAI (implementation)
/// @dev Do not call this contract directly. Use the ERC1967Proxy address only.
///      Direct calls write to implementation storage, not the live protocol state.
contract GRAI is
    IGRAI,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint8 public constant USD_DECIMALS = 18;
    uint16 public constant BPS = 100_00; // 100%
    uint16 public constant DEFAULT_MINT_SPLIT = 50_00; // 50%
    uint16 public constant DEFAULT_YIELD_SPLIT = 80_00; // 80%

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    mapping(address asset => IGRAI.AssetConfig) public assets;
    address[] public assetList;

    uint256 public totalValue;
    address public treasury;

    IPriceOracleRouter public oracle;
    SeniorVault public seniorVault;
    JuniorVault public juniorVault;

    /// custody => asset => cumulative units allocated to that custody.
    mapping(address custody => mapping(address asset => uint256)) public allocatedAmount;

    /// custody => asset => cumulative yield units returned by that custody.
    mapping(address custody => mapping(address asset => uint256)) public yieldGenerated;

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
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        oracle = IPriceOracleRouter(oracle_);
        treasury = treasury_;
        _tokenURI = "https://grindurus.xyz/metadata.json";

        SeniorVault s = new SeniorVault(address(this));
        JuniorVault j = new JuniorVault(address(this));
        seniorVault = s;
        juniorVault = j;
    }

    receive() external payable {}

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

    function addAsset(address asset, uint16 mintSplit, uint16 yieldSplit) external onlyRole(ADMIN_ROLE) {
        require(!assets[asset].exists, "exists");
        require(mintSplit <= BPS, "bps>max");
        require(yieldSplit <= BPS, "bps>max");

        assets[asset] = IGRAI.AssetConfig({
            exists: true,
            mintSplit: mintSplit,
            yieldSplit: yieldSplit,
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

    function removeAsset(address asset, uint256 hintId) external onlyRole(ADMIN_ROLE) {
        IGRAI.AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(a.pausedMinting, "not paused");

        uint256 sBal = seniorVault.balance(asset);
        if (sBal > 0) seniorVault.withdraw(asset, msg.sender, sBal);
        uint256 jBal = juniorVault.balance(asset);
        if (jBal > 0) juniorVault.withdraw(asset, msg.sender, jBal);

        totalValue -= a.totalValue;

        uint256 len = assetList.length;
        require(hintId < len, "bad hint");
        require(assetList[hintId] == asset, "hint mismatch");

        uint256 index = hintId;
        uint256 lastIndex = assetList.length - 1;
        if (index != lastIndex) {
            assetList[index] = assetList[lastIndex];
        }
        assetList.pop();
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

    function sweep(address asset, address to) external onlyRole(ADMIN_ROLE) {
        require(to != address(0), "to=0");
        if (asset == address(0)) {
            uint256 amount = address(this).balance;
            require(amount > 0, "amount=0");
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth transfer failed");
            emit Sweep(asset, to, amount);
        } else {
            uint256 amount = IERC20(asset).balanceOf(address(this));
            require(amount > 0, "amount=0");
            IERC20(asset).safeTransfer(to, amount);
            emit Sweep(asset, to, amount);
        }
    }

    function mint(address asset, uint256 amount) external payable returns (uint256 graiOut) {
        IGRAI.AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(!a.pausedMinting, "paused");
        require(amount > 0, "amount=0");

        uint256 seniorBalanceIn = (amount * a.mintSplit) / BPS;
        uint256 juniorBalanceIn = amount - seniorBalanceIn;

        uint256 depositValue = usdValue(asset, amount);
        require(depositValue > 0, "value=0");

        uint256 supply = totalSupply();
        graiOut = (supply == 0 || totalValue == 0) ? depositValue : (depositValue * supply) / totalValue;
        require(graiOut > 0, "grai=0");

        // Effects: mint GRAI and update NAV before pulling assets into vaults.
        a.totalValue += depositValue;
        totalValue += depositValue;
        _mint(msg.sender, graiOut);
        emit Mint(msg.sender, asset, amount, graiOut, depositValue);

        // Interactions: collect assets and route to senior/junior vaults.
        if (asset == address(0)) {
            require(msg.value == amount, "value mismatch");
            if (seniorBalanceIn > 0) seniorVault.deposit{value: seniorBalanceIn}(address(0), seniorBalanceIn);
            if (juniorBalanceIn > 0) juniorVault.deposit{value: juniorBalanceIn}(address(0), juniorBalanceIn);
        } else {
            require(msg.value == 0, "unexpected value");
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            if (seniorBalanceIn > 0) seniorVault.deposit(asset, seniorBalanceIn);
            if (juniorBalanceIn > 0) juniorVault.deposit(asset, juniorBalanceIn);
        }
    }

    function burn(uint256 graiAmount) public override {
        require(graiAmount > 0, "amount=0");
        uint256 supply = totalSupply();
        require(supply > 0, "no supply");
        require(graiAmount <= supply, "amount>supply");

        uint256 totalValueBefore = totalValue;
        uint256 burnValue = (graiAmount * totalValueBefore) / supply;

        uint256 len = assetList.length;
        address[] memory redeemAssets = new address[](len);
        uint256[] memory redeemAmounts = new uint256[](len);
        uint256 redeemCount;

        // Effects: burn GRAI and update NAV before any senior vault payouts.
        _burn(msg.sender, graiAmount);
        totalValue = totalValueBefore - burnValue;

        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            IGRAI.AssetConfig storage a = assets[asset];

            if (totalValueBefore > 0 && a.totalValue > 0) {
                uint256 share = (burnValue * a.totalValue) / totalValueBefore;
                if (share > a.totalValue) share = a.totalValue;
                a.totalValue -= share;
            }

            uint256 seniorBalance = seniorVault.balance(asset);
            if (seniorBalance == 0) continue;
            uint256 redeem = (graiAmount * seniorBalance) / supply;
            if (redeem == 0) continue;
            redeemAssets[redeemCount] = asset;
            redeemAmounts[redeemCount] = redeem;
            ++redeemCount;
        }

        emit Burn(msg.sender, graiAmount, burnValue);

        // Interactions: pay out from senior vault after all accounting is final.
        for (uint256 i; i < redeemCount; ++i) {
            seniorVault.withdraw(redeemAssets[i], msg.sender, redeemAmounts[i]);
        }
    }

    function allocate(address asset, address custody, uint256 amount) external onlyRole(ADMIN_ROLE) {
        IGRAI.AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(custody != address(0), "custody=0");
        require(amount > 0, "amount=0");

        a.activeAmount += amount;
        allocatedAmount[custody][asset] += amount;
        emit Allocate(asset, custody, amount);

        juniorVault.withdraw(asset, custody, amount);
    }

    function deallocate(address asset, uint256 amount) external payable {
        address custody = msg.sender;
        IGRAI.AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(amount > 0, "amount=0");
        require(allocatedAmount[custody][asset] >= amount, "insufficient allocation");
        require(a.activeAmount >= amount, "insufficient active");

        allocatedAmount[custody][asset] -= amount;
        a.activeAmount -= amount;
        emit Deallocate(asset, custody, amount);

        if (asset == address(0)) {
            require(msg.value == amount, "value mismatch");
            seniorVault.deposit{value: amount}(address(0), amount);
        } else {
            require(msg.value == 0, "unexpected value");
            IERC20(asset).safeTransferFrom(custody, address(this), amount);
            seniorVault.deposit(asset, amount);
        }
    }

    function distribute(address asset, uint256 yieldAmount) external payable {
        IGRAI.AssetConfig storage a = assets[asset];
        require(a.exists, "unknown asset");
        require(yieldAmount > 0, "amount=0");

        uint256 seniorYield = (yieldAmount * a.yieldSplit) / BPS;
        uint256 treasuryYield = yieldAmount - seniorYield;
        uint256 yieldValue = seniorYield > 0 ? usdValue(asset, seniorYield) : 0;

        // Effects: update NAV before pulling yield into vaults or treasury.
        a.totalValue += yieldValue;
        totalValue += yieldValue;
        yieldGenerated[msg.sender][asset] += yieldAmount;
        emit Distribute(asset, msg.sender, yieldAmount, seniorYield, treasuryYield);

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
    }

    function seniorNav() external view returns (uint256 total) {
        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            uint256 idleBal = seniorVault.balance(asset);
            if (idleBal > 0) total += usdValue(asset, idleBal);
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

    function usdValue(address asset, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        (uint256 price, uint8 pdec) = oracle.getPrice(asset);
        uint8 adec = asset == address(0) ? 18 : IERC20Metadata(asset).decimals();
        return (amount * price * (10 ** USD_DECIMALS)) / (10 ** adec) / (10 ** pdec);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
