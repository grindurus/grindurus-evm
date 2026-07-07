// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGPv2Settlement {
    function setPreSignature(bytes calldata orderUid, bool signed) external;
}
