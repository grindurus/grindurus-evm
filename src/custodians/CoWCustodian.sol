// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IGPv2Settlement} from "../interfaces/IGPv2Settlement.sol";
import {Custodian} from "../Custodian.sol";

/// @title Gnosis Protocol v2 Order Library (vendored from CoW Protocol)
/// @dev https://github.com/cowprotocol/contracts/blob/main/src/contracts/libraries/GPv2Order.sol
library GPv2Order {
    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }

    /// @dev EIP-712 typehash for CoW `Order`:
    ///      `keccak256("Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,bytes32 kind,bool partiallyFillable,bytes32 sellTokenBalance,bytes32 buyTokenBalance)")`.
    ///      Prepended to the ABI-encoded struct fields inside `hash()` to form the EIP-712 struct hash.
    bytes32 internal constant TYPE_HASH =
        hex"d5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489"; // Order(...) per GPv2

    function hash(Data memory order, bytes32 domainSeparator) internal pure returns (bytes32 orderDigest) {
        bytes32 structHash;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let dataStart := sub(order, 32)
            let temp := mload(dataStart)
            mstore(dataStart, TYPE_HASH)
            structHash := keccak256(dataStart, 416)
            mstore(dataStart, temp)
        }
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(freeMemoryPointer, "\x19\x01")
            mstore(add(freeMemoryPointer, 2), domainSeparator)
            mstore(add(freeMemoryPointer, 34), structHash)
            orderDigest := keccak256(freeMemoryPointer, 66)
        }
    }
}

/// @title CoWCustodian (implementation)
/// @notice Junior-capital custody wallet for a GRAI grinder (owner).
///
/// ## Purpose
/// 1. **Swap inventory on owner intent** — move base/quote via CoW Protocol only when the owner
///    signed the exact order off-chain. Settlement calls `isValidSignature`; unsigned or
///    tampered orders never execute. Swapped proceeds stay on this contract.
/// 2. **Protect inventory from owner theft** — capital allocated from GRAI cannot be sent
///    to the owner's wallet arbitrarily. Normal exits go through `deallocate` (principal)
///    and `distribute` (yield), which route funds back into GRAI accounting. The owner
///    controls trading, not custody of principal.
///
/// ## Flow
/// - GRAI `allocate` → tokens on custody
/// - Owner signs CoW order digest, then API signature is `abi.encode(ecdsaSig, GPv2Order.Data)`
/// - POST to CoW API → settlement calls `isValidSignature` → `deallocate` / `distribute`
///
/// ## Trust model
/// - Owner (Treasury NFT holder) **can** swap only via CoW orders they signed as EIP-1271 maker.
///   `isValidSignature` requires owner ECDSA, recomputes the digest, and enforces custody bounds:
///   `receiver == address(this)`, sell/buy ∈ `{baseAsset, quoteAsset}`, and
///   `GPv2Order.hash(order) == hash`. Bare ECDSA or a digest for another receiver cannot pass.
/// - Other order fields (`kind`, `feeAmount`, `partiallyFillable`, `sellTokenBalance`, `buyTokenBalance`, …)
///   are not constrained on-chain; the owner signs the exact params they accept.
///   Custody security is receiver + asset bounds + digest binding.
/// - Owner **chooses** signed amounts and prices within those bounds (operational discretion); proceeds
///   always remain on this contract.
/// - Principal exits only through `deallocate`; yield through `distribute` — both route via GRAI accounting,
///   not to an arbitrary owner wallet.
/// - Owner **cannot** `rescue` while `isRescueDisabled` is true.
///   Funds route to treasury, not the NFT holder wallet.
///   `toggleRescue()` locks instantly; call again while locked to schedule a 24h unlock delay.
/// - Owner **cannot** `upgradeTo` while `isUpgradeableDisabled` is true or a re-enable delay is pending.
///   `toggleUpgradeable()` locks instantly; call again while locked to schedule a 24h unlock delay.
///
/// @dev Use the ERC1967Proxy address only, not the implementation.
///      VaultRelayer max-allowance for base/quote is set in `initialize` / `setAssets`.
contract CoWCustodian is Custodian, IERC1271 {
    using SafeERC20 for IERC20;

    error NotTradingAsset();

    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;

    IGPv2Settlement public constant COW_SETTLEMENT = IGPv2Settlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    bytes32 public immutable COW_DOMAIN_SEPARATOR = keccak256(
        abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Gnosis Protocol"),
            keccak256("v2"),
            block.chainid,
            address(COW_SETTLEMENT)
        )
    );

    function initialize(
        address treasury_,
        uint256 custodianId_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) public override initializer {
        __Custodian_init(treasury_, custodianId_, baseAsset_, quoteAsset_);
        _approveVaultRelayer(baseAsset_, quoteAsset_);
    }

    /// @inheritdoc Custodian
    function custodianKind() public pure override returns (bytes32) {
        return keccak256("grindurus.custodian.cow");
    }

    /// @inheritdoc IERC1271
    /// @dev `hash` is the CoW order digest. `signature` is `abi.encode(bytes ecdsaSig, GPv2Order.Data order)`:
    ///      65-byte owner ECDSA over `hash`, plus the full order used to recompute and constrain the digest.
    function isValidSignature(bytes32 hash, bytes memory signature) public view returns (bytes4 magicValue) {
        if (signature.length < 224) return bytes4(0xffffffff);
        (bytes memory ecdsaSig, GPv2Order.Data memory order) = decodeEip1271Signature(signature);
        if (ecdsaSig.length != 65) return bytes4(0xffffffff);
        if (!_isConstrainedCustodyOrder(hash, order)) return bytes4(0xffffffff);
        address signer = ECDSA.recover(hash, ecdsaSig);
        return signer == owner() ? _EIP1271_MAGIC : bytes4(0xffffffff);
    }

    function _isConstrainedCustodyOrder(bytes32 hash, GPv2Order.Data memory order) internal view returns (bool) {
        address sell = address(order.sellToken);
        address buy = address(order.buyToken);
        address base = address(baseAsset);
        address quote = address(quoteAsset);
        if (sell != base && sell != quote) return false;
        if (buy != base && buy != quote) return false;
        if (sell == buy) return false;
        if (order.receiver != address(this)) return false;

        return GPv2Order.hash(order, COW_DOMAIN_SEPARATOR) == hash;
    }

    /// @notice Parse the EIP-1271 `signature` bytes produced for custody orders.
    function decodeEip1271Signature(bytes memory signature)
        public
        pure
        returns (bytes memory ecdsaSig, GPv2Order.Data memory order)
    {
        (ecdsaSig, order) = abi.decode(signature, (bytes, GPv2Order.Data));
    }

    /// @notice Build the EIP-1271 `signature` bytes expected by CoW API for custody orders.
    function encodeEip1271Signature(bytes memory ecdsaSig, GPv2Order.Data calldata order)
        public
        pure
        returns (bytes memory signature)
    {
        signature = abi.encode(ecdsaSig, order);
    }

    function approve(IERC20 token, uint256 amount) public {
        _onlyOwner();
        if (token != baseAsset && token != quoteAsset) revert NotTradingAsset();
        token.forceApprove(COW_VAULT_RELAYER, amount);
    }

    function setAssets(IERC20 baseAsset_, IERC20 quoteAsset_) public override {
        super.setAssets(baseAsset_, quoteAsset_);
        _approveVaultRelayer(baseAsset_, quoteAsset_);
    }

    function _approveVaultRelayer(IERC20 base_, IERC20 quote_) internal {
        base_.forceApprove(COW_VAULT_RELAYER, type(uint256).max);
        quote_.forceApprove(COW_VAULT_RELAYER, type(uint256).max);
    }
}
