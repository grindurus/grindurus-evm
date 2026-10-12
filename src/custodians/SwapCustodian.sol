// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Custodian} from "../Custodian.sol";
import {CoWCustodian} from "./CoWCustodian.sol";
import {PathCustodian} from "./PathCustodian.sol";

/// @title SwapCustodian (implementation)
/// @notice Junior-capital custody that combines CoW Protocol EIP-1271 orders and
///         PathCustodian router `swap` in one wallet.
///
/// ## Purpose
/// - **CoW path** — owner-signed GPv2 orders validated via `isValidSignature` (from `CoWCustodian`).
/// - **Router path** — owner-gated aggregator calldata via `swap(limitPrice, target, data)` (from `PathCustodian`).
/// - Capital still exits only through `deallocate` / `distribute`.
///
/// ## Label
/// `grinder.custodian.swap` at CAIP-2 `eip155:<chainid>` (`keccak256` → `label()`).
///
/// @dev Use the ERC1967Proxy address only, not the implementation.
contract SwapCustodian is CoWCustodian, PathCustodian {
    function initialize(address grinders_) public override(CoWCustodian, PathCustodian) initializer {
        __Custodian_init(grinders_);
    }

    /// @inheritdoc Custodian
    /// @dev Kind suffix `.swap` (not chained `.cow` / `.path`).
    function _labelName() internal pure override(CoWCustodian, PathCustodian) returns (string memory) {
        return string.concat(Custodian._labelName(), ".swap");
    }

    /// @inheritdoc Custodian
    /// @dev Keep CoW vault-relayer max allowance when assets change.
    function setAssets(address baseAsset_, address quoteAsset_) public override(Custodian, CoWCustodian) {
        CoWCustodian.setAssets(baseAsset_, quoteAsset_);
    }
}
