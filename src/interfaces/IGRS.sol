// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IGRS {
    error CapExceeded();
    error InvalidRecipient();
    error NotHome();
    error BucketExceeded();
    error ProprietorGated();
    error InvalidSchedule();
    error ZeroAmount();
    error NothingToRelease();
    error UnknownVesting();
    error InstantNotVest();
    error SaleClosed();
    error InvalidPayment();
    error PaymentFailed();
    error UnknownSale();

    enum Bucket {
        TokenSales,
        PreSeed,
        Seed,
        Series,
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
        Proprietary,
        VoteGated
    }

    struct Peer {
        uint32 eid;
        bytes32 peer;
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
        /// @dev `address(0)` = native ETH.
        address quote;
        /// @dev Quote units per 1 GRS (`1e18`). Zero closes this sale.
        uint256 price;
        /// @dev Proceeds; `address(0)` → `owner()` at purchase time.
        address recipient;
    }

    event Granted(Bucket indexed bucket, address indexed to, uint256 amount, uint256 vestingId);
    event Vested(address indexed from, address indexed to, uint256 amount, uint256 vestingId);
    event Released(uint256 indexed vestingId, address indexed to, uint256 amount);
    event ProprietorSet(address indexed proprietor);
    event VeGRSSet(address indexed veGRS);
    event SaleSet(uint256 indexed id, address indexed quote, uint256 price, address indexed recipient);
    event Bought(uint256 indexed id, address indexed buyer, address indexed to, uint256 amount, uint256 cost);

    function home() external view returns (bool);

    function MAX_SUPPLY() external view returns (uint256);

    function proprietor() external view returns (address);

    function veGRS() external view returns (address);

    function saleCount() external view returns (uint256);

    function getSales(uint256 offset, uint256 limit) external view returns (Sale[] memory);

    function spent(Bucket bucket) external view returns (uint256);

    function capOf(Bucket bucket) external view returns (uint256);

    function gateOf(Bucket bucket) external view returns (Gate);

    function remaining(Bucket bucket) external view returns (uint256);

    function getAllocations() external view returns (Allocation[] memory);

    function vestingCount() external view returns (uint256);

    function vested(uint256 id, uint256 timestamp) external view returns (uint256);

    function releasable(uint256 id) external view returns (uint256);

    function getVestings(uint256 offset, uint256 limit) external view returns (Vesting[] memory);

    function getPeers() external view returns (Peer[] memory);

    function setProprietor(address proprietor_) external;

    function setVeGRS(address veGRS_) external;

    /// @notice Create (`id == 0`) or update sale `id`. Returns the id used.
    function setSale(uint256 id, address quote, uint256 price, address recipient) external returns (uint256);

    function quoteSale(uint256 id, uint256 amount) external view returns (uint256 cost);

    /// @notice Buy `amount` from `TokenSales` via sale `id` (instant). Quote `address(0)` is ETH
    ///         (`msg.value` must equal the cost); otherwise ERC-20 `transferFrom`.
    function buy(uint256 id, uint256 amount, address to) external payable returns (uint256 cost);

    /// @notice Assign `amount` from `bucket`. Instant if `cliffSeconds` and `durationSeconds` are 0
    ///         (returns 0). Otherwise a non-revocable in-token vest (id ≥ 1). Vote-gated buckets
    ///         need `proprietor`.
    function grant(
        Bucket bucket,
        address to,
        uint256 amount,
        uint64 start,
        uint64 cliffSeconds,
        uint64 durationSeconds
    ) external returns (uint256 vestingId);

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
