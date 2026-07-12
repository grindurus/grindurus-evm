// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PriceOracleRouter} from "./PriceOracleRouter.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";
import {ISeniorToken} from "./interfaces/ISeniorToken.sol";
import {IJuniorToken} from "./interfaces/IJuniorToken.sol";
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

    uint8 public constant USD_DECIMALS = 6;
    uint16 public constant BPS = 100_00; // 100%
    uint16 public constant DEFAULT_MINT_SPLIT = 50_00; // 50%
    uint16 public constant DEFAULT_YIELD_SPLIT = 80_00; // 80%

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    address public pendingOwner;
    address public currentOwner;

    mapping(address asset => IGRAI.AssetConfig) public assets;
    address[] public assetList;

    uint256 public totalValue;

    ISeniorToken public seniorToken;
    IJuniorToken public juniorToken;

    string private _tokenUri;

    /// @dev Storage gap for future upgrades.
    uint256[41] private _gap;

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

        _tokenUri = "https://grindurus.xyz/metadata.json";
        currentOwner = admin;
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

    function setJuniorToken(address newJuniorToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(juniorToken) != address(0)) revert JuniorTokenAlreadySet();
        if (newJuniorToken == address(0)) revert JuniorTokenZero();
        IJuniorToken token = IJuniorToken(newJuniorToken);
        if (token.grai() != address(this)) revert NotJuniorTokenGrai();
        juniorToken = token;
        emit JuniorTokenUpdate(newJuniorToken);
    }

    function setSeniorToken(address newSeniorToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(seniorToken) != address(0)) revert SeniorTokenAlreadySet();
        if (newSeniorToken == address(0)) revert SeniorTokenZero();
        ISeniorToken token = ISeniorToken(newSeniorToken);
        if (token.grai() != address(this)) revert NotSeniorTokenGrai();
        seniorToken = token;
        emit SeniorTokenUpdate(newSeniorToken);
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

    function decimals() public pure override returns (uint8) {
        return USD_DECIMALS;
    }

    function setTokenURI(string calldata tokenUri_) external onlyRole(ADMIN_ROLE) {
        _tokenUri = tokenUri_;
        emit TokenURIUpdate(tokenUri_);
    }


    function addAsset(address asset, uint16 mintSplit, uint16 yieldSplit) external onlyRole(ADMIN_ROLE) {
        if (assets[asset].exists) revert AssetExists();
        if (mintSplit > BPS) revert BpsTooHigh();
        if (yieldSplit > BPS) revert BpsTooHigh();

        IGRAI.AssetConfig storage cfg = assets[asset];
        cfg.exists = true;
        cfg.mintSplit = mintSplit;
        cfg.yieldSplit = yieldSplit;
        cfg.pausedMinting = false;
        assetList.push(asset);

        emit AssetAdd(asset);
    }

    function removeAsset(address asset, uint256 hintId) external onlyRole(ADMIN_ROLE) {
        IGRAI.AssetConfig storage a = assets[asset];
        if (!a.exists) revert AssetUnknown();
        if (!a.pausedMinting) revert NotPaused();
        if (juniorToken.activeAmount(asset) > 0) revert ActiveJuniorCapital();

        uint256 sBal = seniorToken.balance(asset);
        if (sBal > 0) seniorToken.withdraw(asset, msg.sender, sBal);

        uint256 jBal = juniorToken.balance(asset);
        if (jBal > 0) juniorToken.withdraw(asset, msg.sender, jBal);

        uint256 assetValue = a.totalValue;
        uint256 seniorBook = a.seniorBook;
        uint256 juniorBook = a.juniorBook;

        totalValue -= assetValue;
        if (seniorBook > 0) seniorToken.reduceValue(seniorBook);
        if (juniorBook > 0) juniorToken.reduceValue(juniorBook);

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

    function mint(address asset, uint256 amount) external payable returns (uint256 depositValue) {
        IGRAI.AssetConfig storage a = assets[asset];
        if (!a.exists) revert AssetUnknown();
        if (a.pausedMinting) revert MintingPaused();
        if (amount == 0) revert AmountZero();

        uint256 seniorBalanceIn = (amount * a.mintSplit) / BPS;
        uint256 juniorBalanceIn = amount - seniorBalanceIn;

        depositValue = usdValue(asset, amount);
        if (depositValue == 0) revert ValueZero();
        uint256 seniorValue = (depositValue * a.mintSplit) / BPS;
        uint256 juniorValue = depositValue - seniorValue;

        // Effects: update protocol NAV and mint tranche tokens before pulling assets.
        a.totalValue += depositValue;
        a.seniorBook += seniorValue;
        a.juniorBook += juniorValue;
        totalValue += depositValue;
        if (seniorValue > 0) seniorToken.mint(msg.sender, seniorValue);
        if (juniorValue > 0) juniorToken.mint(msg.sender, juniorValue);
        emit Mint(msg.sender, asset, amount, depositValue, depositValue);

        // Interactions: collect assets and route to senior/junior vaults.
        if (asset == address(0)) {
            if (msg.value != amount) revert ValueMismatch();
            if (seniorBalanceIn > 0) {
                (bool ok,) = address(seniorToken).call{value: seniorBalanceIn}("");
                if (!ok) revert EthTransferFailed();
            }
            if (juniorBalanceIn > 0) {
                (bool ok,) = address(juniorToken).call{value: juniorBalanceIn}("");
                if (!ok) revert EthTransferFailed();
            }
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            if (seniorBalanceIn > 0) IERC20(asset).safeTransfer(address(seniorToken), seniorBalanceIn);
            if (juniorBalanceIn > 0) IERC20(asset).safeTransfer(address(juniorToken), juniorBalanceIn);
        }
    }

    function burn(uint256 stAmount) public override {
        if (stAmount == 0) revert AmountZero();

        IERC20 st = IERC20(address(seniorToken));
        if (stAmount > st.balanceOf(msg.sender)) revert AmountExceedsSupply();

        uint256 supply = st.totalSupply();
        if (supply == 0) revert NoSupply();

        uint256 totalValueBefore = totalValue;
        uint256 seniorTotalBefore = seniorToken.totalValue();
        uint256 burnValue = seniorToken.burn(msg.sender, stAmount);

        totalValue = totalValueBefore - burnValue;

        uint256 len = assetList.length;
        for (uint256 i; i < len; ++i) {
            IGRAI.AssetConfig storage a = assets[assetList[i]];
            if (seniorTotalBefore > 0 && a.seniorBook > 0) {
                uint256 seniorShare = (burnValue * a.seniorBook) / seniorTotalBefore;
                if (seniorShare == 0 && burnValue > 0) revert DustBurn();
                if (seniorShare > a.seniorBook) seniorShare = a.seniorBook;
                a.seniorBook -= seniorShare;
                a.totalValue -= seniorShare;
            }
        }

        emit Burn(msg.sender, stAmount, burnValue);

        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            uint256 seniorBalance = seniorToken.balance(asset);
            if (seniorBalance == 0) continue;
            uint256 redeem = (stAmount * seniorBalance) / supply;
            if (redeem == 0) continue;
            seniorToken.withdraw(asset, msg.sender, redeem);
        }
    }

    function distribute(address asset, uint256 yieldAmount) external payable {
        IGRAI.AssetConfig storage a = assets[asset];
        if (!a.exists) revert AssetUnknown();
        if (yieldAmount == 0) revert AmountZero();

        uint256 seniorYield = (yieldAmount * a.yieldSplit) / BPS;
        uint256 protocolProfit = yieldAmount - seniorYield;
        uint256 yieldValue = seniorYield > 0 ? usdValue(asset, seniorYield) : 0;

        // Effects: update NAV before pulling yield into vaults or paying protocol profit.
        a.totalValue += yieldValue;
        a.seniorBook += yieldValue;
        totalValue += yieldValue;
        if (yieldValue > 0) seniorToken.accrueValue(yieldValue);
        emit Distribute(asset, msg.sender, yieldAmount, seniorYield, protocolProfit);

        if (asset == address(0)) {
            if (msg.value != yieldAmount) revert ValueMismatch();
            if (seniorYield > 0) {
                (bool ok,) = address(seniorToken).call{value: seniorYield}("");
                if (!ok) revert EthTransferFailed();
            }
            if (protocolProfit > 0) {
                (bool ok,) = currentOwner.call{value: protocolProfit}("");
                if (!ok) revert EthTransferFailed();
            }
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            if (seniorYield > 0) IERC20(asset).safeTransferFrom(msg.sender, address(seniorToken), seniorYield);
            if (protocolProfit > 0) IERC20(asset).safeTransferFrom(msg.sender, currentOwner, protocolProfit);
        }
    }

    function getVaultsData() external view returns (IGRAI.VaultSnapshot[] memory snapshot) {
        uint256 len = assetList.length;
        snapshot = new IGRAI.VaultSnapshot[](len);
        for (uint256 i; i < len; ++i) {
            address asset = assetList[i];
            snapshot[i] = IGRAI.VaultSnapshot({
                asset: asset,
                seniorBalance: seniorToken.balance(asset),
                juniorBalance: juniorToken.balance(asset),
                activeAmount: juniorToken.activeAmount(asset)
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
