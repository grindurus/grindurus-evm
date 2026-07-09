// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Custodian} from "../Custodian.sol";

/// @title LiFiCustodian (implementation)
/// @notice Junior-capital custody wallet for GRAI grinders using LiFi routing.
/// @dev Use the ERC1967Proxy address only, not the implementation.
contract LiFiCustodian is Custodian {
    bytes32 private constant _CUSTODY_KIND =
        0xd4a33314c9dfc303d37784d8fca3a16a6b60da179d866acaab28e9cd8af2b856; // keccak256("grindurus.custodian.lifi")

    /// @inheritdoc Custodian
    function custodyKind() public pure override returns (bytes32) {
        return _CUSTODY_KIND;
    }

    /// TO BE IMPLEMENTED
}
