// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IERC1046} from "./IERC1046.sol";

import {IGRAI} from "./IGRAI.sol";

interface IGrinders is IERC721Enumerable, IERC1046 {
    error ZeroAddress();
    error OwnerZero();
    error GraiTokenZero();
    error AssetUnknown();
    error ToZero();
    error AmountZero();
    error EthTransferFailed();
    error MintingPaused();
    error ValueZero();
    error ValueMismatch();
    error UnexpectedValue();
    error ActiveJuniorCapital();
    error UnknownCustodianKind(bytes32 custodianKind);
    error CustodianKindMismatch(bytes32 expected, bytes32 actual);
    error CustodianZero();
    error UnknownCustodian();
    error InsufficientReserve();
    error CustodianNonexistent(uint256 custodianId);
    error CustodianAlreadyRegistered(uint256 custodianId);

    event GraiTokenUpdate(address indexed graiToken);
    event Sweep(address indexed asset, address indexed to, uint256 amount);
    event CustodianImplementationUpdated(bytes32 indexed custodianKind, address implementation);
    event CustodianDeployed(
        bytes32 indexed custodianKind,
        address indexed custodian,
        address indexed owner,
        address baseAsset,
        address quoteAsset
    );
    event CustodianRegistered(address indexed custodian, address indexed owner, uint256 indexed custodianId);
    event Allocate(address indexed asset, address indexed custodian, uint256 amount);
    event Deallocate(address indexed asset, address indexed custodian, uint256 amount);

    function BPS() external view returns (uint16);
    function DEFAULT_YIELD_SPLIT() external view returns (uint16);

    function grai() external view returns (IGRAI);
    function balance(address asset) external view returns (uint256);

    function custodianImplementations(bytes32 custodianKind) external view returns (address);
    function custodians(uint256 custodianId) external view returns (address);
    function custodianIds(address custodian) external view returns (uint256);
    function allocated(address custodian, address asset) external view returns (uint256);
    function active(address asset) external view returns (uint256);
    function yieldBy(address custodian, address asset) external view returns (uint256);

    function isCustodian(address custodian) external view returns (bool);

    function custodianKindOf(address custodian) external view returns (bytes32);

    function sweep(address asset) external;

    function setCustodianImplementation(bytes32 custodianKind, address implementation) external;
    function mint(bytes32 custodianKind, address owner_, IERC20 baseAsset_, IERC20 quoteAsset_)
        external
        returns (address custodian);
    function register(address custodian, uint256 custodianId, address owner_) external;
    function allocate(address custodian, address asset, uint256 amount) external;
    function deallocate(address asset, uint256 amount) external payable;
}
