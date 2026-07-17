// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGRAI} from "./IGRAI.sol";

/// @title IJuniorPool
/// @notice High-risk pool that generates yield backing GRAI.
interface IJuniorPool {
    function grai() external view returns (IGRAI);
}
