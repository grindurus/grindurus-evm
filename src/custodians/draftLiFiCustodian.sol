// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {Custodian} from "../Custodian.sol";

/// @dev LI.FI / OIF `MandateOutput` (`callbackData` ≡ docs field `call`).
///      https://docs.li.fi/lifi-intents/architecture/settlement
struct MandateOutput {
    bytes32 oracle;
    bytes32 settler;
    uint256 chainId;
    bytes32 token;
    uint256 amount;
    bytes32 recipient;
    bytes callbackData;
    bytes context;
}

/// @dev LI.FI / OIF `StandardOrder`.
struct StandardOrder {
    address user;
    uint256 nonce;
    uint256 originChainId;
    uint32 expires;
    uint32 fillDeadline;
    address inputOracle;
    uint256[2][] inputs;
    MandateOutput[] outputs;
}

interface IInputSettlerEscrow {
    /// @notice Lock inputs from `msg.sender` into escrow (maker path).
    function open(StandardOrder calldata order) external payable;

    /// @notice Lock inputs from `sponsor` via Permit2 / EIP-3009 signature (taker / gasless path).
    function openFor(StandardOrder calldata order, address sponsor, bytes calldata signature) external payable;

    function refund(StandardOrder calldata order) external;

    function orderIdentifier(StandardOrder memory order) external view returns (bytes32);
}

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title LiFiCustodian (implementation) UNVERIFIED
/// @notice Junior-capital custody for same-chain LI.FI Intents (escrow maker `open` + taker `openFor`).
///
/// ## Purpose
/// 1. **Swap / rebalance inventory** — constrained same-chain `StandardOrder` over base/quote.
/// 2. **Protect inventory** — exits still via Grinders `deallocate` / `distribute` / `liquidate`.
///
/// Two execution modes (same order constraints; pick one):
///
/// ## Maker — `open` (this contract pays gas / pulls ERC20)
/// Owner posts the intent on-chain without taking a standing quote first.
/// 1. Build `StandardOrder` with `user` / output `recipient` = this proxy (same-chain)
/// 2. Owner (or relayer with owner key) calls `LiFiCustodian.open(order)`
/// 3. Custodian approves settler (set in `setAssets`) and calls `INPUT_SETTLER.open(order)`
///    → inputs pulled from this contract → escrow locks → solvers fill from `Open` event
/// 4. If expired unfilled: `refund(order)` returns inputs here
///
/// ## Taker — `openFor` (solver pays gas; Permit2 + EIP-1271)
/// Owner takes a solver standing quote; solver opens escrow.
/// 1. Off-chain quote: `POST https://order.li.fi/quote/request` (`oif-escrow-v0`)
/// 2. Build `StandardOrder` with `user` / output `recipient` = this proxy (same-chain)
/// 3. Owner signs `permit2Digest(order)` (ECDSA); optional nested EIP-1271 binding
/// 4. Solver: `INPUT_SETTLER.openFor(order, custodian, bytes.concat(0x00, sig))`
///    → Permit2 pulls inputs → escrow locks → fill → settle
/// 5. If expired unfilled: `refund(order)` returns inputs here
///
/// ## EIP-1271 (taker / `openFor` only)
/// Permit2 verifies the sponsor (`address(this)`) via EIP-1271. `isValidSignature` accepts:
/// - raw 65-byte owner ECDSA over the Permit2 digest, or
/// - `abi.encode(bytes ecdsaSig, StandardOrder order)` (CoW-style) which also enforces custody
///   bounds and recomputes `permit2Digest(order) == hash`.
///
/// @dev Use the ERC1967Proxy only. Escrow / Permit2 addresses are CREATE2-stable on supported EVMs.
///      Docs: https://docs.li.fi/lifi-intents/introduction
contract LiFiCustodian is Custodian, IERC1271 {
    using SafeERC20 for IERC20;

    error NotTradingAsset();
    error BadUser();
    error BadInputToken();
    error BadOrder();

    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;

    /// @notice Uniswap Permit2 (canonical deployment).
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice LI.FI / OIF `InputSettlerEscrow`.
    IInputSettlerEscrow public constant INPUT_SETTLER_ESCROW =
        IInputSettlerEscrow(0x00fC00edbe7C003b006f870068c548940000223e);

    /// @notice LI.FI / OIF `OutputSettlerSimple`.
    address public constant OUTPUT_SETTLER = 0x75220B7600c300005038432a0000f308e0000068;

    /// @notice Polymer oracle (mainnet deployments).
    address public constant POLYMER_ORACLE = 0x008C3800F3Ad9b3B662d002E90Cc00000000eE17;

    /// @dev OIF `SIGNATURE_TYPE_PERMIT2` prefix for `openFor`.
    bytes1 public constant SIGNATURE_TYPE_PERMIT2 = 0x00;

    // forge-lint: disable-next-line(asm-keccak256)
    bytes32 private constant _TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");

    // forge-lint: disable-next-line(asm-keccak256)
    bytes32 private constant _MANDATE_OUTPUT_TYPEHASH = keccak256(
        "MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)"
    );

    // forge-lint: disable-next-line(asm-keccak256)
    bytes32 private constant _PERMIT2_WITNESS_TYPEHASH = keccak256(
        "Permit2Witness(address user,uint32 expires,address inputOracle,MandateOutput[] outputs)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)"
    );

    /// @dev OIF `Permit2WitnessType.PERMIT2_PERMIT2_TYPESTRING` (appended to Permit2 stub).
    string private constant _PERMIT2_WITNESS_TYPESTRING =
        "Permit2Witness witness)MandateOutput(bytes32 oracle,bytes32 settler,uint256 chainId,bytes32 token,uint256 amount,bytes32 recipient,bytes callbackData,bytes context)Permit2Witness(address user,uint32 expires,address inputOracle,MandateOutput[] outputs)TokenPermissions(address token,uint256 amount)";

    event OpenEscrow(bytes32 indexed orderId);
    event RefundEscrow(bytes32 indexed orderId);

    function initialize(address grinders_) public override initializer {
        __Custodian_init(grinders_);
    }

    /// @inheritdoc Custodian
    function custodianKind() public pure override returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256("grindurus.custodian.lifi");
    }

    /// @inheritdoc IERC1271
    /// @dev `hash` is the Permit2 EIP-712 digest for `PermitBatchWitnessTransferFrom` + OIF witness.
    function isValidSignature(bytes32 hash, bytes memory signature) public view returns (bytes4 magicValue) {
        bytes memory ecdsaSig;
        if (signature.length == 65) {
            ecdsaSig = signature;
        } else {
            // CoW-style: bind custody constraints into the EIP-1271 payload.
            if (signature.length < 224) return bytes4(0xffffffff);
            StandardOrder memory order;
            (ecdsaSig, order) = abi.decode(signature, (bytes, StandardOrder));
            if (ecdsaSig.length != 65) return bytes4(0xffffffff);
            if (!_isConstrainedCustodyOrder(order)) return bytes4(0xffffffff);
            if (permit2Digest(order) != hash) return bytes4(0xffffffff);
        }

        address signer = ECDSA.recover(hash, ecdsaSig);
        return signer == owner() ? _EIP1271_MAGIC : bytes4(0xffffffff);
    }

    /// @notice EIP-712 digest the owner must ECDSA-sign for Permit2 `openFor`.
    /// @dev `spender` in the digest is `INPUT_SETTLER_ESCROW` (`msg.sender` inside Permit2).
    function permit2Digest(StandardOrder memory order) public view returns (bytes32) {
        bytes32 witness = _permit2WitnessHash(order);

        uint256 n = order.inputs.length;
        bytes32[] memory tokenHashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            address token = _tokenFromId(order.inputs[i][0]);
            tokenHashes[i] = keccak256(abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, token, order.inputs[i][1]));
        }

        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,",
                _PERMIT2_WITNESS_TYPESTRING
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                keccak256(abi.encodePacked(tokenHashes)),
                address(INPUT_SETTLER_ESCROW),
                order.nonce,
                uint256(order.fillDeadline),
                witness
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", IPermit2Domain(PERMIT2).DOMAIN_SEPARATOR(), structHash));
    }

    /// @notice Prefix a Permit2 ECDSA (or nested EIP-1271) payload for `openFor`.
    function encodeOpenForSignature(bytes memory permit2Signature) public pure returns (bytes memory) {
        return bytes.concat(SIGNATURE_TYPE_PERMIT2, permit2Signature);
    }

    /// @notice Nested EIP-1271 payload: owner ECDSA + order (custody-checked).
    function encodeEip1271Signature(bytes memory ecdsaSig, StandardOrder calldata order)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(ecdsaSig, order);
    }

    /// @notice Maker path: lock a constrained order into escrow (`INPUT_SETTLER.open`).
    /// @dev Caller pays gas. Inputs are pulled from this contract (ERC20 approve to settler).
    ///      `order.user` must be `address(this)`. Does not use Permit2 / EIP-1271.
    function open(StandardOrder calldata order) external returns (bytes32 orderId) {
        _onlyOwner();
        if (!_isConstrainedCustodyOrder(order)) revert BadOrder();

        orderId = INPUT_SETTLER_ESCROW.orderIdentifier(order);
        INPUT_SETTLER_ESCROW.open(order);
        emit OpenEscrow(orderId);
    }

    /// @notice Refund an expired unfinalised order; inputs return to `order.user` (this contract).
    function refund(StandardOrder calldata order) external returns (bytes32 orderId) {
        if (order.user != address(this)) revert BadUser();
        orderId = INPUT_SETTLER_ESCROW.orderIdentifier(order);
        INPUT_SETTLER_ESCROW.refund(order);
        emit RefundEscrow(orderId);
    }

    function setAssets(address baseAsset_, address quoteAsset_) public override {
        super.setAssets(baseAsset_, quoteAsset_);
        _approveEscrowSpenders(baseAsset_, quoteAsset_);
    }

    /// @notice Owner can retarget ERC20 allowance for Permit2 and/or the input settler.
    function approve(address token, uint256 amount) public {
        _onlyOwner();
        if (token != baseAsset && token != quoteAsset) revert NotTradingAsset();
        IERC20(token).forceApprove(PERMIT2, amount);
        IERC20(token).forceApprove(address(INPUT_SETTLER_ESCROW), amount);
    }

    function _approveEscrowSpenders(address base_, address quote_) internal {
        IERC20(base_).forceApprove(PERMIT2, type(uint256).max);
        IERC20(quote_).forceApprove(PERMIT2, type(uint256).max);
        IERC20(base_).forceApprove(address(INPUT_SETTLER_ESCROW), type(uint256).max);
        IERC20(quote_).forceApprove(address(INPUT_SETTLER_ESCROW), type(uint256).max);
    }

    function _permit2WitnessHash(StandardOrder memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _PERMIT2_WITNESS_TYPEHASH,
                order.user,
                order.expires,
                order.inputOracle,
                _hashOutputs(order.outputs)
            )
        );
    }

    function _hashOutputs(MandateOutput[] memory outputs) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            MandateOutput memory o = outputs[i];
            hashes[i] = keccak256(
                abi.encode(
                    _MANDATE_OUTPUT_TYPEHASH,
                    o.oracle,
                    o.settler,
                    o.chainId,
                    o.token,
                    o.amount,
                    o.recipient,
                    keccak256(o.callbackData),
                    keccak256(o.context)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _isConstrainedCustodyOrder(StandardOrder memory order) internal view returns (bool) {
        if (order.user != address(this)) return false;
        if (order.originChainId != block.chainid) return false;
        if (order.fillDeadline == 0 || order.fillDeadline > order.expires) return false;

        uint256 inLen = order.inputs.length;
        if (inLen == 0) return false;
        uint256 outLen = order.outputs.length;
        if (outLen == 0) return false;

        address base = baseAsset;
        address quote = quoteAsset;
        bool soldBase;
        bool soldQuote;

        for (uint256 i; i < inLen; ++i) {
            address token = address(uint160(order.inputs[i][0]));
            if (order.inputs[i][0] >> 160 != 0) return false;
            if (token != base && token != quote) return false;
            if (token == base) soldBase = true;
            if (token == quote) soldQuote = true;
        }

        bytes32 selfId = bytes32(uint256(uint160(address(this))));
        bool boughtBase;
        bool boughtQuote;

        for (uint256 i; i < outLen; ++i) {
            MandateOutput memory o = order.outputs[i];
            if (o.chainId != block.chainid) return false;
            if (o.recipient != selfId) return false;
            if (uint256(o.token) >> 160 != 0) return false;
            address token = address(uint160(uint256(o.token)));
            if (token != base && token != quote) return false;
            if (token == base) boughtBase = true;
            if (token == quote) boughtQuote = true;
        }

        return (soldBase && boughtQuote) || (soldQuote && boughtBase);
    }

    function _tokenFromId(uint256 id) internal pure returns (address token) {
        if (id >> 160 != 0) revert BadInputToken();
        token = address(uint160(id));
        if (token == address(0)) revert BadInputToken();
    }
}
