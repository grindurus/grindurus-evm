// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IGPv2Settlement} from "../interfaces/IGPv2Settlement.sol";
import {Custodian} from "../Custodian.sol";

/// @title Gnosis Protocol v2 Order Library (vendored from CoW Protocol)
library GPv2Order {
    error UidOverflow();

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

    bytes32 internal constant TYPE_HASH =
        hex"d5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489";

    bytes32 internal constant KIND_SELL =
        hex"f3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775";

    bytes32 internal constant BALANCE_ERC20 =
        hex"5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9";

    address internal constant RECEIVER_SAME_AS_OWNER = address(0);

    uint256 internal constant UID_LENGTH = 56;

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

    function packOrderUidParams(bytes memory orderUid, bytes32 orderDigest, address owner, uint32 validTo)
        internal
        pure
    {
        if (orderUid.length != UID_LENGTH) revert UidOverflow();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(add(orderUid, 56), validTo)
            mstore(add(orderUid, 52), owner)
            mstore(add(orderUid, 32), orderDigest)
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
/// - Owner signs CoW order digest (EIP-1271) → POST to CoW API → solver settles
/// - `deallocate` / `distribute` → funds return to GRAI
///
/// ## Trust model
/// - Owner **can** sign any swap within signed order params (operational discretion).
/// - Owner **cannot** pull allocated funds to self while `emergencyWithdrawDisabled` is true.
///   `setEmergencyWithdrawDisabled(true)` locks instantly; `false` clears the flag and starts a 24h
///   delay before `emergencyWithdraw` is allowed again.
/// - Owner **can** upgrade while `upgradesDisabled` is false and no unlock delay is active.
///   `setUpgradesDisabled(true)` locks instantly; `false` clears the flag and starts a 24h delay
///   before `upgradeTo` is allowed again.
///
/// @dev Use the ERC1967Proxy address only, not the implementation.
///      VaultRelayer max-allowance for base/quote is set in `initialize` / `setAssets`.
contract CoWCustodian is Custodian, IERC1271 {
    using SafeERC20 for IERC20;

    error NotTradingAsset();
    error Expired();
    error SellZero();
    error BuyZero();
    error SellAmountZero();
    error BuyAmountZero();

    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;

    uint32 public constant DEFAULT_VALID_FOR = 2 minutes;

    IGPv2Settlement public constant COW_SETTLEMENT = IGPv2Settlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    bytes32 public cowDomainSeparator;

    struct SwapParams {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
    }

    function initialize(
        address treasury_,
        uint256 custodianId_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) public override initializer {
        __Custodian_init(treasury_, custodianId_, baseAsset_, quoteAsset_);
        cowDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                block.chainid,
                address(COW_SETTLEMENT)
            )
        );
    }

    bytes32 private constant _CUSTODY_KIND =
        0x1602c448053eaaee4bf933fb139377e430f7dc803b82baa89439240b33173fec; // keccak256("grindurus.custodian.cow")

    /// @inheritdoc Custodian
    function custodyKind() public pure override returns (bytes32) {
        return _CUSTODY_KIND;
    }

    /// @inheritdoc IERC1271
    /// @dev `hash` is the CoW order digest. `signature` is the owner's 65-byte ECDSA signature over it.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue) {
        address signer = ECDSA.recover(hash, signature);
        return signer == owner() ? _EIP1271_MAGIC : bytes4(0xffffffff);
    }

    /// @notice CoW EIP-712 order digest for off-chain signing.
    function orderDigest(SwapParams calldata params) external view returns (bytes32) {
        uint32 validTo = _resolveValidTo(params.validTo);
        return GPv2Order.hash(_buildOrder(params, validTo), cowDomainSeparator);
    }

    /// @notice GPv2 order UID for the given swap parameters.
    function orderUid(SwapParams calldata params) external view returns (bytes memory uid) {
        uint32 validTo = _resolveValidTo(params.validTo);
        bytes32 digest = GPv2Order.hash(_buildOrder(params, validTo), cowDomainSeparator);
        uid = new bytes(GPv2Order.UID_LENGTH);
        GPv2Order.packOrderUidParams(uid, digest, address(this), validTo);
    }

    function approve(IERC20 token, uint256 amount) external {
        _onlyOwner();
        if (token != baseAsset && token != quoteAsset) revert NotTradingAsset();
        token.forceApprove(COW_VAULT_RELAYER, amount);
    }

    function _onTradingAssetsSet() internal override {
        baseAsset.forceApprove(COW_VAULT_RELAYER, type(uint256).max);
        quoteAsset.forceApprove(COW_VAULT_RELAYER, type(uint256).max);
    }

    function _resolveValidTo(uint32 validTo) internal view returns (uint32 resolved) {
        resolved = validTo == 0 ? uint32(block.timestamp + DEFAULT_VALID_FOR) : validTo;
        if (resolved <= block.timestamp) revert Expired();
    }

    function _buildOrder(SwapParams calldata params, uint32 validTo) internal pure returns (GPv2Order.Data memory order) {
        if (address(params.sellToken) == address(0)) revert SellZero();
        if (address(params.buyToken) == address(0)) revert BuyZero();
        if (params.sellAmount == 0) revert SellAmountZero();
        if (params.buyAmount == 0) revert BuyAmountZero();

        order = GPv2Order.Data({
            sellToken: params.sellToken,
            buyToken: params.buyToken,
            receiver: GPv2Order.RECEIVER_SAME_AS_OWNER,
            sellAmount: params.sellAmount,
            buyAmount: params.buyAmount,
            validTo: validTo,
            appData: params.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
}
