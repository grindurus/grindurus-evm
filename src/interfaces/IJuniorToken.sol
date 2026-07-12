// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IJuniorToken is IERC20 {
    error ZeroAddress();
    error OwnerZero();
    error AmountZero();
    error EthTransferFailed();
    error UnknownCustodianKind(bytes32 custodianKind);
    error CustodianKindMismatch(bytes32 expected, bytes32 actual);
    error CustodianZero();
    error UnknownCustodian();
    error NotAdmin();
    error NotGrai();
    error InsufficientReserve();
    error AssetUnknown();
    error ValueMismatch();
    error UnexpectedValue();
    error ValueExceedsNav();
    error CustodianNonexistent(uint256 custodianId);
    error CustodianOwnerZero();
    error NotCustodianOwner(address caller);
    error CustodianOwnerMismatch(address expected, address actual);

    event CustodianImplementationUpdated(bytes32 indexed custodianKind, address implementation);
    event CustodianDeployed(
        bytes32 indexed custodianKind,
        address indexed custodian,
        address indexed owner,
        address baseAsset,
        address quoteAsset
    );
    event CustodianOwnershipTransferred(
        address indexed custodian, address indexed from, address indexed to
    );
    event JuniorMint(address indexed to, uint256 jtOut, uint256 value);
    event JuniorBurn(address indexed from, uint256 jtAmount, uint256 value);
    event JuniorValueReduced(uint256 value);
    event Allocate(address indexed asset, address indexed custodian, uint256 amount);
    event Deallocate(address indexed asset, address indexed custodian, uint256 amount);

    function grai() external view returns (address);

    function totalValue() external view returns (uint256);

    function custodianCount() external view returns (uint256);

    function custodianImplementations(bytes32 custodianKind) external view returns (address);

    function custodians(uint256 custodianId) external view returns (address);

    function custodianIds(address custodian) external view returns (uint256);

    function custodianOwners(address custodian) external view returns (address);

    function ownerOf(uint256 custodianId) external view returns (address);

    function isCustodian(address custodian) external view returns (bool);

    function initialize(address grai_) external;

    function balance(address asset) external view returns (uint256);

    function tokenURI(uint256 custodianId) external view returns (string memory);

    function setCustodianImplementation(bytes32 custodianKind, address implementation) external;

    function mint(address to, uint256 value) external returns (uint256 jtOut);

    function burn(address from, uint256 jtAmount) external returns (uint256 valueOut);

    function reduceValue(uint256 value) external;

    function withdraw(address asset, address to, uint256 amount) external;

    function mintCustodian(bytes32 custodianKind, address owner_, IERC20 baseAsset_, IERC20 quoteAsset_)
        external
        returns (address custodian);

    function transferCustodianOwnership(address custodian, address newOwner) external;

    function allocate(address asset, address custodian, uint256 amount) external;

    function deallocate(address asset, uint256 amount) external payable;

    function allocatedAmount(address custodian, address asset) external view returns (uint256);

    function activeAmount(address asset) external view returns (uint256);

    function yieldGenerated(address custodian, address asset) external view returns (uint256);

    function recordYield(address custodian, address asset, uint256 yieldAmount) external;
}
