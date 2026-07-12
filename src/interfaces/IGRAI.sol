// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1046} from "./IERC1046.sol";
import {IPriceOracleRouter} from "./IPriceOracleRouter.sol";

import {ISeniorToken} from "./ISeniorToken.sol";
import {IJuniorToken} from "./IJuniorToken.sol";

interface IGRAI is IERC20, IERC1046, IPriceOracleRouter {
    error ZeroAddress();
    error JuniorTokenZero();
    error SeniorTokenZero();
    error NotSeniorTokenGrai();
    error NotJuniorTokenGrai();
    error JuniorTokenAlreadySet();
    error SeniorTokenAlreadySet();
    error AssetExists();
    error AssetUnknown();
    error BpsTooHigh();
    error NotPaused();
    error BadHint();
    error HintMismatch();
    error ToZero();
    error AmountZero();
    error EthTransferFailed();
    error MintingPaused();
    error ValueZero();
    error DustBurn();
    error ValueMismatch();
    error UnexpectedValue();
    error NoSupply();
    error AmountExceedsSupply();
    error OwnershipOfferPending();
    error NotCurrentOwner();
    error ActiveJuniorCapital();

    struct AssetConfig {
        bool exists;
        uint16 mintSplit;
        uint16 yieldSplit;
        bool pausedMinting;
        uint256 totalValue;
        uint256 seniorBook;
        uint256 juniorBook;
    }

    struct VaultSnapshot {
        address asset;
        uint256 seniorBalance;
        uint256 juniorBalance;
        uint256 activeAmount;
    }

    event TokenURIUpdate(string tokenURI);
    event JuniorTokenUpdate(address indexed juniorToken);
    event SeniorTokenUpdate(address indexed seniorToken);
    event AssetAdd(address indexed asset);
    event AssetRemove(address indexed asset);
    event MintingPauseUpdate(address indexed asset, bool paused);
    event MintSplitUpdate(address indexed asset, uint16 bps);
    event YieldSplitUpdate(address indexed asset, uint16 bps);
    event Mint(
        address indexed minter, address indexed asset, uint256 amountIn, uint256 graiOut, uint256 depositValue
    );
    event Burn(address indexed burner, uint256 stAmount, uint256 burnValue);
    event Distribute(
        address indexed asset, address indexed custody, uint256 yieldAmount, uint256 seniorYield, uint256 protocolProfit
    );
    event Sweep(address indexed asset, address indexed to, uint256 amount);
    event OwnershipOffered(address indexed account);
    event OwnershipAccepted(address indexed account);

    function BPS() external view returns (uint16);
    function DEFAULT_MINT_SPLIT() external view returns (uint16);
    function DEFAULT_YIELD_SPLIT() external view returns (uint16);
    function ADMIN_ROLE() external view returns (bytes32);
    function ORACLE_ROLE() external view returns (bytes32);

    function seniorToken() external view returns (ISeniorToken);
    function juniorToken() external view returns (IJuniorToken);

    function assets(address asset)
        external
        view
        returns (
            bool exists,
            uint16 mintSplit,
            uint16 yieldSplit,
            bool pausedMinting,
            uint256 totalValue,
            uint256 seniorBook,
            uint256 juniorBook
        );

    function assetList(uint256 index) external view returns (address);
    function totalValue() external view returns (uint256);

    function setTokenURI(string calldata tokenUri) external;
    function setJuniorToken(address newJuniorToken) external;
    function setSeniorToken(address newSeniorToken) external;
    function addAsset(address asset, uint16 mintSplit, uint16 yieldSplit) external;
    function removeAsset(address asset, uint256 hintId) external;
    function setPaused(address asset, bool paused) external;
    function setMintSplit(address asset, uint16 bps) external;
    function setYieldSplit(address asset, uint16 bps) external;
    function sweep(address asset, address to) external;

    function mint(address asset, uint256 amount) external payable returns (uint256 depositValue);
    function burn(uint256 stAmount) external;
    function distribute(address asset, uint256 yieldAmount) external payable;

    function usdValue(address asset, uint256 amount) external view returns (uint256);
    function getVaultsData() external view returns (VaultSnapshot[] memory);
}
