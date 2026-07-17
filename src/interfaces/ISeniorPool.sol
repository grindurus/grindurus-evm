// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGRAI} from "./IGRAI.sol";

/// @title ISeniorPool
/// @notice Low-risk pool providing liquidation insurance backing for GRAI.
interface ISeniorPool {
    function grai() external view returns (IGRAI);

    function hedgeAsset() external view returns (address);
}
