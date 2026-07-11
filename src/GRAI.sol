// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Vault} from "./Vault.sol";
import {PriceOracleRouter} from "./PriceOracleRouter.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IPriceOracleRouter} from "./interfaces/IPriceOracleRouter.sol";

/// @title GRAI (implementation)
/// @dev Do not call this contract directly. Use the ERC1967Proxy address only.
///      Direct calls write to implementation storage, not the live protocol state.
contract GRAI is
    IGRAI,
    PriceOracleRouter,
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
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    mapping(address asset => IGRAI.AssetConfig) public assets;
    address[] public assetList;

    uint256 public totalValue;
    address public treasury;

    Vault public seniorVault;
    Vault public juniorVault;

    /// custodian => asset => cumulative units allocated to that custodian.
    mapping(address custodian => mapping(address asset => uint256)) public allocatedAmount;

    /// custodian => asset => cumulative yield units returned by that custodian.
    mapping(address custodian => mapping(address asset => uint256)) public yieldGenerated;

    string private _tokenUri;

    address public pendingOwner;
    address public currentOwner;

    /// @dev Storage gap for future upgrades.
    uint256[38] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __ERC20_init("Grinders Artificial Index", "GRAI");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(ORACLE_ROLE, admin);

        treasury = admin;
        _tokenUri = "https://grindurus.xyz/metadata.json";
        currentOwner = admin;

        seniorVault = new Vault(address(this));
        juniorVault = new Vault(address(this));
    }

    receive() external payable {}

    /// @notice Two-step handoff of `DEFAULT_ADMIN_ROLE` (upgrades + role admin).
    /// @dev Current holder: `transferOwnership(recipient)` offers. Recipient: same call accepts.
    function transferOwnership(address account) external {
        if (account == address(0)) revert ZeroAddress();

        if (pendingOwner == account && msg.sender == account) {
            address from = currentOwner;
            pendingOwner = address(0);
            _grantRole(DEFAULT_ADMIN_ROLE, account);
            if (from != account) {
                _revokeRole(DEFAULT_ADMIN_ROLE, from);
            }
            currentOwner = account;
            emit OwnershipAccepted(account);
            return;
        }

        if (msg.sender != currentOwner) revert NotCurrentOwner();
        if (pendingOwner != address(0)) revert OwnershipOfferPending();
        pendingOwner = account;
        emit OwnershipOffered(account);
    }

    function setFeed(address asset, Feed calldata feed)
        public
        override(IPriceOracleRouter, PriceOracleRouter)
        onlyRole(ORACLE_ROLE)
    {
        super.setFeed(asset, feed);
    }

    function tokenURI() external view returns (string memory) {
        return _tokenUri;
    }

    function setTokenURI(string calldata tokenUri_) external onlyRole(ADMIN_ROLE) {
        _tokenUri = tokenUri_;
        emit TokenURIUpdate(tokenUri_);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert TreasuryZero();
        treasury = newTreasury;
        emit TreasuryUpdate(newTreasury);
    }

    function addAsset(address asset, uint16 mintSplit, uint16 yieldSplit) external onlyRole(ADMIN_ROLE) {
        if (assets[asset].exists) revert AssetExists();
        if (mintSplit > BPS) revert BpsTooHigh();
        if (yieldSplit > BPS) revert BpsTooHigh();

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
        if (!a.exists) revert AssetUnknown();
        if (!a.pausedMinting) revert NotPaused();

        uint256 sBal = seniorVault.balance(asset);
        if (sBal > 0) seniorVault.withdraw(asset, msg.sender, sBal);
        uint256 jBal = juniorVault.balance(asset);
        if (jBal > 0) juniorVault.withdraw(asset, msg.sender, jBal);

        totalValue -= a.totalValue;

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
        emit AssetRemove(asset);
    }

    function setPaused(address asset, bool paused) external onlyRole(ADMIN_ROLE) {
        if (!assets[asset].exists) revert AssetUnknown();
        assets[asset].pausedMinting = paused;
        emit MintingPauseUpdate(asset, paused);
    }

    function setMintSplit(address asset, uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (!assets[asset].exists) revert AssetUnknown();
        if (bps > BPS) revert BpsTooHigh();
        assets[asset].mintSplit = bps;
        emit MintSplitUpdate(asset, bps);
    }

    function setYieldSplit(address asset, uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (!assets[asset].exists) revert AssetUnknown();
        if (bps > BPS) revert BpsTooHigh();
        assets[asset].yieldSplit = bps;
        emit YieldSplitUpdate(asset, bps);
    }

    function sweep(address asset, address to) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ToZero();
        if (asset == address(0)) {
            uint256 amount = address(this).balance;
            if (amount == 0) revert AmountZero();
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
            emit Sweep(asset, to, amount);
        } else {
            uint256 amount = IERC20(asset).balanceOf(address(this));
            if (amount == 0) revert AmountZero();
            IERC20(asset).safeTransfer(to, amount);
            emit Sweep(asset, to, amount);
        }
    }

    function mint(address asset, uint256 amount) external payable returns (uint256 graiOut) {
        IGRAI.AssetConfig storage a = assets[asset];
        if (!a.exists) revert AssetUnknown();
        if (a.pausedMinting) revert MintingPaused();
        if (amount == 0) revert AmountZero();

        uint256 seniorBalanceIn = (amount * a.mintSplit) / BPS;
        uint256 juniorBalanceIn = amount - seniorBalanceIn;

        uint256 depositValue = usdValue(asset, amount);
        if (depositValue == 0) revert ValueZero();

        uint256 supply = totalSupply();
        graiOut = (supply == 0 || totalValue == 0) ? depositValue : (depositValue * supply) / totalValue;
        if (graiOut == 0) revert GraiZero();

        // Effects: mint GRAI and update NAV before pulling assets into vaults.
        a.totalValue += depositValue;
        totalValue += depositValue;
        _mint(msg.sender, graiOut);
        emit Mint(msg.sender, asset, amount, graiOut, depositValue);

        // Interactions: collect assets and route to senior/junior vaults.
        if (asset == address(0)) {
            if (msg.value != amount) revert ValueMismatch();
            if (seniorBalanceIn > 0) seniorVault.deposit{value: seniorBalanceIn}(address(0), seniorBalanceIn);
            if (juniorBalanceIn > 0) juniorVault.deposit{value: juniorBalanceIn}(address(0), juniorBalanceIn);
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            if (seniorBalanceIn > 0) seniorVault.deposit(asset, seniorBalanceIn);
            if (juniorBalanceIn > 0) juniorVault.deposit(asset, juniorBalanceIn);
        }
    }

    function burn(uint256 graiAmount) public override {
        if (graiAmount == 0) revert AmountZero();
        uint256 supply = totalSupply();
        if (supply == 0) revert NoSupply();
        if (graiAmount > supply) revert AmountExceedsSupply();

        uint256 totalValueBefore = totalValue;
        uint256 burnValue = (graiAmount * totalValueBefore) / supply;

        // Effects: burn GRAI and update NAV before any senior vault payouts.
        _burn(msg.sender, graiAmount);
        totalValue = totalValueBefore - burnValue;

        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            IGRAI.AssetConfig storage a = assets[assetList[i]];
            if (totalValueBefore > 0 && a.totalValue > 0) {
                uint256 share = (burnValue * a.totalValue) / totalValueBefore;
                if (share > a.totalValue) share = a.totalValue;
                a.totalValue -= share;
            }
        }

        emit Burn(msg.sender, graiAmount, burnValue);

        // Interactions: pay out from senior vault after all accounting is final.
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            uint256 seniorBalance = seniorVault.balance(asset);
            if (seniorBalance == 0) continue;
            uint256 redeem = (graiAmount * seniorBalance) / supply;
            if (redeem == 0) continue;
            seniorVault.withdraw(asset, msg.sender, redeem);
        }
    }

    function allocate(address asset, address custodian, uint256 amount) external onlyRole(ADMIN_ROLE) {
        IGRAI.AssetConfig storage a = assets[asset];
        if (!a.exists) revert AssetUnknown();
        if (custodian == address(0)) revert CustodyZero();
        if (amount == 0) revert AmountZero();
        if (treasury.code.length > 0) {
            try ITreasury(treasury).isCustody(custodian) returns (bool ok) {
                if (!ok) revert UnknownCustodian();
            } catch { 
                if (custodian != treasury) revert UnknownCustodian();
            }
        } else {
            if (custodian != treasury) revert UnknownCustodian();
        }
        a.activeAmount += amount;
        allocatedAmount[custodian][asset] += amount;
        emit Allocate(asset, custodian, amount);

        juniorVault.withdraw(asset, custodian, amount);
    }

    function deallocate(address asset, uint256 amount) external payable {
        address custodian = msg.sender;
        IGRAI.AssetConfig storage a = assets[asset];
        if (!a.exists) revert AssetUnknown();
        if (amount == 0) revert AmountZero();
        if (allocatedAmount[custodian][asset] < amount) revert InsufficientAllocation();
        if (a.activeAmount < amount) revert InsufficientActive();

        allocatedAmount[custodian][asset] -= amount;
        a.activeAmount -= amount;
        emit Deallocate(asset, custodian, amount);

        if (asset == address(0)) {
            if (msg.value != amount) revert ValueMismatch();
            seniorVault.deposit{value: amount}(address(0), amount);
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(custodian, address(this), amount);
            seniorVault.deposit(asset, amount);
        }
    }

    function distribute(address asset, uint256 yieldAmount) external payable {
        IGRAI.AssetConfig storage a = assets[asset];
        if (!a.exists) revert AssetUnknown();
        if (yieldAmount == 0) revert AmountZero();

        uint256 seniorYield = (yieldAmount * a.yieldSplit) / BPS;
        uint256 treasuryYield = yieldAmount - seniorYield;
        uint256 yieldValue = seniorYield > 0 ? usdValue(asset, seniorYield) : 0;

        // Effects: update NAV before pulling yield into vaults or treasury.
        a.totalValue += yieldValue;
        totalValue += yieldValue;
        yieldGenerated[msg.sender][asset] += yieldAmount;
        emit Distribute(asset, msg.sender, yieldAmount, seniorYield, treasuryYield);

        if (asset == address(0)) {
            if (msg.value != yieldAmount) revert ValueMismatch();
            if (seniorYield > 0) seniorVault.deposit{value: seniorYield}(address(0), seniorYield);
            if (treasuryYield > 0) {
                (bool ok,) = treasury.call{value: treasuryYield}("");
                if (!ok) revert EthTransferFailed();
            }
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            if (seniorYield > 0) {
                IERC20(asset).safeTransferFrom(msg.sender, address(this), seniorYield);
                seniorVault.deposit(asset, seniorYield);
            }
            if (treasuryYield > 0) IERC20(asset).safeTransferFrom(msg.sender, treasury, treasuryYield);
        }
    }

    function getVaultsData() external view returns (IGRAI.VaultSnapshot[] memory snapshot) {
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

    function usdValue(address asset, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        (uint256 price, uint8 pdec) = getPrice(asset);
        uint8 adec = asset == address(0) ? 18 : IERC20Metadata(asset).decimals();
        return (amount * price * (10 ** USD_DECIMALS)) / (10 ** adec) / (10 ** pdec);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
