// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Minimal treasury stand-in for custodian tests: ownerOf, grai, custodianIds/custodians.
contract MockTreasuryNFT {
    address public grai;
    mapping(uint256 => address) public custodians;
    mapping(address => uint256) public custodianIds;
    mapping(uint256 => address) private _owners;

    function setGrai(address grai_) external {
        grai = grai_;
    }

    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function setCustodian(address custody, uint256 custodianId) external {
        custodians[custodianId] = custody;
        custodianIds[custody] = custodianId;
    }

    function isCustody(address custody) external view returns (bool) {
        return custodians[custodianIds[custody]] == custody;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    receive() external payable {}
}
