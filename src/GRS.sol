// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OFTMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import {IOAppMsgInspector} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppMsgInspector.sol";
import {MessagingFee, MessagingReceipt, Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC1046} from "./interfaces/IERC1046.sol";
import {IGRS} from "./interfaces/IGRS.sol";

/// @title GRS (Grindurus Token)
/// @notice Fixed-supply LayerZero OFT. Home chain mints the 1B genesis into per-bucket inventory
///         (`docs.grindurus.xyz` mechanics / `grs.svg`); delegate `grant`s vesting / instant payouts. Any holder may `vest`
///         their own GRS (home or spoke). Spokes mint/burn via OFT. Admin is Ownable2Step.
contract GRS is OFT, Ownable2Step, IERC1046, IGRS {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant MONTH = 30 days;
    uint64 public constant MAX_CLIFF = 365 days;
    uint64 public constant MAX_DURATION = 4 * 365 days;
    uint8 public constant BUCKET_COUNT = 11;
    /// @dev Packed LZ payload: keccak256("GRS.sale") || id || asset || assetAmount || grsAmountSD || recipient
    ///      (192 bytes). `grsAmount` on the wire is OFT shared decimals (6).
    bytes32 internal constant SALE_MSG = keccak256("GRS.sale");
    uint256 internal constant SALE_MSG_LEN = 192;

    bool public immutable home;
    address public proprietor;
    address public veGRS;
    mapping(Bucket bucket => uint256) public spent;

    Sale[] internal _sales;
    Vesting[] internal _vestings;

    uint32[] public peerEids;
    mapping(uint32 eid => uint256 indexPlusOne) internal peerEidIndex;

    /// @param lzEndpoint Local LayerZero V2 endpoint.
    /// @param delegate   OFT owner / endpoint delegate. On home, does **not** receive the 1B —
    ///                   inventory stays here until `grant` / `vest` / `release`.
    /// @param home_      If true, mint `MAX_SUPPLY` to this contract (canonical chain).
    constructor(address lzEndpoint, address delegate, bool home_)
        OFT("GrindURUS Token", "GRS", lzEndpoint, delegate)
        Ownable(delegate)
    {
        home = home_;
        proprietor = delegate;
        if (home_) {
            _mint(address(this), MAX_SUPPLY);
        }
    }

    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function setProprietor(address proprietor_) public onlyOwner {
        if (!home) revert NotHome();
        proprietor = proprietor_;
        emit ProprietorSet(proprietor_);
    }

    function setVeGRS(address veGRS_) public onlyOwner {
        if (!home) revert NotHome();
        veGRS = veGRS_;
        emit VeGRSSet(veGRS_);
    }

    /// @notice Home: append a sale. Id is `saleCount() + 1`. `asset = 0` is native ETH. `recipient = 0`
    ///         pays `owner()` at buy. `recipient` is 32 bytes (EVM address left-padded; Solana pubkey as-is).
    ///         `dstEid == 0` is local only (`msg.value` must be 0). Else burns `grsAmount` from TokenSales
    ///         inventory and LZ-publishes so the spoke mints that GRS into escrow. The home row is
    ///         then closed (`grsAmount` / `assetAmount` = 0) so home `buy` cannot fill the same lot.
    function sale(
        bytes32 asset,
        uint256 assetAmount,
        uint256 grsAmount,
        bytes32 recipient,
        uint32 dstEid
    ) public payable onlyOwner returns (uint256 id) {
        if (!home) revert NotHome();
        if (dstEid == 0) {
            if (msg.value != 0) revert InvalidPayment();
        } else {
            uint256 sendable = _removeDust(grsAmount);
            if (sendable != grsAmount) revert IOFT.SlippageExceeded(sendable, grsAmount);
            if (grsAmount != 0) {
                _takeBucket(Bucket.TokenSales, grsAmount);
                _debit(address(this), grsAmount, grsAmount, dstEid);
            }
        }
        id = _upsertSale(0, asset, assetAmount, grsAmount, recipient, false);
        if (dstEid != 0) {
            _sale(id, dstEid);
            Sale storage published = _sales[id - 1];
            published.grsAmount = 0;
            published.assetAmount = 0;
        }
    }

    /// @notice Native LZ fee for `sale(..., dstEid)` (next id). `dstEid == 0` is 0.
    function quoteSale(bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient, uint32 dstEid)
        public
        view
        returns (uint256 nativeFee)
    {
        if (dstEid == 0) return 0;
        nativeFee = _quote(
            dstEid, _encodeSale(_sales.length + 1, asset, assetAmount, grsAmount, recipient), _saleOptions(dstEid), false
        ).nativeFee;
    }

    /// @notice Assign `amount` from `bucket`. Instant if `cliffSeconds` and `durationSeconds` are 0
    ///         (`vestingId = 0`). `dstEid == 0` pays on home (`msg.value` must be 0; `to` is an EVM
    ///         address). Else instant only: OFT-send inventory to `to` on that chain (`bytes32`:
    ///         Solana pubkey as-is, EVM address left-padded).
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

    /// @notice Native LZ fee for `grant(..., dstEid)`. `dstEid == 0` is 0.
    function quoteGrant(bytes32 to, uint256 amount, uint32 dstEid) public view returns (uint256 nativeFee) {
        if (dstEid == 0) return 0;
        nativeFee = quoteBridge(dstEid, to, amount);
    }

    function bridge(uint32 dstEid, bytes32 to, uint256 amountLD) public payable {
        _bridgeFrom(msg.sender, dstEid, to, amountLD);
    }

    function quoteBridge(uint32 dstEid, bytes32 to, uint256 amountLD) public view returns (uint256 nativeFee) {
        nativeFee = this.quoteSend(_bridgeParam(dstEid, to, amountLD), false).nativeFee;
    }

    /// @notice Buy `amount` GRS from `TokenSales` via sale `id`. Instant, no vest. Home genesis or
    ///         spoke escrow (this contract's balance). Local 150M cap via `_takeBucket`.
    function buy(uint256 id, uint256 amount, address to) public payable returns (uint256 cost) {
        if (to == address(0)) revert InvalidRecipient();
        cost = previewBuy(id, amount);
        Sale storage s = _sales[id - 1];
        s.grsAmount -= amount;
        s.assetAmount -= cost;
        _takeBucket(Bucket.TokenSales, amount);

        address payee = s.recipient == bytes32(0) ? owner() : _evm(s.recipient);
        if (s.asset == bytes32(0)) {
            if (msg.value != cost) revert InvalidPayment();
            (bool ok,) = payable(payee).call{value: cost}("");
            if (!ok) revert PaymentFailed();
        } else {
            if (msg.value != 0) revert InvalidPayment();
            IERC20(address(uint160(uint256(s.asset)))).safeTransferFrom(msg.sender, payee, cost);
        }

        _transfer(address(this), to, amount);
        emit Bought(id, msg.sender, to, amount, cost);
    }

    function vest(address to, uint256 amount, uint64 start, uint64 cliffSeconds, uint64 durationSeconds)
        public
        returns (uint256 vestingId)
    {
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (cliffSeconds == 0 && durationSeconds == 0) revert InstantNotVest();
        if (cliffSeconds > MAX_CLIFF || durationSeconds > MAX_DURATION) revert InvalidSchedule();
        _transfer(msg.sender, address(this), amount);
        vestingId = _openVesting(Bucket.Holder, msg.sender, to, amount, start, cliffSeconds, durationSeconds);
        emit Vested(msg.sender, to, amount, vestingId);
    }

    function release(uint256 id) public {
        uint256 amount = releasable(id);
        if (amount == 0) revert NothingToRelease();
        Vesting storage v = _vesting(id);
        v.released += amount;
        _transfer(address(this), v.beneficiary, amount);
        emit Released(id, v.beneficiary, amount);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getAllocations() public view returns (Allocation[] memory listed) {
        if (!home) revert NotHome();
        listed = new Allocation[](BUCKET_COUNT);
        for (uint8 i; i < BUCKET_COUNT; ++i) {
            Bucket b = Bucket(i);
            (uint32 cliffMonths, uint32 linearMonths) = scheduleOf(b);
            uint256 cap = capOf(b);
            uint256 used = spent[b];
            listed[i] = Allocation({
                bucket: b,
                cap: cap,
                spent: used,
                remaining: cap - used,
                gate: gateOf(b),
                cliffMonths: cliffMonths,
                linearMonths: linearMonths
            });
        }
    }

    function vestingCount() public view returns (uint256) {
        return _vestings.length;
    }

    /// @notice Page of vestings. `offset` is 0-based into the array (id `offset + 1`).
    function getVestings(uint256 offset, uint256 limit) public view returns (Vesting[] memory listed) {
        uint256 n = _vestings.length;
        if (offset >= n || limit == 0) {
            return listed;
        }
        uint256 end = offset + limit;
        if (end < offset || end > n) end = n;
        uint256 len = end - offset;
        listed = new Vesting[](len);
        for (uint256 i; i < len; ++i) {
            listed[i] = _vestings[offset + i];
        }
    }

    /// @notice Page of sales. `offset` is 0-based into the array (id `offset + 1`).
    function getSales(uint256 offset, uint256 limit) public view returns (Sale[] memory listed) {
        uint256 n = _sales.length;
        if (offset >= n || limit == 0) {
            return listed;
        }
        uint256 end = offset + limit;
        if (end < offset || end > n) end = n;
        uint256 len = end - offset;
        listed = new Sale[](len);
        for (uint256 i; i < len; ++i) {
            listed[i] = _sales[offset + i];
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
        if (bucket == Bucket.TokenSales) return 150_000_000e18;
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
        return 0; // Holder — not a cap-table row
    }

    function gateOf(Bucket bucket) public pure returns (Gate) {
        if (bucket == Bucket.TokenSales) return Gate.Instant;
        if (
            bucket == Bucket.PreSeed
            || bucket == Bucket.CoreTeam
            || bucket == Bucket.Advisors
        ) {
            return Gate.Linear;
        }
        if (
            bucket == Bucket.RevenueShare
            || bucket == Bucket.Airdrops
            || bucket == Bucket.LpMm
            || bucket == Bucket.GrowthFund
            || bucket == Bucket.LongTermReserve
            || bucket == Bucket.Audits
            || bucket == Bucket.Legal
        ) {
            return Gate.Proprietary;
        }
        if (bucket == Bucket.Holder) return Gate.Linear;
        return Gate.Instant;
    }

    /// @notice Default cliff / linear months from cap-table `grs.svg`. Delegate may still pick other
    ///         `grant` timestamps; proprietary rows have 0/0 (release is gated, not calendar).
    function scheduleOf(Bucket bucket) public pure returns (uint32 cliffMonths, uint32 linearMonths) {
        if (bucket == Bucket.PreSeed) return (0, 24);
        if (bucket == Bucket.CoreTeam) return (12, 60);
        if (bucket == Bucket.Advisors) return (6, 66);
        if (bucket == Bucket.Airdrops) return (0, 67);
        return (0, 0);
    }

    function remaining(Bucket bucket) public view returns (uint256) {
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

    function saleCount() public view returns (uint256) {
        return _sales.length;
    }


    /// @notice Asset units due for `grsAmount` GRS from remaining `assetAmount`. Buying the whole
    ///         remainder costs exactly `assetAmount`; a partial fill is `floor(grsAmount × assetAmount / remaining)`.
    function previewBuy(uint256 id, uint256 grsAmount) public view returns (uint256 cost) {
        cost = _quoteCost(_saleAt(id), grsAmount);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }

    function _lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) internal override {
        if (_isSaleMessage(message)) {
            if (home) revert NotSpoke();
            (uint256 id, bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient) = _decodeSale(message);
            uint256 previous = (id > 0 && id <= _sales.length) ? _sales[id - 1].grsAmount : 0;
            _upsertSale(id, asset, assetAmount, grsAmount, recipient, true);
            if (grsAmount != 0 && previous == 0) {
                _credit(address(this), grsAmount, origin.srcEid);
            }
            return;
        }
        super._lzReceive(origin, guid, message, executor, extraData);
    }

    function _saleOptions(uint32 dstEid) internal view returns (bytes memory) {
        return this.combineOptions(dstEid, SEND, "");
    }

    function _isSaleMessage(bytes calldata message) internal pure returns (bool) {
        return message.length == SALE_MSG_LEN && bytes32(message[0:32]) == SALE_MSG;
    }

    function _encodeSale(uint256 id, bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(SALE_MSG, id, asset, assetAmount, uint256(_toSD(grsAmount)), recipient);
    }

    function _decodeSale(bytes calldata message)
        internal
        view
        returns (uint256 id, bytes32 asset, uint256 assetAmount, uint256 grsAmount, bytes32 recipient)
    {
        id = uint256(bytes32(message[32:64]));
        asset = bytes32(message[64:96]);
        assetAmount = uint256(bytes32(message[96:128]));
        uint256 shared = uint256(bytes32(message[128:160]));
        if (shared > type(uint64).max) revert CapExceeded();
        grsAmount = _toLD(uint64(shared));
        recipient = bytes32(message[160:192]);
    }

    function _saleAt(uint256 id) internal view returns (Sale storage s) {
        if (id == 0 || id > _sales.length) revert UnknownSale();
        return _sales[id - 1];
    }

    function _quoteCost(Sale storage s, uint256 grsAmount) internal view returns (uint256 cost) {
        if (s.assetAmount == 0 || s.grsAmount == 0) revert SaleClosed();
        if (grsAmount == 0) revert ZeroAmount();
        if (grsAmount > s.grsAmount) revert SaleExceeded();
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
        return address(uint160(n));
    }

    function _upsertSale(
        uint256 id,
        bytes32 asset,
        uint256 assetAmount,
        uint256 grsAmount,
        bytes32 recipient,
        bool accepted
    ) internal returns (uint256) {
        if (recipient == bytes32(uint256(uint160(address(this))))) revert InvalidRecipient();
        Sale memory row =
            Sale({asset: asset, assetAmount: assetAmount, grsAmount: grsAmount, recipient: recipient});
        if (id == 0) {
            _sales.push(row);
            id = _sales.length;
        } else if (accepted) {
            while (_sales.length < id) {
                _sales.push(Sale({asset: bytes32(0), assetAmount: 0, grsAmount: 0, recipient: bytes32(0)}));
            }
            _sales[id - 1] = row;
        } else {
            revert UnknownSale();
        }
        if (accepted) emit SaleAccepted(id, asset, assetAmount, grsAmount, recipient);
        else emit SaleSet(id, asset, assetAmount, grsAmount, recipient);
        return id;
    }

    function _vesting(uint256 id) internal view returns (Vesting storage v) {
        if (id == 0 || id > _vestings.length) revert UnknownVesting();
        return _vestings[id - 1];
    }

    function _sale(uint256 id, uint32 dstEid) internal {
        Sale storage s = _sales[id - 1];
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
        if (!home) revert NotHome();
        if (to == bytes32(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();

        if (dstEid == 0) {
            if (msg.value != 0) revert InvalidPayment();
            address payee = _evm(to);
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

        if (cliffSeconds != 0 || durationSeconds != 0) revert InvalidSchedule();
        uint256 sendable = _removeDust(amount);
        if (sendable != amount) revert IOFT.SlippageExceeded(sendable, amount);
        _takeBucket(bucket, amount);
        _bridgeFrom(address(this), dstEid, to, amount);
        emit Granted(bucket, to, amount, 0);
    }

    function _bridgeFrom(address from, uint32 dstEid, bytes32 to, uint256 amountLD) internal {
        SendParam memory p = _bridgeParam(dstEid, to, amountLD);
        (uint256 amountSentLD, uint256 amountReceivedLD) =
            _debit(from, p.amountLD, p.minAmountLD, p.dstEid);

        (bytes memory message, bool hasCompose) = OFTMsgCodec.encode(p.to, _toSD(amountReceivedLD), p.composeMsg);
        bytes memory options = this.combineOptions(p.dstEid, hasCompose ? SEND_AND_CALL : SEND, "");
        address inspector = msgInspector;
        if (inspector != address(0)) IOAppMsgInspector(inspector).inspect(message, options);

        MessagingReceipt memory msgReceipt =
            _lzSend(p.dstEid, message, options, MessagingFee(msg.value, 0), msg.sender);
        emit OFTSent(msgReceipt.guid, p.dstEid, from, amountSentLD, amountReceivedLD);
    }

    function _bridgeParam(uint32 dstEid, bytes32 to, uint256 amountLD)
        internal
        view
        returns (SendParam memory param)
    {
        if (to == bytes32(0)) revert InvalidRecipient();
        uint256 amount = _removeDust(amountLD);
        if (amount == 0) revert IOFT.SlippageExceeded(0, amountLD);
        param = SendParam({
            dstEid: dstEid,
            to: to,
            amountLD: amountLD,
            minAmountLD: amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
    }

    function _takeBucket(Bucket bucket, uint256 amount) internal {
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
        } else if (prev == bytes32(0)) {
            peerEids.push(eid);
            peerEidIndex[eid] = peerEids.length;
        }
    }

    function _credit(address _to, uint256 _amountLD, uint32 _srcEid)
        internal
        override
        returns (uint256 amountReceivedLD)
    {
        if (totalSupply() + _amountLD > MAX_SUPPLY) revert CapExceeded();
        return super._credit(_to, _amountLD, _srcEid);
    }
}
