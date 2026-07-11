// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ERC-1046 tokenURI Interoperability
/// @notice https://eips.ethereum.org/EIPS/eip-1046
interface IERC1046 {
    /// @notice ERC-721-like metadata URI for the token contract.
    /// @dev Resolved JSON MUST follow ERC-1046's ERC-20 Token Metadata Schema.
    function tokenURI() external view returns (string memory);
}
