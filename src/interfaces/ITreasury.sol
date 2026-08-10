// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IGRAI} from "./IGRAI.sol";

/// @title Treasury — fee sink, sticky referrer tree + cashflow NFTs, claim-time revenue split
interface ITreasury {
    error ZeroAddress();
    error NotGrai();
    error NotGraiOwner();
    error AlreadyBound();
    error ReferralLoop();
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

    /// @notice Deposit book value and sticky upline for a locker node.
    /// @param value Own credited deposit book value.
    /// @param l1Value Deposits for which this address is L1 (direct recruits).
    /// @param l2Value Deposits for which this address is L2.
    /// @param referrer Sticky upline locker (`poach` / `rebind` only); independent of `ownerOf`.
    struct ReferralBook {
        uint256 value;
        uint256 l1Value;
        uint256 l2Value;
        address referrer;
    }

    /// @notice One bound locker row for frontend pagination over ERC-721 enumerable order.
    struct LockerReferral {
        address locker;
        address referrer;
        ReferralBook book;
    }

    function grai() external view returns (IGRAI);

    /// @notice Protocol fee recipient for the non-affiliate slice of claim-time treasury income.
    /// @dev Returns the configured address, or `grai.owner()` when unset (`address(0)`).
    function beneficiar() external view returns (address);

    /// @notice Secondary-sale royalty in bps (ERC-2981), paid to the locker (depositor).
    function royaltyBps() external view returns (uint16);

    /// @notice Per-level split of claim-time revenue share (bps; sum must equal 10_000).
    function revenueShareBps(uint256 index) external view returns (uint16);

    /// @notice Sticky upline locker for `locker` (`referralBooks.referrer`, or `address(0)` if unset).
    function referrerOf(address locker) external view returns (address);

    /// @notice Own / L1 / L2 deposit book value and sticky `referrer` for `locker`.
    function referralBooks(address locker)
        external
        view
        returns (uint256 value, uint256 l1Value, uint256 l2Value, address referrer);

    /// @notice Bound lockers in ERC-721 enumerable order for `[fromId, toId)` (`totalSupply` clipped).
    /// @dev `tokenByIndex` → `locker = address(uint160(tokenId))`, sticky `referrer`, plus `referralBooks`.
    function getReferralBooks(uint256 fromId, uint256 toId) external view returns (LockerReferral[] memory list);

    /// @notice Poach quote for `locker`: `value + l1Value` ask and current sticky referrer.
    /// @dev Reverts if unbound or `account` is already the referrer.
    function poachOf(address locker, address account) external view returns (uint256 price, address referrer);

    /// @notice Split claim-time revenue share across configured referrer levels.
    /// @dev Walks sticky `referrerOf` up to `revenueShareBps.length`. Payee at each level is
    ///      `ownerOf(uint160(uplineLocker))`. Missing deeper levels / rounding dust stay with
    ///      `beneficiar` via `distribute`.
    /// @return referrers Present payee addresses (L1, L2, … cashflow owners).
    /// @return shares Amounts for each payee.
    function revenueShareInfo(address locker, uint256 revenueShare)
        external
        view
        returns (address[] memory referrers, uint256[] memory shares);

    function initialize(address grai_) external;

    function setBeneficiar(address beneficiar_) external;

    function setRoyaltyBps(uint16 royaltyBps_) external;

    /// @notice Set per-level revenue-share weights in bps; `sum(shares) == 10_000`.
    function setRevenueShareBps(uint16[] memory shares) external;

    /// @notice GRAI-only: sticky-bind `referrer`, mint cashflow NFT to `locker` on first call;
    ///         every call credits deposit `value` to `locker` and L1/L2 upline books.
    function mint(address locker, address referrer, uint256 value) external returns (uint256 tokenId);

    /// @notice GRAI-only: rewrite sticky `referrer` to `to` and shift L1/L2 books (after GRAI `poach`).
    /// @dev Does not transfer the cashflow NFT.
    function rebind(address locker, address to) external;

    /// @notice Pay claim-time treasury split from inventory.
    /// @dev No-op if balance < `grossProfitShare`. Soft-fail per recipient; unpaid shares roll into
    ///      `beneficiar` as `netProfitShare` (`grossProfitShare - paid`).
    function distribute(address asset, address locker, uint256 grossProfitShare, uint256 revenueShare)
        external;

    /// @notice Collection metadata (ERC-1046).
    function tokenURI() external pure returns (string memory);
}
