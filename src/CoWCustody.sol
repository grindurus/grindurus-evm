// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IGRAI} from "./interfaces/IGRAI.sol";
import {IGPv2Settlement} from "./interfaces/IGPv2Settlement.sol";

/// @title Gnosis Protocol v2 Order Library (vendored from CoW Protocol)
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
        require(orderUid.length == UID_LENGTH, "GPv2: uid overflow");
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(add(orderUid, 56), validTo)
            mstore(add(orderUid, 52), owner)
            mstore(add(orderUid, 32), orderDigest)
        }
    }
}

/// @title CoWCustody (implementation)
/// @notice Junior-capital custody wallet for a GRAI grinder (owner).
///
/// ## Purpose
/// 1. **Swap on owner intent** — move base/quote via CoW Protocol only when the owner
///    signed the exact order off-chain. Settlement calls `isValidSignature`; unsigned or
///    tampered orders never execute. Swapped proceeds stay on this contract.
/// 2. **Protect principal from owner theft** — capital allocated from GRAI cannot be sent
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
contract CoWCustody is Initializable, OwnableUpgradeable, UUPSUpgradeable, IERC1271 {
    using SafeERC20 for IERC20;

    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;

    uint32 public constant DEFAULT_VALID_FOR = 2 minutes;
    uint48 public constant DISABLE_DELAY = 24 hours;

    IGPv2Settlement public constant COW_SETTLEMENT =
        IGPv2Settlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    IGRAI public GRAI;
    IERC20 public BASE_ASSET;
    IERC20 public QUOTE_ASSET;
    bytes32 public COW_DOMAIN_SEPARATOR;
    bool public upgradesDisabled;
    bool public emergencyWithdrawDisabled;
    uint48 public upgradesDisableScheduledAt;
    uint48 public emergencyWithdrawDisableScheduledAt;

    /// @dev Storage gap for future upgrades.
    uint256[40] private __gap;

    event EmergencyWithdraw(address indexed asset, address indexed to, uint256 amount);
    event GraiUpdated(address indexed grai);
    event AssetsUpdated(address indexed baseAsset, address indexed quoteAsset);
    event UpgradesReenableScheduled(uint48 reenableAt);
    event UpgradesDisabled();
    event UpgradesReenabled();
    event EmergencyWithdrawReenableScheduled(uint48 reenableAt);
    event EmergencyWithdrawDisabled();
    event EmergencyWithdrawReenabled();

    struct SwapParams {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, IGRAI grai_, IERC20 baseAsset_, IERC20 quoteAsset_) external initializer {
        require(owner_ != address(0), "owner=0");

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();

        GRAI = grai_;
        _setAssets(baseAsset_, quoteAsset_);
        COW_DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                block.chainid,
                address(COW_SETTLEMENT)
            )
        );
    }

    receive() external payable {}

    /// @inheritdoc IERC1271
    /// @dev `hash` is the CoW order digest. `signature` is the owner's 65-byte ECDSA signature over it.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue) {
        address signer = ECDSA.recover(hash, signature);
        return signer == owner() ? _EIP1271_MAGIC : bytes4(0xffffffff);
    }

    /// @notice CoW EIP-712 order digest for off-chain signing.
    function orderDigest(SwapParams calldata params) external view returns (bytes32) {
        uint32 validTo = _resolveValidTo(params.validTo);
        return GPv2Order.hash(_buildOrder(params, validTo), COW_DOMAIN_SEPARATOR);
    }

    /// @notice GPv2 order UID for the given swap parameters.
    function orderUid(SwapParams calldata params) external view returns (bytes memory uid) {
        uint32 validTo = _resolveValidTo(params.validTo);
        bytes32 digest = GPv2Order.hash(_buildOrder(params, validTo), COW_DOMAIN_SEPARATOR);
        uid = new bytes(GPv2Order.UID_LENGTH);
        GPv2Order.packOrderUidParams(uid, digest, address(this), validTo);
    }

    function approve(IERC20 token, uint256 amount) external onlyOwner {
        require(token == BASE_ASSET || token == QUOTE_ASSET, "not trading asset");
        token.forceApprove(COW_VAULT_RELAYER, amount);
    }

    function setGRAI(IGRAI grai_) external onlyOwner {
        require(address(grai_) != address(0), "grai=0");
        GRAI = grai_;
        emit GraiUpdated(address(grai_));
    }

    function setAssets(IERC20 baseAsset_, IERC20 quoteAsset_) external onlyOwner {
        _setAssets(baseAsset_, quoteAsset_);
        emit AssetsUpdated(address(baseAsset_), address(quoteAsset_));
    }

    function deallocate(address asset, uint256 amount) external onlyOwner {
        require(amount > 0, "amount=0");
        if (asset == address(0)) {
            GRAI.deallocate{value: amount}(asset, amount);
        } else {
            IERC20(asset).forceApprove(address(GRAI), amount);
            GRAI.deallocate(asset, amount);
        }
    }

    function distribute(address asset, uint256 yieldAmount) external onlyOwner {
        require(yieldAmount > 0, "amount=0");
        if (asset == address(0)) {
            GRAI.distribute{value: yieldAmount}(asset, yieldAmount);
        } else {
            IERC20(asset).forceApprove(address(GRAI), yieldAmount);
            GRAI.distribute(asset, yieldAmount);
        }
    }

    /// @notice Toggle UUPS upgrades. `true`: lock instantly (cancels pending unlock schedule). `false`: schedule unlock.
    function setUpgradesDisabled(bool disabled) external onlyOwner {
        if (disabled) {
            if (upgradesDisabled) {
                upgradesDisableScheduledAt = type(uint48).max;
                return;
            }
            upgradesDisabled = true;
            upgradesDisableScheduledAt = type(uint48).max;
            emit UpgradesDisabled();
        } else {
            require(upgradesDisabled, "enabled");
            require(upgradesDisableScheduledAt == type(uint48).max, "scheduled");
            upgradesDisabled = false;
            upgradesDisableScheduledAt = uint48(block.timestamp + DISABLE_DELAY);
            emit UpgradesReenableScheduled(upgradesDisableScheduledAt);
        }
    }

    /// @notice Toggle `emergencyWithdraw`. `true`: lock instantly (cancels pending unlock schedule). `false`: schedule unlock.
    function setEmergencyWithdrawDisabled(bool disabled) external onlyOwner {
        if (disabled) {
            if (emergencyWithdrawDisabled) {
                emergencyWithdrawDisableScheduledAt = type(uint48).max;
                return;
            }
            emergencyWithdrawDisabled = true;
            emergencyWithdrawDisableScheduledAt = type(uint48).max;
            emit EmergencyWithdrawDisabled();
        } else {
            require(emergencyWithdrawDisabled, "enabled");
            require(emergencyWithdrawDisableScheduledAt == type(uint48).max, "scheduled");
            emergencyWithdrawDisabled = false;
            emergencyWithdrawDisableScheduledAt = uint48(block.timestamp + DISABLE_DELAY);
            emit EmergencyWithdrawReenableScheduled(emergencyWithdrawDisableScheduledAt);
        }
    }

    /// @notice Rescue assets to owner without going through GRAI accounting.
    function emergencyWithdraw(address asset, uint256 amount) external onlyOwner {
        require(!emergencyWithdrawDisabled, "disabled");
        require(block.timestamp > emergencyWithdrawDisableScheduledAt, "delay");
        require(amount > 0, "amount=0");
        address to = owner();
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth transfer failed");
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
        emit EmergencyWithdraw(asset, to, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        newImplementation;
        require(!upgradesDisabled, "disabled");
        require(block.timestamp > upgradesDisableScheduledAt, "delay");
    }

    function _setAssets(IERC20 baseAsset_, IERC20 quoteAsset_) internal {
        require(address(baseAsset_) != address(0), "base=0");
        require(address(quoteAsset_) != address(0), "quote=0");
        require(address(baseAsset_) != address(quoteAsset_), "same asset");
        BASE_ASSET = baseAsset_;
        QUOTE_ASSET = quoteAsset_;
        BASE_ASSET.forceApprove(COW_VAULT_RELAYER, type(uint256).max);
        QUOTE_ASSET.forceApprove(COW_VAULT_RELAYER, type(uint256).max);
    }

    function _resolveValidTo(uint32 validTo) internal view returns (uint32 resolved) {
        resolved = validTo == 0 ? uint32(block.timestamp + DEFAULT_VALID_FOR) : validTo;
        require(resolved > block.timestamp, "expired");
    }

    function _buildOrder(SwapParams calldata params, uint32 validTo) internal pure returns (GPv2Order.Data memory order) {
        require(address(params.sellToken) != address(0), "sell=0");
        require(address(params.buyToken) != address(0), "buy=0");
        require(params.sellAmount > 0, "sellAmount=0");
        require(params.buyAmount > 0, "buyAmount=0");

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
