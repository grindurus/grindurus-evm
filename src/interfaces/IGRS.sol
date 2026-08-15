// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IGRS {
    error CapExceeded();
    error InvalidRecipient();
    error NotHome();
    error BucketExceeded();
    error VoteGated();
    error InvalidSchedule();
    error ZeroAmount();
    error NothingToRelease();
    error UnknownVesting();
    error InstantNotVest();

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

    struct VestingRec {
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

    event Granted(Bucket indexed bucket, address indexed to, uint256 amount, uint256 vestingId);
    event Vested(address indexed from, address indexed to, uint256 amount, uint256 vestingId);
    event Released(uint256 indexed vestingId, address indexed to, uint256 amount);
    event ProprietorSet(address indexed proprietor);
    event VeGRSSet(address indexed veGRS);

    function home() external view returns (bool);

    function MAX_SUPPLY() external view returns (uint256);

    function proprietor() external view returns (address);

    function veGRS() external view returns (address);

    function spent(Bucket bucket) external view returns (uint256);

    function capOf(Bucket bucket) external view returns (uint256);

    function gateOf(Bucket bucket) external view returns (Gate);

    function remaining(Bucket bucket) external view returns (uint256);

    function getAllocations() external view returns (Allocation[] memory);

    function vestingCount() external view returns (uint256);

    function vested(uint256 id, uint256 timestamp) external view returns (uint256);

    function releasable(uint256 id) external view returns (uint256);

    function getVestings() external view returns (VestingRec[] memory);

    function getPeers() external view returns (Peer[] memory);

    function setProprietor(address proprietor_) external;

    function setVeGRS(address veGRS_) external;

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
