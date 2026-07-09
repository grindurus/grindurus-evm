// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGRAI} from "../../src/interfaces/IGRAI.sol";

/// @dev Minimal treasury stand-in for custodian tests: exposes IERC721.ownerOf and grai().
contract MockTreasuryNFT {
    IGRAI public grai;
    mapping(uint256 => address) private _owners;

    function setGrai(IGRAI grai_) external {
        grai = grai_;
    }

    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }
}
