// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OFTMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import {IOAppMsgInspector} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppMsgInspector.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee, MessagingReceipt, Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC1046} from "./interfaces/IERC1046.sol";
import {IGRS} from "./interfaces/IGRS.sol";

/// @title GRS (Grindurus Token)
/// @author Vakhtanh Chikhladze (github: @Pozzitron1337)
/// @notice Fixed-supply LayerZero OFT. Home chain mints the 1B genesis into per-bucket inventory
///         (`docs.grindurus.xyz` mechanics / `grs.svg`); delegate `grant`s vesting / instant payouts. Any holder may `vest`
///         their own GRS (home or spoke). Spokes mint/burn via OFT. Admin is Ownable2Step.
contract GRS is OFT, Ownable2Step, IERC1046, IGRS {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    uint256 internal constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint64 internal constant MAX_CLIFF = 365 days;
    uint64 internal constant MAX_DURATION = 4 * 365 days;
    uint8 internal constant BUCKET_COUNT = 11;
    /// @dev Packed LZ payload: keccak256("GRS.sale") || id || asset || assetAmount || grsAmountSD || recipient
    ///      (192 bytes). `grsAmount` on the wire is OFT shared decimals (6).
    bytes32 internal constant SALE_MSG = keccak256("GRS.sale");
    uint256 internal constant SALE_MSG_LEN = 192;
    /// @dev Packed LZ payload: keccak256("GRS.grant") || to || amountSD || start || cliff || duration || bucket
    ///      (224 bytes). Spoke credits inventory and opens a local vest; instant grants use OFT instead.
    bytes32 internal constant GRANT_MSG = keccak256("GRS.grant");
    uint256 internal constant GRANT_MSG_LEN = 224;

    /// @dev Fallback lzReceive gas when `peerLzReceiveBudget[eid].gas == 0` (typical EVM peer).
    uint128 internal constant DEFAULT_LZ_RECEIVE_GAS = 200_000;
    /// @dev Native lamports the Executor may spend on Solana `lz_receive` (ATA / escrow rent).
    ///      GRS always `init_if_needed`s `sale_escrow` plus the recipient ATA — one token-account
    ///      rent (2_039_280) is not enough; Executor then reverts `PostExecute` / `InsufficientBalance`
    ///      and the whole atomic tx rolls back. Budget covers ~3 token accounts + headroom.
    uint128 internal constant DEFAULT_SOLANA_LZ_RECEIVE_VALUE = 10_000_000;

    /// @notice LayerZero eid of the home chain. `0` on home; on spoke set in the constructor with
    ///         `homeAddress` (`setPeer(homeEid, homeAddress)`).
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint32 public immutable homeEid;

    /// @notice Canonical home GRS as `bytes32` (`address` left-padded, or Solana pubkey as-is).
    ///         On home = this contract (`address(this)` left-padded). On spoke = the home peer
    ///         wired in the constructor via `homeEid`. Role gate uses `homeEid == 0` (home).
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    bytes32 public immutable homeAddress;

    /// @notice Unreleased vesting GRS locked in this contract (not TokenSales float).
    uint256 public vestingLocked;

    /// @notice GRS earmarked by open sale lots (local home listings + spoke escrow). Not free float.
    uint256 public salesReserved;

    /// @notice Tracks the amount spent from each allocation bucket.
    mapping(Bucket bucket => uint256) public spent;

    /// @notice Per-destination lzReceive budget used by `setPeer` defaults. `gas == 0` → fall back
    ///         to `DEFAULT_LZ_RECEIVE_GAS` / `value = 0`. Non-EVM chains (Solana, Aptos, …) set `value`.
    mapping(uint32 eid => PeerLzReceiveBudget) public peerLzReceiveBudget;

    /// @notice 1-based sale book. Sparse on spokes (no pad loop for high ids).
    mapping(uint256 id => Sale) internal _sales;
    /// @notice Highest sale id written (home append or spoke accept). Pagination length for `getSales`.
    uint256 internal _saleCount;
    /// @notice Spoke: id has accepted at least one LZ sale message (distinguishes close from never-opened).
    mapping(uint256 id => bool) internal _saleReceived;

    /// @notice List of all vesting schedules. Each vesting contains information about locked GRS allocations.
    Vesting[] internal _vestings;

    uint32[] internal peerEids;
    mapping(uint32 eid => uint256 indexPlusOne) internal peerEidIndex;

    /// @param lzEndpoint   Local LayerZero V2 endpoint.
    /// @param delegate     OFT owner / endpoint delegate. On home, does **not** receive the 1B —
    ///                     inventory stays here until `grant` / `vest` / `release`.
    /// @param homeEid_     Home chain LZ eid. Must be `0` on home; required non-zero on spoke — constructor
    ///                     calls `setPeer(homeEid_, homeAddress_)` so the spoke can receive from home.
    /// @param homeAddress_ `bytes32(0)` = deploy as home (mint `MAX_SUPPLY`, store `address(this)`).
    ///                     Else spoke: canonical home GRS identity (EVM left-padded / Solana pubkey).
    constructor(address lzEndpoint, address delegate, uint32 homeEid_, bytes32 homeAddress_)
        OFT("GrindURUS Token", "GRS", lzEndpoint, delegate)
        Ownable(delegate)
    {
        // LayerZero V2 eids that need native value on lzReceive (ATA / account rent):
        // 30168 = Solana mainnet, 40168 = Solana Devnet.
        peerLzReceiveBudget[30_168] =
            PeerLzReceiveBudget({gas: DEFAULT_LZ_RECEIVE_GAS, value: DEFAULT_SOLANA_LZ_RECEIVE_VALUE});
        peerLzReceiveBudget[40_168] =
            PeerLzReceiveBudget({gas: DEFAULT_LZ_RECEIVE_GAS, value: DEFAULT_SOLANA_LZ_RECEIVE_VALUE});
        homeEid = homeEid_;
        if (homeAddress_ == bytes32(0)) {
            if (homeEid_ != 0) revert InvalidRecipient();
            homeAddress = bytes32(uint256(uint160(address(this))));
            _mint(address(this), MAX_SUPPLY);
        } else {
            if (homeEid_ == 0) revert InvalidRecipient();
            homeAddress = homeAddress_;
            _setPeer(homeEid_, homeAddress_);
        }
    }

    /// @notice Transfers contract ownership to a new owner. Use Ownable2Step for safety; only callable by current owner.
    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    /// @dev Disabled: owner is the default sale payee and LZ endpoint delegate. Transfer via
    ///      Ownable2Step instead — renouncing would leave a sticky LZ delegate and burn ETH on
    ///      native sales with `recipient == bytes32(0)`.
    function renounceOwnership() public view override onlyOwner {
        revert();
    }

    /// @notice Wire or clear the LayerZero peer for `eid` (also refreshes default `enforcedOptions`).
    ///         Spoke constructors already call this for `homeEid` / `homeAddress`; home still needs
    ///         an explicit `setPeer` per spoke after deploy.
    function setPeer(uint32 eid, bytes32 peer) public override onlyOwner {
        _setPeer(eid, peer);
    }

    /// @notice Set lzReceive gas/value used when `setPeer` installs default enforcedOptions.
    ///         `gas == 0` clears the entry (EVM fallback). If the peer is already wired, options refresh.
    function setPeerLzReceiveBudget(uint32 eid, uint128 gas, uint128 value) public onlyOwner {
        if (gas == 0) {
            delete peerLzReceiveBudget[eid];
        } else {
            peerLzReceiveBudget[eid] = PeerLzReceiveBudget({gas: gas, value: value});
        }
        emit PeerLzReceiveBudgetSet(eid, gas, value);
        if (peers[eid] != bytes32(0)) {
            _applyDefaultPeerEnforcedOptions(eid);
        }
    }

    /// @notice Bridges `amountLd` GRS from caller to `to` on destination chain `dstEid`.
    function bridge(uint32 dstEid, bytes32 to, uint256 amountLd) public payable {
        _bridgeFrom(msg.sender, dstEid, to, amountLd);
    }

    /// @notice Home: create or close a sale. `id == 0` appends (`_saleCount + 1`); `id != 0` closes
    ///         that lot (`assetAmount` / `grsAmount` → 0) and releases any local `salesReserved`.
    ///         Create: `asset = 0` is native ETH; `recipient = 0` pays `owner()` at buy; `recipient` is
    ///         32 bytes (EVM address left-padded; Solana pubkey as-is). Buyable lots need
    ///         `assetAmount > 0`; cross-chain quotes must fit `uint64` (Solana wire). `dstEid == 0`
    ///         is local only (`msg.value` must be 0). Else burns `grsAmount` from TokenSales and
    ///         LZ-publishes so the spoke mints escrow; home row is then closed so home `buy` cannot
    ///         fill the same lot. Close: create args are ignored; `dstEid == 0` closes home only;
    ///         else LZ-publishes a zeroed row so the spoke unlists, frees `salesReserved`, and burns
    ///         remaining escrow (inventory is not stranded as float).
    function sale(
        uint256 id,
        bytes32 asset,
        uint256 assetAmount,
        uint256 grsAmount,
        bytes32 recipient,
        uint32 dstEid
    ) public payable onlyOwner returns (uint256) {
        _requireHome();
        if (id != 0) {
            _closeSale(id, dstEid);
            return id;
        }
        // Unbuyable open lots (`assetAmount == 0` with inventory) are rejected; `0/0` placeholders OK.
        if (grsAmount != 0 && assetAmount == 0) revert InvalidAssetAmount();
        // Solana (and shared u64 codec) cannot decode assetAmount above uint64.max.
        if (dstEid != 0 && assetAmount > type(uint64).max) revert InvalidAssetAmount();
        if (dstEid == 0) {
            if (msg.value != 0) revert InvalidPayment();
            // Earmark float so overlapping local lots cannot oversubscribe `_freeInventory`.
            if (grsAmount > 0) {
                _requireFreeInventory(grsAmount);
                salesReserved += grsAmount;
            }
        } else {
            uint256 sendable = _removeDust(grsAmount);
            if (sendable != grsAmount) revert IOFT.SlippageExceeded(sendable, grsAmount);
            if (grsAmount > 0) {
                _requireFreeInventory(grsAmount);
                _takeBucket(Bucket.TokenSales, grsAmount);
                _debit(address(this), grsAmount, grsAmount, dstEid);
            }
        }
        id = _appendSale(asset, assetAmount, grsAmount, recipient);
        if (dstEid != 0) {
            _openSale(id, dstEid);
            Sale storage published = _sales[id];
            published.grsAmount = 0;
            published.assetAmount = 0;
        }
        return id;
    }

    /// @notice Assign `amount` from `bucket`. Instant if `cliffSeconds` and `durationSeconds` are 0
    ///         (`vestingId = 0`). `dstEid == 0` pays on home (`msg.value` must be 0; `to` is an EVM
    ///         address). Else: instant OFT-sends to `to`, or (non-zero schedule) burns inventory and
    ///         LZ-publishes a grant so the spoke opens a local vest (`vestingId = 0` on home; spoke
    ///         id is local). Cliff ≤ `MAX_CLIFF`; linear duration ≤ `MAX_DURATION`. `to` is `bytes32`
    ///         (Solana pubkey as-is, EVM address left-padded).
    function grant(
        Bucket bucket,
        bytes32 to,
        uint256 amount,
        uint64 start,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        uint32 dstEid
    ) public payable onlyOwner returns (uint256 vestingId) {
        return _grant(bucket, to, amount, start, cliffSeconds, durationSeconds, dstEid);
    }

    /// @notice Lock the caller's GRS into a non-revocable `Holder` vest for `to`. Instant schedule
    ///         (`cliffSeconds` and `durationSeconds` both 0) reverts — use `transfer`. Cliff ≤
    ///         `MAX_CLIFF`; linear duration ≤ `MAX_DURATION`. Returns the 1-based vesting id.
    function vest(address to, uint256 amount, uint64 start, uint64 cliffSeconds, uint64 durationSeconds)
        public
        returns (uint256 vestingId)
    {
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        if (amount == 0) revert ZeroAmount();
        if (cliffSeconds == 0 && durationSeconds == 0) revert InstantNotVest();
        if (cliffSeconds > MAX_CLIFF || durationSeconds > MAX_DURATION) revert InvalidSchedule();
        _transfer(msg.sender, address(this), amount);
        vestingId = _openVesting(Bucket.Holder, msg.sender, to, amount, start, cliffSeconds, durationSeconds);
        emit Vest(msg.sender, to, amount, vestingId);
    }

    /// @notice Pay out vested-but-unreleased GRS for vesting `id` to its `beneficiary`. Anyone may
    ///         call; tokens always go to the beneficiary, not `msg.sender`.
    function release(uint256 id) public {
        uint256 amount = releasable(id);
        if (amount == 0) revert ZeroAmount();
        Vesting storage v = _vesting(id);
        v.released += amount;
        vestingLocked -= amount;
        _transfer(address(this), v.beneficiary, amount);
        emit Release(id, v.beneficiary, amount);
    }

    /// @notice Buy `amount` GRS from `TokenSales` via sale `id`. Instant, no vest. Home genesis or
    ///         spoke escrow (this contract's balance). TokenSales has no hard cap (`spent` is
    ///         accounting only) so buybacks returned to this bucket can be re-listed.
    /// @dev CEI: release sale reserve + transfer GRS before paying `recipient` (native / ERC-20 hooks).
    function buy(uint256 id, uint256 amount, address to) public payable returns (uint256 cost) {
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        Sale storage s = _saleAt(id);
        cost = _quoteCost(s, amount);
        s.grsAmount -= amount;
        s.assetAmount -= cost;
        salesReserved -= amount;
        _takeBucket(Bucket.TokenSales, amount);
        _transfer(address(this), to, amount);

        address recipient = s.recipient == bytes32(0) ? owner() : _evm(s.recipient);
        if (s.asset == bytes32(0)) {
            if (msg.value != cost) revert InvalidPayment();
            (bool ok,) = payable(recipient).call{value: cost}("");
            if (!ok) revert PaymentFailed();
        } else {
            if (msg.value != 0) revert InvalidPayment();
            IERC20(address(uint160(uint256(s.asset)))).safeTransferFrom(msg.sender, recipient, cost);
        }

        emit Buy(id, msg.sender, to, amount, cost);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Asset units due for `grsAmount` GRS from sale `id`'s remaining lot. Partial fill is
    ///         `floor(grsAmount × assetAmount / remaining GRS)`; buying the remainder costs all
    ///         remaining `assetAmount`. Quotes the lot only (already in `salesReserved`), not
    ///         `_freeInventory`.
    function quoteBuy(uint256 id, uint256 grsAmount) public view returns (uint256 cost) {
        cost = _quoteCost(_saleAt(id), grsAmount);
    }

    /// @notice Native LayerZero fee for `bridge(dstEid, to, amountLd)` (OFT send quote).
    function quoteBridge(uint32 dstEid, bytes32 to, uint256 amountLd) public view returns (uint256 nativeFee) {
        nativeFee = this.quoteSend(_bridgeParam(dstEid, to, amountLd), false).nativeFee;
    }

    /// @notice Native LZ fee for `sale(id, ..., dstEid)`. `dstEid == 0` is 0.
    ///         `id == 0` quotes create (next id + args); `id != 0` quotes close (zeroed row for that id).
    function quoteSale(
        uint256 id,
        bytes32 asset,
        uint256 assetAmount,
        uint256 grsAmount,
        bytes32 recipient,
        uint32 dstEid
    ) public view returns (uint256 nativeFee) {
        if (dstEid == 0) return 0;
        bytes memory message;
        if (id == 0) {
            message = _encodeSale(_saleCount + 1, asset, assetAmount, grsAmount, recipient);
        } else {
            Sale storage s = _saleAt(id);
            message = _encodeSale(id, s.asset, 0, 0, s.recipient);
        }
        nativeFee = _quote(dstEid, message, _saleOptions(dstEid), false).nativeFee;
    }

    /// @notice Native LZ fee for `grant(..., dstEid)`. `dstEid == 0` is 0. Instant quotes OFT send;
    ///         scheduled grants quote the packed `GRS.grant` message.
    function quoteGrant(
        bytes32 to,
        uint256 amount,
        uint64 start,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        Bucket bucket,
        uint32 dstEid
    ) public view returns (uint256 nativeFee) {
        if (dstEid == 0) return 0;
        if (cliffSeconds == 0 && durationSeconds == 0) {
            return quoteBridge(dstEid, to, amount);
        }
        nativeFee = _quote(dstEid, _encodeGrant(to, amount, start, cliffSeconds, durationSeconds, bucket), _saleOptions(dstEid), false)
            .nativeFee;
    }

    function getAllocations() public view returns (Allocation[] memory listed) {
        _requireHome();
        listed = new Allocation[](BUCKET_COUNT);
        for (uint8 i; i < BUCKET_COUNT; ++i) {
            Bucket b = Bucket(i);
            (uint32 cliffMonths, uint32 linearMonths) = scheduleOf(b);
            uint256 cap = capOf(b);
            uint256 used = spent[b];
            // TokenSales: unlistable float (balance − vest − open sale reserves).
            uint256 left = b == Bucket.TokenSales ? _freeInventory() : cap - used;
            listed[i] = Allocation({
                bucket: b,
                cap: cap,
                spent: used,
                remaining: left,
                gate: gateOf(b),
                cliffMonths: cliffMonths,
                linearMonths: linearMonths
            });
        }
    }

    /// @notice Page of vestings. `offset` is 0-based into the array (id `offset + 1`).
    ///         Reverts `UnknownVesting` if `offset >=` book length; `ZeroAmount` if `limit == 0`.
    ///         A short page (length `< limit`) means the end of the book — there is no `vestingCount`.
    function getVestings(uint256 offset, uint256 limit) public view returns (Vesting[] memory listed) {
        uint256 n = _vestings.length;
        if (limit == 0) revert ZeroAmount();
        if (offset >= n) revert UnknownVesting();
        uint256 end = offset + limit;
        if (end < offset || end > n) end = n;
        uint256 len = end - offset;
        listed = new Vesting[](len);
        for (uint256 i; i < len; ++i) {
            listed[i] = _vestings[offset + i];
        }
    }

    /// @notice Page of sales. `offset` is 0-based into the array (id `offset + 1`).
    ///         Reverts `UnknownSale` if `offset >=` book length; `ZeroAmount` if `limit == 0`.
    ///         A short page (length `< limit`) means the end of the book — there is no `saleCount`.
    function getSales(uint256 offset, uint256 limit) public view returns (Sale[] memory listed) {
        uint256 n = _saleCount;
        if (limit == 0) revert ZeroAmount();
        if (offset >= n) revert UnknownSale();
        uint256 end = offset + limit;
        if (end < offset || end > n) end = n;
        uint256 len = end - offset;
        listed = new Sale[](len);
        for (uint256 i; i < len; ++i) {
            listed[i] = _sales[offset + i + 1];
        }
    }

    function getPeers() public view returns (Peer[] memory listed) {
        uint256 n = peerEids.length;
        listed = new Peer[](n);
        for (uint256 i; i < n; ++i) {
            uint32 eid = peerEids[i];
            listed[i] = Peer({eid: eid, peer: peers[eid]});
        }
    }

    function tokenURI() public pure returns (string memory) {
        return "https://grindurus.xyz/grs.json";
    }

    function capOf(Bucket bucket) public pure returns (uint256) {
        // TokenSales uncapped (buybacks re-enter). Finite genesis rows sum to 850M; Holder = 0.
        if (bucket == Bucket.TokenSales) return type(uint256).max;
        if (bucket == Bucket.PreSeed) return 50_000_000e18;
        if (bucket == Bucket.RevenueShare) return 150_000_000e18;
        if (bucket == Bucket.Airdrops) return 50_000_000e18;
        if (bucket == Bucket.CoreTeam) return 150_000_000e18;
        if (bucket == Bucket.Advisors) return 50_000_000e18;
        if (bucket == Bucket.GrowthFund) return 100_000_000e18;
        if (bucket == Bucket.LpMm) return 100_000_000e18;
        if (bucket == Bucket.LongTermReserve) return 150_000_000e18;
        if (bucket == Bucket.Audits) return 30_000_000e18;
        if (bucket == Bucket.Legal) return 20_000_000e18;
        return 0;
    }

    function gateOf(Bucket bucket) public pure returns (Gate) {
        uint8 i = uint8(bucket);
        // PreSeed(1), CoreTeam(4), Advisors(5), Holder(11) → Linear; TokenSales(0) → Instant; else Proprietary
        if (i == 0) return Gate.Instant;
        if (i == 1 || i == 4 || i == 5 || i == 11) return Gate.Linear;
        return Gate.Proprietary;
    }

    /// @notice Default cliff / linear months from cap-table `grs.svg`. Delegate may still pick other
    ///         `grant` timestamps; proprietary rows have 0/0 (release is gated, not calendar).
    function scheduleOf(Bucket bucket) public pure returns (uint32 cliffMonths, uint32 linearMonths) {
        uint8 i = uint8(bucket);
        if (i == 1) return (0, 24); // PreSeed
        if (i == 3) return (0, 67); // Airdrops
        if (i == 4) return (12, 60); // CoreTeam
        if (i == 5) return (6, 66); // Advisors
    }

    function remaining(Bucket bucket) public view returns (uint256) {
        // TokenSales: unlistable float (balance − vesting lockbox − open sale reserves).
        if (bucket == Bucket.TokenSales) return _freeInventory();
        return capOf(bucket) - spent[bucket];
    }

    function vested(uint256 id, uint256 timestamp) public view returns (uint256) {
        Vesting storage v = _vesting(id);
        if (timestamp < v.cliffEnd) return 0;
        if (v.end <= v.cliffEnd || timestamp >= v.end) return v.allocation;
        return v.allocation * (timestamp - v.cliffEnd) / (v.end - v.cliffEnd);
    }

    function releasable(uint256 id) public view returns (uint256) {
        Vesting storage v = _vesting(id);
        uint256 due = vested(id, block.timestamp);
        return due > v.released ? due - v.released : 0;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
        // Keep LayerZero endpoint delegate in lockstep with Ownable after acceptOwnership.
        // Skip during construction: Ownable runs before OAppCore assigns `endpoint` (OAppCore
        // already calls endpoint.setDelegate(delegate) once the endpoint is live).
        if (newOwner != address(0) && address(endpoint) != address(0)) {
            endpoint.setDelegate(newOwner);
        }
    }

    function _lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) internal override {
        if (_isSaleMessage(message)) {
            _requireSpoke();
            (uint256 id, bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient) = _decodeSale(message);
            // id == 0 is the OFT-compose forgery path (append + remint); home always publishes id ≥ 1.
            if (id == 0) revert UnknownSale();
            bool known = _saleReceived[id];
            uint256 previous = known ? _sales[id].grsAmount : 0;
            // Unordered LZ: Close then Open — keep the closed row; never remint a revoked lot.
            if (known && previous == 0 && grsAmount != 0) {
                return;
            }
            _acceptSale(id, asset, assetAmount, grsAmount, recipient);
            _saleReceived[id] = true;
            if (!known) {
                if (grsAmount != 0) {
                    _credit(address(this), grsAmount, origin.srcEid);
                    salesReserved += grsAmount;
                }
            } else if (grsAmount != previous) {
                // Republish: mint delta on increase; burn escrow on decrease/close so inventory is not stranded.
                if (grsAmount > previous) {
                    uint256 minted = grsAmount - previous;
                    _credit(address(this), minted, origin.srcEid);
                    salesReserved += minted;
                } else {
                    uint256 burned = previous - grsAmount;
                    salesReserved -= burned;
                    _burn(address(this), burned);
                }
            }
            return;
        }
        if (_isGrantMessage(message)) {
            _requireSpoke();
            (
                bytes32 to,
                uint256 amount,
                uint64 start,
                uint64 cliffSeconds,
                uint64 durationSeconds,
                Bucket bucket
            ) = _decodeGrant(message);
            if (cliffSeconds == 0 && durationSeconds == 0) revert InvalidSchedule();
            address payee = _evm(to);
            if (amount != 0) {
                _credit(address(this), amount, origin.srcEid);
            }
            uint256 vestingId =
                _openVesting(bucket, address(this), payee, amount, start, cliffSeconds, durationSeconds);
            emit Granted(bucket, to, amount, vestingId);
            return;
        }
        super._lzReceive(origin, guid, message, executor, extraData);
    }

    function _saleOptions(uint32 dstEid) internal view returns (bytes memory) {
        return this.combineOptions(dstEid, SEND, "");
    }

    /// @dev Ban OFT compose and magic `to` so public `send` cannot forge `GRS.sale` / `GRS.grant`
    ///      packets (length+prefix collision with composed OFT framing). Use `bridge` for OFT transfers;
    ///      custom payloads go through `_lzSend` only from `sale` / `_grant`.
    function _buildMsgAndOptions(SendParam calldata _sendParam, uint256 _amountLd)
        internal
        view
        override
        returns (bytes memory message, bytes memory options)
    {
        if (_sendParam.composeMsg.length != 0) revert ComposeDisabled();
        if (_sendParam.to == SALE_MSG || _sendParam.to == GRANT_MSG) revert InvalidRecipient();
        return super._buildMsgAndOptions(_sendParam, _amountLd);
    }

    function _isSaleMessage(bytes calldata message) internal pure returns (bool) {
        return message.length == SALE_MSG_LEN && bytes32(message[0:32]) == SALE_MSG;
    }

    function _isGrantMessage(bytes calldata message) internal pure returns (bool) {
        return message.length == GRANT_MSG_LEN && bytes32(message[0:32]) == GRANT_MSG;
    }

    function _encodeSale(uint256 id, bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(SALE_MSG, id, asset, assetAmount, uint256(_toSD(grsAmount)), recipient);
    }

    function _encodeGrant(
        bytes32 to,
        uint256 amount,
        uint64 start,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        Bucket bucket
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            GRANT_MSG,
            to,
            uint256(_toSD(amount)),
            uint256(start),
            uint256(cliffSeconds),
            uint256(durationSeconds),
            uint256(uint8(bucket))
        );
    }

    function _amountFromShared(bytes32 word) internal view returns (uint256) {
        uint256 shared = uint256(word);
        if (shared > type(uint64).max) revert IOFT.AmountSDOverflowed(shared);
        // casting to 'uint64' is safe because AmountSDOverflowed above
        // forge-lint: disable-next-line(unsafe-typecast)
        return _toLD(uint64(shared));
    }

    function _decodeSale(bytes calldata message)
        internal
        view
        returns (uint256 id, bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient)
    {
        id = uint256(bytes32(message[32:64]));
        asset = bytes32(message[64:96]);
        assetAmount = uint256(bytes32(message[96:128]));
        grsAmount = _amountFromShared(bytes32(message[128:160]));
        recipient = bytes32(message[160:192]);
    }

    function _decodeGrant(bytes calldata message)
        internal
        view
        returns (
            bytes32 to,
            uint256 amount,
            uint64 start,
            uint64 cliffSeconds,
            uint64 durationSeconds,
            Bucket bucket
        )
    {
        to = bytes32(message[32:64]);
        amount = _amountFromShared(bytes32(message[64:96]));
        start = uint64(uint256(bytes32(message[96:128])));
        cliffSeconds = uint64(uint256(bytes32(message[128:160])));
        durationSeconds = uint64(uint256(bytes32(message[160:192])));
        uint256 bucketRaw = uint256(bytes32(message[192:224]));
        if (bucketRaw > uint8(Bucket.Holder)) revert InvalidSchedule();
        // casting to 'uint8' is safe because InvalidSchedule above (Holder is last enum)
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket = Bucket(uint8(bucketRaw));
    }

    function _saleAt(uint256 id) internal view returns (Sale storage s) {
        if (id == 0 || id > _saleCount) revert UnknownSale();
        return _sales[id];
    }

    function _quoteCost(Sale storage s, uint256 grsAmount) internal view returns (uint256 cost) {
        if (s.assetAmount == 0 || s.grsAmount == 0) revert SaleClosed();
        if (grsAmount == 0) revert ZeroAmount();
        if (grsAmount > s.grsAmount) revert InsufficientInventory();
        cost = grsAmount == s.grsAmount
            ? s.assetAmount
            : Math.mulDiv(grsAmount, s.assetAmount, s.grsAmount, Math.Rounding.Floor);
        if (cost == 0) revert ZeroAmount();
    }

    /// @dev EVM `buy` payee: `bytes32(0)` is handled by the caller. High 12 bytes must be 0 (Solana
    ///      pubkeys are the LZ / spoke payee, not an ETH / ERC-20 destination).
    function _evm(bytes32 word) internal pure returns (address) {
        uint256 n = uint256(word);
        if (n >> 160 != 0) revert InvalidRecipient();
        // casting to 'uint160' is safe because high 12 bytes checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(n));
    }

    /// @dev Home: append a new lot; id = `_saleCount + 1` (1-based).
    function _appendSale(bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient)
        internal
        returns (uint256 id)
    {
        if (recipient == bytes32(uint256(uint160(address(this))))) revert InvalidRecipient();
        id = ++_saleCount;
        _sales[id] = Sale({asset: asset, assetAmount: assetAmount, grsAmount: grsAmount, recipient: recipient});
        emit SaleSet(id, asset, assetAmount, grsAmount, recipient);
    }

    /// @dev Spoke: write/overwrite lot `id` from an LZ sale message (sparse — no gas pad for holes).
    function _acceptSale(uint256 id, bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient)
        internal
    {
        if (recipient == bytes32(uint256(uint160(address(this))))) revert InvalidRecipient();
        if (id > _saleCount) _saleCount = id;
        _sales[id] = Sale({asset: asset, assetAmount: assetAmount, grsAmount: grsAmount, recipient: recipient});
        emit SaleAccepted(id, asset, assetAmount, grsAmount, recipient);
    }

    function _vesting(uint256 id) internal view returns (Vesting storage v) {
        if (id == 0 || id > _vestings.length) revert UnknownVesting();
        return _vestings[id - 1];
    }

    /// @dev Close lot `id` on home; optional LZ zero-row to `dstEid` so the spoke unlists.
    function _closeSale(uint256 id, uint32 dstEid) internal {
        Sale storage s = _saleAt(id);
        uint256 unsold = s.grsAmount;
        if (dstEid == 0) {
            if (msg.value != 0) revert InvalidPayment();
        }
        // Local listings earmark `salesReserved`; cross-chain publish already zeros home first.
        if (unsold > 0) salesReserved -= unsold;
        s.grsAmount = 0;
        s.assetAmount = 0;
        if (dstEid != 0) _openSale(id, dstEid);
        emit SaleSet(id, s.asset, 0, 0, s.recipient);
    }

    function _openSale(uint256 id, uint32 dstEid) internal {
        Sale storage s = _sales[id];
        bytes memory message = _encodeSale(id, s.asset, s.assetAmount, s.grsAmount, s.recipient);
        bytes memory options = _saleOptions(dstEid);
        address inspector = msgInspector;
        if (inspector != address(0)) IOAppMsgInspector(inspector).inspect(message, options);
        MessagingReceipt memory receipt =
            _lzSend(dstEid, message, options, MessagingFee({nativeFee: msg.value, lzTokenFee: 0}), msg.sender);
        emit SalePublished(id, dstEid, receipt.guid);
    }

    function _grant(
        Bucket bucket,
        bytes32 to,
        uint256 amount,
        uint64 start,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        uint32 dstEid
    ) internal returns (uint256 vestingId) {
        _requireHome();
        if (to == bytes32(0) || to == bytes32(uint256(uint160(address(this))))) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (cliffSeconds > MAX_CLIFF || durationSeconds > MAX_DURATION) revert InvalidSchedule();

        if (dstEid == 0) {
            if (msg.value != 0) revert InvalidPayment();
            address payee = _evm(to);
            _requireFreeInventory(amount);
            _takeBucket(bucket, amount);
            if (cliffSeconds == 0 && durationSeconds == 0) {
                _transfer(address(this), payee, amount);
                emit Granted(bucket, to, amount, 0);
                return 0;
            }
            vestingId = _openVesting(bucket, address(this), payee, amount, start, cliffSeconds, durationSeconds);
            emit Granted(bucket, to, amount, vestingId);
            return vestingId;
        }

        // Scheduled grant on an EVM spoke calls `_evm(to)` after credit — validate before burn.
        // Non-EVM peers (Solana etc.) set `peerLzReceiveBudget[eid].value != 0` and accept raw pubkeys.
        bool scheduled = cliffSeconds != 0 || durationSeconds != 0;
        if (scheduled && peerLzReceiveBudget[dstEid].value == 0) {
            _evm(to);
        }

        uint256 sendable = _removeDust(amount);
        if (sendable != amount) revert IOFT.SlippageExceeded(sendable, amount);
        _requireFreeInventory(amount);
        _takeBucket(bucket, amount);

        if (!scheduled) {
            _bridgeFrom(address(this), dstEid, to, amount);
            emit Granted(bucket, to, amount, 0);
            return 0;
        }

        _debit(address(this), amount, amount, dstEid);
        bytes memory message = _encodeGrant(to, amount, start, cliffSeconds, durationSeconds, bucket);
        bytes memory options = _saleOptions(dstEid);
        address inspector = msgInspector;
        if (inspector != address(0)) IOAppMsgInspector(inspector).inspect(message, options);
        _lzSend(dstEid, message, options, MessagingFee({nativeFee: msg.value, lzTokenFee: 0}), msg.sender);
        emit Granted(bucket, to, amount, 0);
        return 0;
    }

    function _bridgeFrom(address from, uint32 dstEid, bytes32 to, uint256 amountLd) internal {
        SendParam memory p = _bridgeParam(dstEid, to, amountLd);
        (uint256 amountSentLd, uint256 amountReceivedLd) =
            _debit(from, p.amountLD, p.minAmountLD, p.dstEid);

        (bytes memory message, bool hasCompose) = OFTMsgCodec.encode(p.to, _toSD(amountReceivedLd), p.composeMsg);
        bytes memory options = this.combineOptions(p.dstEid, hasCompose ? SEND_AND_CALL : SEND, "");
        address inspector = msgInspector;
        if (inspector != address(0)) IOAppMsgInspector(inspector).inspect(message, options);

        MessagingReceipt memory msgReceipt =
            _lzSend(p.dstEid, message, options, MessagingFee({nativeFee: msg.value, lzTokenFee: 0}), msg.sender);
        emit OFTSent(msgReceipt.guid, p.dstEid, from, amountSentLd, amountReceivedLd);
    }

    function _bridgeParam(uint32 dstEid, bytes32 to, uint256 amountLd)
        internal
        view
        returns (SendParam memory param)
    {
        if (to == bytes32(0) || to == SALE_MSG || to == GRANT_MSG) revert InvalidRecipient();
        uint256 amount = _removeDust(amountLd);
        if (amount == 0) revert IOFT.SlippageExceeded(0, amountLd);
        param = SendParam({
            dstEid: dstEid,
            to: to,
            amountLD: amountLd,
            minAmountLD: amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
    }

    function _takeBucket(Bucket bucket, uint256 amount) internal {
        // TokenSales: no hard cap — buybacks returned here can be sold/granted again.
        if (bucket == Bucket.TokenSales) {
            spent[bucket] += amount;
            return;
        }
        uint256 next = spent[bucket] + amount;
        if (next > capOf(bucket)) revert BucketExceeded();
        spent[bucket] = next;
    }

    function _openVesting(
        Bucket bucket,
        address funder,
        address to,
        uint256 amount,
        uint64 start,
        uint64 cliffSeconds,
        uint64 durationSeconds
    ) internal returns (uint256 vestingId) {
        uint64 start_ = start == 0 ? uint64(block.timestamp) : start;
        uint64 cliffEnd = start_ + cliffSeconds;
        uint64 end_ = cliffEnd + durationSeconds;
        if (cliffEnd < start_ || end_ < cliffEnd) revert InvalidSchedule();

        vestingId = _vestings.length + 1;
        vestingLocked += amount;
        _vestings.push(
            Vesting({
                id: vestingId,
                bucket: bucket,
                funder: funder,
                beneficiary: to,
                allocation: amount,
                released: 0,
                start: start_,
                cliffEnd: cliffEnd,
                end: end_
            })
        );
    }

    /// @dev Unlistable inventory: contract balance minus vesting lockbox minus open sale earmarks.
    function _freeInventory() internal view returns (uint256) {
        uint256 bal = balanceOf(address(this));
        uint256 locked = vestingLocked + salesReserved;
        return bal > locked ? bal - locked : 0;
    }

    function _requireFreeInventory(uint256 amount) internal view {
        if (amount > _freeInventory()) revert InsufficientInventory();
    }

    function _requireHome() private view {
        if (homeEid != 0) revert NotHome();
    }

    function _requireSpoke() private view {
        if (homeEid == 0) revert NotSpoke();
    }

    function _setPeer(uint32 eid, bytes32 peer) internal override {
        bytes32 prev = peers[eid];
        super._setPeer(eid, peer);
        if (peer == bytes32(0)) {
            uint256 idx = peerEidIndex[eid];
            if (idx == 0) return;
            uint256 last = peerEids.length;
            if (idx != last) {
                uint32 moved = peerEids[last - 1];
                peerEids[idx - 1] = moved;
                peerEidIndex[moved] = idx;
            }
            peerEids.pop();
            delete peerEidIndex[eid];
            _clearPeerEnforcedOptions(eid);
        } else if (prev == bytes32(0)) {
            peerEids.push(eid);
            peerEidIndex[eid] = peerEids.length;
            _applyDefaultPeerEnforcedOptions(eid);
        }
    }

    /// @dev Per-eid lzReceive budget for auto `enforcedOptions` on `setPeer`. Unset (`gas == 0`)
    ///      falls back to `DEFAULT_LZ_RECEIVE_GAS` / `value = 0` (EVM). Solana/Aptos/etc. set `value`.
    function _applyDefaultPeerEnforcedOptions(uint32 eid) internal {
        (uint128 gas, uint128 value) = _lzReceiveBudget(eid);
        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, value);
        EnforcedOptionParam[] memory enforced = new EnforcedOptionParam[](2);
        enforced[0] = EnforcedOptionParam({eid: eid, msgType: SEND, options: opts});
        enforced[1] = EnforcedOptionParam({eid: eid, msgType: SEND_AND_CALL, options: opts});
        _setEnforcedOptions(enforced);
    }

    function _clearPeerEnforcedOptions(uint32 eid) internal {
        delete enforcedOptions[eid][SEND];
        delete enforcedOptions[eid][SEND_AND_CALL];
    }

    function _lzReceiveBudget(uint32 eid) internal view returns (uint128 gas, uint128 value) {
        PeerLzReceiveBudget memory budget = peerLzReceiveBudget[eid];
        if (budget.gas == 0) return (DEFAULT_LZ_RECEIVE_GAS, 0);
        return (budget.gas, budget.value);
    }

    function _credit(address _to, uint256 _amountLd, uint32 _srcEid)
        internal
        override
        returns (uint256 amountReceivedLd)
    {
        if (totalSupply() + _amountLd > MAX_SUPPLY) revert CapExceeded();
        return super._credit(_to, _amountLd, _srcEid);
    }
}
