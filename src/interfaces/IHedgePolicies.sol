// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IGRAI} from "./IGRAI.sol";
import {IHedgePool} from "./IHedgePool.sol";

/// @title IHedgePolicies
/// @notice Tradable GRAI liquidation-insurance policies as ERC721. Coverage is minted only by the
///         `HedgePool`, and can be split, merged, or sold via an ascending (English) auction.
interface IHedgePolicies is IERC721Enumerable {
    /// @param coverage  Insured GRAI notional (GRAI/USD decimals).
    /// @param createdAt Policy start timestamp (preserved across split/merge as the earliest start).
    struct Policy {
        uint256 coverage;
        uint64 createdAt;
    }

    /// @param bidder Current highest bidder (address(0) if no active bid).
    /// @param amount Current highest bid, escrowed in `bidAsset`.
    struct Auction {
        address bidder;
        uint256 amount;
    }

    error ZeroAddress();
    error NotAdmin();
    error NotHedgePool();
    error NotOwner();
    error AmountZero();
    error TooFewParts();
    error CoverageMismatch(uint256 expected, uint256 provided);
    error BidZero();
    error BidTooLow(uint256 amount, uint256 highest);
    error NoBid();
    error CannotBidOwn();
    error BidBelowMin(uint256 amount, uint256 minAmount);
    error ValueMismatch();
    error UnexpectedValue();
    error EthTransferFailed();

    event Mint(address indexed to, uint256 indexed tokenId, uint256 coverage);
    event Split(uint256 indexed tokenId, uint256[] newTokenIds);
    event Merge(uint256[] tokenIds, uint256 indexed newTokenId, uint256 coverage);
    event BidPlaced(uint256 indexed tokenId, address indexed bidder, uint256 amount);
    event BidWithdrawn(uint256 indexed tokenId, address indexed bidder, uint256 amount);
    event BidAccepted(uint256 indexed tokenId, address indexed seller, address indexed bidder, uint256 amount);

    function hedgePool() external view returns (IHedgePool);
    function grai() external view returns (IGRAI);
    function bidAsset() external view returns (address);
    function policies(uint256 tokenId) external view returns (uint256 coverage, uint64 createdAt);
    function auction(uint256 tokenId) external view returns (address bidder, uint256 amount);
    /// @notice Append-only history of leading bidders for `tokenId` (for frontend display).
    function bidders(uint256 tokenId) external view returns (address[] memory);

    /// @notice Mint a new policy covering `coverage` GRAI to `to`. Callable only by `hedgePool`.
    function mint(address to, uint256 coverage) external returns (uint256 tokenId);

    /// @notice Split a policy into several new policies whose coverages sum to the original.
    function split(uint256 tokenId, uint256[] calldata coverages) external returns (uint256[] memory tokenIds);

    /// @notice Merge several owned policies into a single new policy with the summed coverage.
    function merge(uint256[] calldata tokenIds) external returns (uint256 tokenId);

    /// @notice Place an ascending bid on `tokenId`; must exceed the current highest. Refunds the
    ///         previous leader and escrows `amount` in `bidAsset`.
    function bid(uint256 tokenId, uint256 amount) external payable;

    /// @notice Withdraw the caller's leading bid on `tokenId` and refund the escrow.
    function cancelBid(uint256 tokenId) external;

    /// @notice As the owner of `tokenId`, settle the auction to the highest bidder (>= `minAmount`).
    function acceptBid(uint256 tokenId, uint256 minAmount) external;
}
