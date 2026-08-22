// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IGRS {
    error CapExceeded();
    error InvalidRecipient();
    error NotHome();
    error NotSpoke();
    error BucketExceeded();
    error ProprietorGated();
    error InvalidSchedule();
    error ZeroAmount();
    error NothingToRelease();
    error UnknownVesting();
    error InstantNotVest();
    error SaleClosed();
    error SaleExceeded();
    error InvalidPayment();
    error PaymentFailed();
    error UnknownSale();
    /// @dev Sellable / transferable inventory is below the requested amount (vesting lockbox reserved).
    error InsufficientInventory();
    /// @dev OFT compose is disabled — custom sale/grant payloads must not share compose framing.
    error ComposeDisabled();

    enum Bucket {
        TokenSales,
        PreSeed,
        RevenueShare,
        Airdrops,
        CoreTeam,
        Advisors,
        GrowthFund,
        LpMm,
        LongTermReserve,
        Audits,
        Legal,
        /// @dev Holder-created vest (`vest`); not a cap-table bucket.
        Holder
    }

    enum Gate {
        Instant,
        Linear,
        Proprietary
    }

    struct Peer {
        uint32 eid;
        bytes32 peer;
    }

    /// @dev lzReceive executor budget for a destination eid (`gas` / CU, `value` / native on dest).
    struct PeerLzReceiveBudget {
        uint128 gas;
        uint128 value;
    }

    struct Allocation {
        Bucket bucket;
        uint256 cap;
        uint256 spent;
        uint256 remaining;
        Gate gate;
        uint32 cliffMonths;
        uint32 linearMonths;
    }

    struct Vesting {
        uint256 id;
        Bucket bucket;
        address funder;
        address beneficiary;
        uint256 allocation;
        uint256 released;
        uint64 start;
        uint64 cliffEnd;
        uint64 end;
    }

    struct Sale {
        /// @dev `bytes32(0)` = native ETH / SOL. Else the payment mint as 32 bytes (EVM address left-padded).
        bytes32 asset;
        /// @dev Remaining `asset` units the seller still wants for remaining `grsAmount`. Zero closes the id.
        uint256 assetAmount;
        /// @dev Remaining GRS for sale at this id.
        uint256 grsAmount;
        /// @dev Quote payee. `bytes32(0)` → `owner()` (EVM) / `oft_store.admin` (Solana) at purchase.
        ///      EVM address left-padded; Solana pubkey as 32 bytes. EVM `buy` requires a clean EVM
        ///      address (high 12 bytes 0).
        bytes32 recipient;
    }

    event Granted(Bucket indexed bucket, bytes32 indexed to, uint256 amount, uint256 vestingId);
    event Vested(address indexed from, address indexed to, uint256 amount, uint256 vestingId);
    event Released(uint256 indexed vestingId, address indexed to, uint256 amount);
    event ProprietorSet(address indexed proprietor);
    event PeerLzReceiveBudgetSet(uint32 indexed eid, uint128 gas, uint128 value);
    event SaleSet(uint256 indexed id, bytes32 indexed asset, uint256 assetAmount, uint256 grsAmount, bytes32 indexed recipient);
    event SaleAccepted(uint256 indexed id, bytes32 indexed asset, uint256 assetAmount, uint256 grsAmount, bytes32 indexed recipient);
    event SalePublished(uint256 indexed id, uint32 dstEid, bytes32 guid);
    event Bought(uint256 indexed id, address indexed buyer, address indexed to, uint256 amount, uint256 cost);

    function home() external view returns (bool);

    function MAX_SUPPLY() external view returns (uint256);

    function proprietor() external view returns (address);

    /// @notice Page of sales (`offset` 0-based, id = offset+1). Reverts `UnknownSale` if
    ///         `offset` is past the book; `ZeroAmount` if `limit == 0`. Short page ⇒ end.
    function getSales(uint256 offset, uint256 limit) external view returns (Sale[] memory);

    function spent(Bucket bucket) external view returns (uint256);

    function capOf(Bucket bucket) external view returns (uint256);

    function gateOf(Bucket bucket) external view returns (Gate);

    function remaining(Bucket bucket) external view returns (uint256);

    /// @notice Unreleased vesting escrow still held by this contract (`Σ allocation − released`).
    function vestingLocked() external view returns (uint256);

    function getAllocations() external view returns (Allocation[] memory);

    function vested(uint256 id, uint256 timestamp) external view returns (uint256);

    function releasable(uint256 id) external view returns (uint256);

    /// @notice Page of vestings (`offset` 0-based, id = offset+1). Reverts `UnknownVesting` if
    ///         `offset` is past the book; `ZeroAmount` if `limit == 0`. Short page ⇒ end.
    function getVestings(uint256 offset, uint256 limit) external view returns (Vesting[] memory);

    function getPeers() external view returns (Peer[] memory);

    function setProprietor(address proprietor_) external;

    /// @notice Per-eid lzReceive gas/value for auto enforcedOptions on `setPeer`. `gas == 0` clears.
    function setPeerLzReceiveBudget(uint32 eid, uint128 gas, uint128 value) external;

    /// @notice Home: append a sale. Id is the next 1-based index. `dstEid == 0` is local only; else burns
    ///         `grsAmount` from TokenSales, LZ-publishes so the spoke mints that GRS into escrow, and
    ///         closes the home row so home `buy` cannot fill the same lot.
    function sale(bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient, uint32 dstEid)
        external
        payable
        returns (uint256 id);

    /// @notice Native LZ fee for `sale(..., dstEid)` (next id). `dstEid == 0` is 0.
    function quoteSale(bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient, uint32 dstEid)
        external
        view
        returns (uint256 nativeFee);

    /// @notice Asset units due for `grsAmount` GRS from that sale's remaining `assetAmount`.
    function previewBuy(uint256 id, uint256 grsAmount) external view returns (uint256 cost);

    /// @notice Buy `amount` from `TokenSales` via sale `id` (instant). Home or spoke. Asset
    ///         `bytes32(0)` is ETH (`msg.value` must equal the cost); otherwise ERC-20 `transferFrom`
    ///         from the address in the low 20 bytes of `asset`.
    function buy(uint256 id, uint256 amount, address to) external payable returns (uint256 cost);

    /// @notice Assign `amount` from `bucket`. Instant if `cliffSeconds` and `durationSeconds` are 0
    ///         (returns 0). Otherwise a non-revocable in-token vest. `dstEid == 0` pays locally
    ///         (`to` must be an EVM address, high 12 bytes 0). Else instant OFT to `to`, or LZ grant
    ///         message so the spoke opens a local vest (home returns 0). Cap-table `grant` is `owner`.
    function grant(
        Bucket bucket,
        bytes32 to,
        uint256 amount,
        uint64 start,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        uint32 dstEid
    ) external payable returns (uint256 vestingId);

    /// @notice Native LZ fee for `grant(..., dstEid)`. Instant quotes OFT; scheduled quotes `GRS.grant`.
    function quoteGrant(
        bytes32 to,
        uint256 amount,
        uint64 start,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        Bucket bucket,
        uint32 dstEid
    ) external view returns (uint256 nativeFee);

    /// @notice Lock `amount` of the caller's GRS into a non-revocable vest for `to`.
    ///         `cliffSeconds` or `durationSeconds` must be non-zero (use `transfer` for instant).
    ///         Cliff ≤ 365 days; linear duration ≤ 4 × 365 days.
    function vest(
        address to,
        uint256 amount,
        uint64 start,
        uint64 cliffSeconds,
        uint64 durationSeconds
    ) external returns (uint256 vestingId);

    function release(uint256 id) external;

    function quoteBridge(uint32 dstEid, bytes32 to, uint256 amountLD) external view returns (uint256 nativeFee);

    function bridge(uint32 dstEid, bytes32 to, uint256 amountLD) external payable;
}
