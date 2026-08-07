// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IGRAI} from "./IGRAI.sol";

/// @title Treasury — fee sink, sticky referrer NFTs, and claim-time revenue split
interface ITreasury {
    error ZeroAddress();
    error NotGrai();
    error NotGraiOwner();
    error AlreadyBound();
    error BpsTooHigh();
    error InvalidShares();
    error TokenNonexistent(uint256 tokenId);

    /// @notice Claim-time payout to a referrer or `beneficiar`.
    event Distribute(address indexed asset, address indexed to, uint256 amount);

    event Mint(address indexed locker, address indexed referrer, uint256 indexed tokenId);
    event RoyaltyBpsUpdate(uint16 royaltyBps);
    event RevenueShareUpdate(uint16[] shares);

    function grai() external view returns (IGRAI);

    /// @notice Protocol fee recipient for the non-affiliate slice of claim-time treasury income.
    function beneficiar() external view returns (address);

    /// @notice Secondary-sale royalty in bps (ERC-2981), paid to the locker (depositor).
    function royaltyBps() external view returns (uint16);

    /// @notice Per-level split of claim-time revenue share (bps; sum must equal 10_000).
    function revenueShareBps(uint256 index) external view returns (uint16);

    /// @notice Current revenue-share recipient for `locker` (`ownerOf` of their NFT, or `address(0)`).
    function referrerOf(address locker) external view returns (address);

    /// @notice Split claim-time revenue share across configured referrer levels.
    /// @dev Walks `referrerOf` up to `revenueShareBps.length`. Each present level gets its bps;
    ///      missing deeper levels / rounding dust stay with `beneficiar` via `distribute`.
    /// @return referrers Present upline addresses (L1, L2, …).
    /// @return shares Amounts for each referrer.
    function revenueShareInfo(address locker, uint256 revenueShare)
        external
        view
        returns (address[] memory referrers, uint256[] memory shares);

    function initialize(address grai_) external;

    function setBeneficiar(address beneficiar_) external;

    function setRoyaltyBps(uint16 royaltyBps_) external;

    /// @notice Set per-level revenue-share weights in bps; `sum(shares) == 10_000`.
    function setRevenueShareBps(uint16[] memory shares) external;

    /// @notice Only linked GRAI may mint: NFT → `referrer`, sticky bind for `locker`, royalty → locker.
    function mint(address locker, address referrer) external returns (uint256 tokenId);

    /// @notice Pay claim-time treasury split from inventory.
    /// @dev No-op if balance < `netProfitShare`. Soft-fail per recipient; unpaid shares roll into
    ///      `beneficiar` (`netProfitShare - paid`).
    function distribute(address asset, address locker, uint256 netProfitShare, uint256 revenueShare)
        external;

    /// @notice Collection metadata (ERC-1046).
    function tokenURI() external pure returns (string memory);
}
