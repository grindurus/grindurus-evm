// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ITreasury is IERC721 {
    error ZeroAddress();
    error OwnerZero();
    error AmountZero();
    error ToZero();
    error EthTransferFailed();
    error UnknownCustodyKind(bytes32 custodyKind);
    error CustodyKindMismatch(bytes32 expected, bytes32 actual);

    event CustodyImplementationUpdated(bytes32 indexed custodyKind, address implementation);
    event CustodyDeployed(
        bytes32 indexed custodyKind,
        address indexed custody,
        address indexed owner,
        address baseAsset,
        address quoteAsset
    );
    event Withdraw(address indexed asset, address indexed to, uint256 amount);

    function grai() external view returns (address);

    function custodyImplementations(bytes32 custodyKind) external view returns (address);

    function custodians(uint256 custodianId) external view returns (address);

    function custodianIds(address custody) external view returns (uint256);

    function isCustody(address custody) external view returns (bool);

    function initialize(address owner_, address grai_) external;

    function balance(address asset) external view returns (uint256);

    function setCustodyImplementation(bytes32 custodyKind, address implementation) external;

    function mint(bytes32 custodyKind, address owner_, IERC20 baseAsset_, IERC20 quoteAsset_)
        external
        returns (address custody);

    function withdraw(address asset, address to, uint256 amount) external;
}
