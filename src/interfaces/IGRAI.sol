// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1046} from "./IERC1046.sol";
import {IPriceOracleRouter} from "./IPriceOracleRouter.sol";

import {SeniorVault} from "../SeniorVault.sol";
import {JuniorVault} from "../JuniorVault.sol";

interface IGRAI is IERC20, IERC1046 {
    struct AssetConfig {
        bool exists;
        uint16 mintSplit;
        uint16 yieldSplit;
        bool pausedMinting;
        uint256 totalValue;
        uint256 activeAmount;
    }

    struct VaultSnapshot {
        address asset;
        uint256 seniorBalance;
        uint256 juniorBalance;
        uint256 activeAmount;
    }

    event TokenURIUpdate(string tokenURI);
    event TreasuryUpdate(address indexed treasury);
    event AssetAdd(address indexed asset);
    event AssetRemove(address indexed asset);
    event MintingPauseUpdate(address indexed asset, bool paused);
    event MintSplitUpdate(address indexed asset, uint16 bps);
    event YieldSplitUpdate(address indexed asset, uint16 bps);
    event Mint(
        address indexed minter, address indexed asset, uint256 amountIn, uint256 graiOut, uint256 depositValue
    );
    event Burn(address indexed burner, uint256 graiAmount, uint256 burnValue);
    event Allocate(address indexed asset, address indexed custody, uint256 amount);
    event Deallocate(address indexed asset, address indexed custody, uint256 amount);
    event Distribute(
        address indexed asset, address indexed custody, uint256 yieldAmount, uint256 seniorYield, uint256 treasuryYield
    );
    event Sweep(address indexed asset, address indexed to, uint256 amount);

    function BPS() external view returns (uint16);
    function DEFAULT_MINT_SPLIT() external view returns (uint16);
    function DEFAULT_YIELD_SPLIT() external view returns (uint16);
    function ADMIN_ROLE() external view returns (bytes32);

    function oracle() external view returns (IPriceOracleRouter);
    function seniorVault() external view returns (SeniorVault);
    function juniorVault() external view returns (JuniorVault);
    function allocatedAmount(address custody, address asset) external view returns (uint256);
    function yieldReturned(address custody, address asset) external view returns (uint256);

    function assets(address asset)
        external
        view
        returns (
            bool exists,
            uint16 mintSplit,
            uint16 yieldSplit,
            bool pausedMinting,
            uint256 totalValue,
            uint256 activeAmount
        );

    function assetList(uint256 index) external view returns (address);
    function totalValue() external view returns (uint256);
    function treasury() external view returns (address);

    function setTokenURI(string calldata tokenURI) external;
    function setTreasury(address newTreasury) external;
    function addAsset(address asset, uint16 mintSplit, uint16 yieldSplit) external;
    function removeAsset(address asset, uint256 hintId) external;
    function setPaused(address asset, bool paused) external;
    function setMintSplit(address asset, uint16 bps) external;
    function setYieldSplit(address asset, uint16 bps) external;
    function sweep(address asset, address to) external;

    function mint(address asset, uint256 amount) external payable returns (uint256 graiOut);
    function burn(uint256 graiAmount) external;
    function allocate(address asset, address custody, uint256 amount) external;
    function deallocate(address asset, uint256 amount) external payable;
    function distribute(address asset, uint256 yieldAmount) external payable;

    function seniorNav() external view returns (uint256 total);
    function usdValue(address asset, uint256 amount) external view returns (uint256);
    function getAssets() external view returns (address[] memory);
    function getVaults() external view returns (VaultSnapshot[] memory);
    function assetCount() external view returns (uint256);
}
