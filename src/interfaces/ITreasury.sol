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
    error InvalidAmount();
    error TokenNonexistent(uint256 tokenId);
    error InvalidRange(uint256 fromId, uint256 toId);

    /// @notice Claim-time payout to a referrer or `beneficiar`.
    event Distribute(address indexed asset, address indexed to, uint256 amount);

    event Mint(address indexed locker, address indexed referrer, uint256 indexed tokenId);
    event Rebind(address indexed locker, address indexed from, address indexed to, uint256 tokenId);
    event RoyaltyBpsUpdate(uint16 royaltyBps);
    event RevenueShareUpdate(uint16[] shares);

    /// @notice Deposit book value for a locker node.
    /// @param value Own credited deposit book value.
    /// @param l1Value Deposits for which this address is L1 (direct recruits).
    /// @param l2Value Deposits for which this address is L2.
    struct ReferralBook {
        uint256 value;
        uint256 l1Value;
        uint256 l2Value;
    }

    /// @notice One bound locker row for frontend pagination over ERC-721 enumerable order.
    struct LockerReferral {
        address locker;
        address referrer;
        ReferralBook book;
    }

    function grai() external view returns (IGRAI);

    /// @notice Protocol fee recipient for the non-affiliate slice of claim-time treasury income.
    function beneficiar() external view returns (address);

    /// @notice Secondary-sale royalty in bps (ERC-2981), paid to the locker (depositor).
    function royaltyBps() external view returns (uint16);

    /// @notice Per-level split of claim-time revenue share (bps; sum must equal 10_000).
    function revenueShareBps(uint256 index) external view returns (uint16);

    /// @notice Current revenue-share recipient for `locker` (`ownerOf` of their NFT, or `address(0)` if unbound).
    function referrerOf(address locker) external view returns (address);

    /// @notice Own / L1 / L2 deposit book value for `locker`.
    function referralBooks(address locker)
        external
        view
        returns (uint256 value, uint256 l1Value, uint256 l2Value);

    /// @notice Bound lockers in ERC-721 enumerable order for `[fromId, toId)` (`totalSupply` clipped).
    /// @dev `tokenByIndex` → `locker = address(uint160(tokenId))`, `referrer = ownerOf`, plus `referralBooks`.
    function getReferralBooks(uint256 fromId, uint256 toId) external view returns (LockerReferral[] memory list);

    /// @notice Poach quote for `locker`: `value + l1Value` ask and current NFT owner.
    /// @dev Reverts if unbound or `account` already owns the slot.
    function poachOf(address locker, address account) external view returns (uint256 price, address referrer);

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

    /// @notice GRAI-only: sticky-mint NFT to `referrer` on first call; every call credits deposit
    ///         `value` to `locker` and L1/L2 upline `l1Value` / `l2Value`.
    function mint(address locker, address referrer, uint256 value) external returns (uint256 tokenId);

    /// @notice GRAI-only: move locker NFT to `to` and shift L1/L2 book (after GRAI `poach` payment).
    function rebind(address locker, address to) external;

    /// @notice Pay claim-time treasury split from inventory.
    /// @dev No-op if balance < `grossProfitShare`. Soft-fail per recipient; unpaid shares roll into
    ///      `beneficiar` as `netProfitShare` (`grossProfitShare - paid`).
    function distribute(address asset, address locker, uint256 grossProfitShare, uint256 revenueShare)
        external;

    /// @notice Collection metadata (ERC-1046).
    function tokenURI() external pure returns (string memory);
}
