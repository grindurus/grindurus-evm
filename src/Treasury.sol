// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Custodian} from "./Custodian.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/// @title Treasury (implementation)
/// @notice Protocol treasury that receives GRAI yield, mints custodian NFTs, and deploys custody wallets.
/// @dev Use the ERC1967Proxy address only, not the implementation.
contract Treasury is ITreasury, OwnableUpgradeable, ERC721EnumerableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IGRAI public grai;

    mapping(bytes32 => address) public custodyImplementations;

    mapping(uint256 => address) public custodians;

    uint256 public nextCustodianId;

    /// @dev Storage gap for future upgrades.
    uint256[46] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(IGRAI grai_, address owner_) external initializer {
        if (address(grai_) == address(0) || owner_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ERC721_init("Grindurus Custodians", "GRINDURUS-CUSTODIANS");
        __ERC721Enumerable_init();

        grai = grai_;
    }

    function balance(address asset) external view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function setCustodyImplementation(bytes32 custodyKind, address implementation) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        bytes32 implKind = Custodian(payable(implementation)).custodyKind();
        if (implKind != custodyKind) revert CustodyKindMismatch(custodyKind, implKind);
        custodyImplementations[custodyKind] = implementation;
        emit CustodyImplementationUpdated(custodyKind, implementation);
    }

    /// @notice Deploy a custodian proxy for `owner_`, mint its NFT (`tokenId = custodianId`), and register it.
    function mint(bytes32 custodyKind, address owner_, IERC20 baseAsset_, IERC20 quoteAsset_)
        external
        onlyOwner
        returns (address custody)
    {
        if (owner_ == address(0)) revert OwnerZero();

        address impl = custodyImplementations[custodyKind];
        if (impl == address(0)) revert UnknownCustodyKind(custodyKind);
        bytes32 implKind = Custodian(payable(impl)).custodyKind();
        if (implKind != custodyKind) revert CustodyKindMismatch(custodyKind, implKind);

        uint256 custodianId = nextCustodianId++;

        _mint(owner_, custodianId);

        custody = address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(
                    Custodian.initialize,
                    (address(this), custodianId, baseAsset_, quoteAsset_)
                )
            )
        );

        custodians[custodianId] = custody;

        emit CustodyDeployed(custodyKind, custody, owner_, address(baseAsset_), address(quoteAsset_));
    }

    /// @notice Withdraw ETH or ERC20 held by the treasury.
    function withdraw(address asset, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ToZero();
        if (amount == 0) revert AmountZero();

        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }

        emit Withdraw(asset, to, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
