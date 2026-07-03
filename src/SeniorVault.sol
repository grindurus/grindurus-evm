// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultBase} from "./VaultBase.sol";

/// Idle liquidity reserve, the only source of `burn` redemptions.
contract SeniorVault is VaultBase {}
