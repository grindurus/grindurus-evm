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
    /// @notice Sticky referrer / poach target is a protocol sink (GRAI, Treasury, WETH).
    error InvalidReferrer();
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
    struct LockerBook {
        uint256 value;
        uint256 l1Value;
        uint256 l2Value;
        address referrer;
    }

    /// @notice One bound locker row for frontend pagination over ERC-721 enumerable order.
    /// @dev `book.referrer` = sticky upline; `ownerOf` = cashflow NFT holder.
    struct LockerData {
        address locker;
        address ownerOf;
        LockerBook book;
    }

    function grai() external view returns (IGRAI);

    /// @notice Protocol fee recipient for the non-affiliate slice of claim-time treasury income.
    /// @dev Returns the configured address, or `grai.owner()` when unset (`address(0)`).
    function beneficiar() external view returns (address);

    /// @notice Secondary-sale royalty in bps (ERC-2981), paid to `beneficiar()`.
    function royaltyBps() external view returns (uint16);

    /// @notice Per-level split of claim-time revenue share (bps; sum must equal 10_000).
    function revenueShareBps(uint256 index) external view returns (uint16);

    /// @notice Sticky upline locker for `locker` (`lockerBooks.referrer`, or `address(0)` if unset).
    function referrerOf(address locker) external view returns (address);

    /// @notice Own / L1 / L2 deposit book value and sticky `referrer` for `locker`.
    function lockerBooks(address locker)
        external
        view
        returns (uint256 value, uint256 l1Value, uint256 l2Value, address referrer);

    /// @notice Bound lockers in ERC-721 enumerable order for `[fromId, toId)` (`totalSupply` clipped).
    /// @dev `tokenByIndex` → `locker = address(uint160(tokenId))`, cashflow `ownerOf`, plus `lockerBooks`.
    function getReferralsData(uint256 fromId, uint256 toId) external view returns (LockerData[] memory list);

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

    /// @notice Retarget the protocol fee recipient.
    function setBeneficiar(address beneficiar_) external;

    /// @notice Set ERC-2981 royalty bps.
    function setRoyaltyBps(uint16 royaltyBps_) external;

    /// @notice Set L1/L2 revenue-share weights in bps; `shares.length == 2` and `sum == 10_000`.
    function setRevenueShareBps(uint16[] memory shares) external;

    /// @notice GRAI-only: sticky-bind `referrer`, mint cashflow NFT to `locker` on first call;
    ///         every call credits deposit book `value` to `locker` and L1/L2 upline books.
    /// @dev Volumes are sticky — not reversed on `GRAI.redeem`. Claim-time book credit is in `distribute`.
    function mint(address locker, address referrer, uint256 value) external returns (uint256 tokenId);

    /// @notice GRAI-only: rewrite sticky `referrer` to `newReferrer` and shift L1/L2 books (after GRAI `poach`).
    /// @dev Does not transfer the cashflow NFT.
    function rebind(address locker, address newReferrer) external;

    /// @notice Pay claim-time treasury split from inventory; credit poach books for `claimedValue`.
    /// @dev Credits `claimedValue` (book USD) into locker books first. No-op payouts if balance
    ///      < `grossProfitShare`. Soft-fail per recipient; unpaid shares roll into `beneficiar`.
    function distribute(
        address asset,
        address locker,
        uint256 grossProfitShare,
        uint256 revenueShare,
        uint256 claimedValue
    ) external;

    /// @notice Collection metadata (ERC-1046).
    function tokenURI() external pure returns (string memory);
}
