// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IGRAI} from "./IGRAI.sol";

interface ITreasury {
    error ZeroAddress();
    error NotGrai();
    error NotGraiOwner();
    error EthTransferFailed();

    /// @notice Claim-time treasury split: affiliate `revenueShare` (+ unused → `beneficiar`) and protocol `beneficiarShare`.
    event Distribute(
        address indexed asset,
        address indexed referrer,
        address indexed beneficiar,
        uint256 revenueShare,
        uint256 beneficiarShare
    );

    function grai() external view returns (IGRAI);

    function beneficiar() external view returns (address);

    function initialize(address grai_) external;

    /// @notice Pay claim-time treasury split from inventory.
    /// @dev `revenueShare` → `referrer` if set, else folded into `beneficiarShare`.
    ///      `beneficiarShare` → `beneficiar`. Caps to balance (referrer first). No-op if recipients/amounts are zero.
    function distribute(address asset, address referrer, uint256 revenueShare, uint256 beneficiarShare)
        external;
}
