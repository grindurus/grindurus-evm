// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IGRAI} from "./interfaces/IGRAI.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title On-chain Treasury locker card (pixel UI) for cashflow NFTs.
/// @dev Inlined into `Treasury` (internal library — no separate deploy / link).
library TreasuryArt {
    using Strings for uint256;
    using Strings for address;

    /// @dev Book amounts are GRAI `USD_DECIMALS` (6).
    uint256 private constant USD_DECIMALS = 1e6;

    function tokenJson(
        address locker,
        address cashflowOwner,
        address referrer,
        uint256 ownValue,
        uint256 l1Value,
        uint256 l2Value
    ) internal pure returns (string memory) {
        bool root = referrer == locker;
        return string.concat(
            '{"name":"Treasury Locker ',
            _short(locker),
            '","description":"Tradable claim on GRAI revenue share for a depositor locker.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(locker, cashflowOwner, referrer, root, ownValue, l1Value, l2Value))),
            '","attributes":[{"trait_type":"Locker","value":"',
            locker.toHexString(),
            '"},{"trait_type":"CashflowOwner","value":"',
            cashflowOwner.toHexString(),
            '"},{"trait_type":"Referrer","value":"',
            referrer.toHexString(),
            '"},{"trait_type":"Root","value":"',
            root ? "true" : "false",
            '"},{"trait_type":"OWN","value":"',
            _usd(ownValue),
            '"},{"trait_type":"L1","value":"',
            _usd(l1Value),
            '"},{"trait_type":"L2","value":"',
            _usd(l2Value),
            '"}]}'
        );
    }

    function _svg(
        address locker,
        address cashflowOwner,
        address referrer,
        bool root,
        uint256 ownValue,
        uint256 l1Value,
        uint256 l2Value
    ) private pure returns (string memory) {
        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 320 148' shape-rendering='crispEdges'>",
            "<rect width='320' height='148' fill='#000'/>",
            "<rect x='3' y='3' width='314' height='142' fill='none' stroke='#ff2d8c' stroke-width='2'/>",
            "<circle cx='160' cy='3' r='3' fill='#ff2d8c'/>",
            "<circle cx='160' cy='145' r='3' fill='#ff2d8c'/>",
            "<text x='16' y='30' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='14' font-weight='700' fill='#fff'>Locker</text>",
            "<text x='74' y='30' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='14' fill='#8a8a8a'>",
            _short(locker),
            "</text>",
            root
                ? "<text x='304' y='30' text-anchor='end' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='14' font-weight='700' fill='#ff2d8c'>ROOT</text>"
                : "",
            "<text x='16' y='50' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='14' font-weight='700' fill='#fff'>Owner:</text>",
            "<text x='82' y='50' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='14' fill='#8a8a8a'>",
            _short(cashflowOwner),
            "</text>",
            "<text x='16' y='70' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='14' font-weight='700' fill='#fff'>Referrer:</text>",
            "<text x='102' y='70' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='14' fill='#8a8a8a'>",
            _short(referrer),
            "</text>",
            "<line x1='16' y1='82' x2='304' y2='82' stroke='#ff2d8c' stroke-width='2'/>",
            _col(53, "OWN", ownValue),
            _col(160, "L1", l1Value),
            _col(267, "L2", l2Value),
            "</svg>"
        );
    }

    function _col(uint256 x, string memory label, uint256 amount) private pure returns (string memory) {
        string memory xs = x.toString();
        return string.concat(
            "<text x='",
            xs,
            "' y='106' text-anchor='middle' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='13' fill='#8a8a8a'>",
            label,
            "</text>",
            "<text x='",
            xs,
            "' y='128' text-anchor='middle' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='16' font-weight='700' fill='#fff'>",
            _usd(amount),
            "</text>"
        );
    }

    /// @dev `0xabcdef…1234` → `0xabcdef...1234` (`0x` + 6 + `...` + 4).
    function _short(address account) private pure returns (string memory) {
        bytes memory h = bytes(account.toHexString());
        bytes memory o = new bytes(15);
        o[0] = "0";
        o[1] = "x";
        o[2] = h[2];
        o[3] = h[3];
        o[4] = h[4];
        o[5] = h[5];
        o[6] = h[6];
        o[7] = h[7];
        o[8] = ".";
        o[9] = ".";
        o[10] = ".";
        o[11] = h[38];
        o[12] = h[39];
        o[13] = h[40];
        o[14] = h[41];
        return string(o);
    }

    /// @dev Compact USD: `$N[.xx]` under 1K; else `$N[.x]K` / `M` / `B` (1 dp, trailing zero trimmed).
    function _usd(uint256 amount) private pure returns (string memory) {
        if (amount >= 1e15) return _compact(amount, 1e15, "B"); // >= $1B
        if (amount >= 1e12) return _compact(amount, 1e12, "M"); // >= $1M
        if (amount >= 1_000 * USD_DECIMALS) return _compact(amount, 1_000 * USD_DECIMALS, "K"); // >= $1K

        uint256 whole = amount / USD_DECIMALS;
        uint256 frac2 = (amount % USD_DECIMALS) / 1e4;
        if (frac2 == 0) return string.concat("$", whole.toString());
        if (frac2 % 10 == 0) {
            return string.concat("$", whole.toString(), ".", (frac2 / 10).toString());
        }
        if (frac2 < 10) return string.concat("$", whole.toString(), ".0", frac2.toString());
        return string.concat("$", whole.toString(), ".", frac2.toString());
    }

    function _compact(uint256 amount, uint256 unit, string memory suffix) private pure returns (string memory) {
        uint256 whole = amount / unit;
        uint256 frac1 = ((amount % unit) * 10) / unit;
        if (frac1 == 0) return string.concat("$", whole.toString(), suffix);
        return string.concat("$", whole.toString(), ".", frac1.toString(), suffix);
    }
}

/// @title Treasury
/// @notice Protocol fee sink, sticky referrer tree, and claim-time split between affiliates and `beneficiar`.
/// @dev Three layers:
///      - `tokenId = uint160(locker)` — permanent locker slot; `ownerOf` = cashflow rights (OTC-transferable).
///      - `lockerBooks[locker].referrer` — upline link (set on first `mint`, moved only by `rebind` / `poach`).
///      - `lockerBooks` volumes — L1/L2 deposit books keyed by locker identity in the tree.
///      Claim payees = `ownerOf` of each upline locker node. UUPS; `mint`/`rebind`/`distribute` = only GRAI;
///      payout knobs / upgrades = `GRAI.owner()`.
///      Interact via ERC1967Proxy only.
contract Treasury is ITreasury, ERC721EnumerableUpgradeable, ERC2981Upgradeable, UUPSUpgradeable {
    using Strings for uint256;
    using Strings for address;

    /// @notice Basis-point denominator (`100_00` = 100%).
    uint16 internal constant BPS = 100_00;

    /// @notice Linked GRAI that may call `mint` / `rebind` / `distribute`; upgrades authorized by its `owner`.
    IGRAI public grai;

    /// @notice Protocol fee recipient for the non-affiliate slice of claim-time treasury income.
    address public beneficiar;

    /// @notice Shared ERC-2981 royalty fraction (bps of sale price → `beneficiar`).
    uint16 public royaltyBps;

    /// @notice Per-level claim revenue-share weights in bps (`length == 2`, `sum == BPS`).
    uint16[] public revenueShareBps;

    /// @notice Deposit book + sticky upline per locker.
    mapping(address locker => LockerBook) public lockerBooks;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ITreasury
    /// @param beneficiar_ Protocol fee recipient; `address(0)` defaults to `owner()`.
    function initialize(address grai_, address beneficiar_) external initializer {
        if (grai_ == address(0)) grai_ = msg.sender;
        if (beneficiar_ == address(0)) beneficiar_ = msg.sender;
        __ERC721_init("Treasury", "T-GRAI");
        __ERC721Enumerable_init();
        __ERC2981_init();
        __UUPSUpgradeable_init();
        grai = IGRAI(grai_);
        beneficiar = beneficiar_;
        royaltyBps = 500; // 5%
        revenueShareBps.push(8000); // L1 80%
        revenueShareBps.push(2000); // L2 20%
    }

    /// @notice Protocol admin — `grai.owner()`, or `address(grai)` if that call fails / returns zero.
    /// @dev Same pattern as `Grinders.owner()`.
    function owner() public view returns (address) {
        address grai_ = address(grai);
        if (grai_.code.length == 0) return grai_;
        try grai.owner() returns (address o) {
            if (o != address(0)) return o;
        } catch {}
        return grai_;
    }

    /// @inheritdoc ITreasury
    function setBeneficiar(address beneficiar_) public {
        _onlyOwner();
        if (beneficiar_ == address(0)) revert ZeroAddress();
        beneficiar = beneficiar_;
    }

    /// @inheritdoc ITreasury
    function setRoyaltyBps(uint16 royaltyBps_) external {
        _onlyOwner();
        if (royaltyBps_ > BPS) revert BpsTooHigh();
        royaltyBps = royaltyBps_;
        emit RoyaltyBpsUpdate(royaltyBps_);
    }

    /// @inheritdoc ITreasury
    function setRevenueShareBps(uint16[] memory shares) external {
        _onlyOwner();
        uint256 len = shares.length;
        if (len != 2) revert InvalidShares();
        uint256 sum;
        for (uint256 i; i < len; ++i) {
            sum += shares[i];
        }
        if (sum != BPS) revert InvalidShares();
        revenueShareBps = shares;
        emit RevenueShareUpdate(shares);
    }

    receive() external payable {}

    /// @inheritdoc ITreasury
    /// @dev First call sticky-binds `referrer` when unset (or `locker` if zero), mints cashflow NFT
    ///      to `locker` if needed, and ensures the upline has a cashflow NFT. Looping upline falls
    ///      back to self-root (no revert). Upline stubs from `_ensure` do not set `referrer`, so a
    ///      later `mint` for that address still sticky-binds. On that first bind, any pre-existing
    ///      `locker.l1Value` (downline accrued while unbound) is credited to `referrer.l2Value` when
    ///      share depth is ≥ 2 — matching what `rebind` later debits. Every call with `value > 0`
    ///      credits `locker.value` and walks up to `revenueShareBps.length` upline levels into
    ///      `l1Value` / `l2Value` (levels beyond L2 are walked for stop rules only — books only
    ///      store L1/L2). GRAI calls this on deposit (book USD); claim credits via `distribute`.
    ///      First sticky bind also mirrors any pre-bind `locker.value` (e.g. unbound claims) onto
    ///      the new upline’s L1/L2, matching `_creditBooks`, so later `rebind` debits stay solvent.
    function mint(address locker, address referrer, uint256 value) public returns (uint256 tokenId) {
        _onlyGrai();
        if (locker == address(0)) revert ZeroAddress();
        tokenId = uint256(uint160(locker));
        if (referrerOf(locker) == address(0)) {
            if (referrer == address(0)) referrer = locker;
            if (referrer != locker) _requireValidReferrer(referrer);
            // Looping upline → self-root so a bad referrer does not brick deposit binding.
            if (_hasReferralLoop(locker, referrer)) referrer = locker;
            lockerBooks[locker].referrer = referrer;
            if (_ownerOf(tokenId) == address(0)) {
                _mint(locker, tokenId);
            }
            if (referrer != locker) {
                _ensure(referrer);
                // Unbound claims may have grown `locker.value` with no upline credit. Mirror that
                // stock onto the new tree the same way `_creditBooks` would (without re-adding own).
                uint256 own = lockerBooks[locker].value;
                if (own > 0) _creditUpline(locker, referrer, own);
                // Stub had L1 recruits before bind — those are now L2 under `referrer`.
                if (revenueShareBps.length > 1) {
                    uint256 stubL1 = lockerBooks[locker].l1Value;
                    if (stubL1 > 0) lockerBooks[referrer].l2Value += stubL1;
                }
            }
            emit Mint(locker, referrer, tokenId);
        }
        if (value == 0) return tokenId;
        _creditBooks(locker, value);
    }

    /// @dev Credit `value` to locker + L1/L2 upline walk (same stop rules as `revenueShareInfo`).
    function _creditBooks(address locker, uint256 value) internal {
        if (value == 0) return;
        lockerBooks[locker].value += value;
        _creditUpline(locker, referrerOf(locker), value);
    }

    /// @dev Walk from `ref` up to `revenueShareBps.length` levels, crediting L1 then L2.
    ///      `locker` is the originating node (stop if the walk returns to it).
    function _creditUpline(address locker, address ref, uint256 value) internal {
        if (value == 0) return;
        uint256 levels = revenueShareBps.length;
        for (uint256 level; level < levels;) {
            if (ref == address(0) || ref == locker) break;
            if (level == 0) lockerBooks[ref].l1Value += value;
            else if (level == 1) lockerBooks[ref].l2Value += value;
            unchecked {
                ++level;
            }
            address next = referrerOf(ref);
            if (next == ref) break;
            ref = next;
        }
    }

    /// @inheritdoc ITreasury
    /// @dev Rewrites `locker.referrer` to `newReferrer` and shifts L1/L2 books. Does **not** move the NFT
    ///      (`ownerOf` stays the cashflow holder). Reverts `ReferralLoop` if the new link would
    ///      cycle. Called by GRAI after `poach` payment. L2 book moves only when
    ///      `revenueShareBps.length > 1` (mint never writes L2 at depth 1).
    function rebind(address locker, address newReferrer) public {
        _onlyGrai();
        if (newReferrer == address(0)) revert ZeroAddress();
        if (newReferrer != locker) _requireValidReferrer(newReferrer);
        uint256 tokenId = uint256(uint160(locker));
        if (_ownerOf(tokenId) == address(0)) revert TokenNonexistent(tokenId);

        address from = referrerOf(locker);
        if (from == address(0)) revert ZeroAddress();
        if (newReferrer == from) revert AlreadyBound();
        if (_hasReferralLoop(locker, newReferrer)) revert ReferralLoop();

        LockerBook storage node = lockerBooks[locker];
        uint256 own = node.value;
        uint256 direct = node.l1Value;
        bool shiftL2 = revenueShareBps.length > 1;

        // Self-slot: locker was their own referrer — keep downline L1/L2 on the locker node;
        // only credit the new upline (+ its L2).
        if (from != locker) {
            LockerBook storage seller = lockerBooks[from];
            seller.l1Value -= own;
            if (shiftL2) {
                seller.l2Value -= direct;
                address oldL2 = referrerOf(from);
                if (oldL2 != address(0) && oldL2 != from && oldL2 != locker) {
                    lockerBooks[oldL2].l2Value -= own;
                }
            }
        }

        // Self-root reclaim (`newReferrer == locker`): debit old upline only. Do not credit
        // `own` onto the locker's `l1Value` (would double-count in `poachOf = value + l1Value`)
        // nor treat the old upline as a new L2.
        if (newReferrer != locker) {
            address newL2 = referrerOf(newReferrer);
            LockerBook storage buyer = lockerBooks[newReferrer];
            buyer.l1Value += own;
            if (shiftL2) {
                buyer.l2Value += direct;
                if (newL2 != address(0) && newL2 != newReferrer && newL2 != locker) {
                    lockerBooks[newL2].l2Value += own;
                }
            }
        }

        node.referrer = newReferrer;
        _ensure(newReferrer);
        emit Rebind(locker, from, newReferrer, tokenId);
    }

    /// @inheritdoc ITreasury
    /// @dev Credits referral books with `claimedValue` (book USD of claimed dividends) before payouts
    ///      so poach ask tracks realized yield. No-op payouts if balance < `grossProfitShare` so claim
    ///      is not bricked and partial affiliate pays never happen; book credit still applies.
    ///      Soft-fail per recipient via `_trySend` (no self-call); unpaid → `beneficiar`.
    function distribute(
        address asset,
        address locker,
        uint256 grossProfitShare,
        uint256 revenueShare,
        uint256 claimedValue
    ) public {
        _onlyGrai();
        _creditBooks(locker, claimedValue);

        uint256 bal = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        if (bal < grossProfitShare) return;

        (address[] memory referrers, uint256[] memory shares) = revenueShareInfo(locker, revenueShare);

        revenueShare = 0;
        uint256 len = referrers.length;
        for (uint256 i; i < len;) {
            address ref = referrers[i];
            uint256 share = shares[i];
            if (_trySend(ref, asset, share)) {
                revenueShare += share;
                emit Distribute(asset, ref, share);
            }
            unchecked {
                ++i;
            }
        }

        uint256 netProfitShare = grossProfitShare - revenueShare;
        address to = beneficiar;
        if (_trySend(to, asset, netProfitShare)) {
            emit Distribute(asset, to, netProfitShare);
        }
    }

    /// @inheritdoc ITreasury
    /// @dev Walks sticky `referrer` links; each level’s payee is `ownerOf(uint160(uplineLocker))`.
    function revenueShareInfo(address locker, uint256 revenueShare)
        public
        view
        returns (address[] memory referrers, uint256[] memory shares)
    {
        uint256 levels = revenueShareBps.length;
        if (revenueShare == 0 || levels == 0) return (referrers, shares);

        referrers = new address[](levels);
        shares = new uint256[](levels);
        uint256 level;
        for (address cur = locker; level < levels;) {
            address ref = referrerOf(cur);
            // stop on empty, back-to-locker, or self-loop.
            if (ref == address(0) || ref == locker || ref == cur) break;

            address payee = _ownerOf(uint256(uint160(ref)));
            if (payee == address(0)) break;

            referrers[level] = payee;
            shares[level] = (revenueShare * revenueShareBps[level]) / BPS;
            unchecked {
                ++level;
            }
            cur = ref;
        }
        assembly ("memory-safe") {
            mstore(referrers, level)
            mstore(shares, level)
        }
    }

    /// @dev Shared `royaltyBps` for all tokens; receiver is `beneficiar` (same as Solana
    ///      Metaplex creator / `royalty_info` — not the locker).
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        public
        view
        override
        returns (address receiver, uint256 amount)
    {
        if (_ownerOf(tokenId) == address(0)) return (address(0), 0);
        receiver = beneficiar;
        amount = (salePrice * royaltyBps) / BPS;
    }

    /// @inheritdoc ITreasury
    function referrerOf(address locker) public view returns (address) {
        return lockerBooks[locker].referrer;
    }

    /// @inheritdoc ITreasury
    function poachOf(address locker, address account) public view returns (uint256 price, address referrer) {
        referrer = referrerOf(locker);
        if (referrer == address(0)) revert ZeroAddress();
        if (account == referrer) revert AlreadyBound();
        LockerBook memory node = lockerBooks[locker];
        price = node.value + node.l1Value;
    }

    /// @inheritdoc ITreasury
    /// @dev Pages `_allTokens` via `tokenByIndex`. Empty page if `fromId >= totalSupply`.
    function getLockersData(uint256 fromId, uint256 toId) public view returns (LockerData[] memory list) {
        if (fromId >= toId) revert InvalidRange(fromId, toId);
        uint256 n = totalSupply();
        if (fromId >= n) return list;
        if (toId > n) toId = n;
        uint256 len = toId - fromId;
        list = new LockerData[](len);
        for (uint256 i; i < len;) {
            uint256 tokenId = tokenByIndex(fromId + i);
            // tokenId is always uint256(uint160(locker)) from mint
            // forge-lint: disable-next-line(unsafe-typecast)
            address locker = address(uint160(tokenId));
            list[i] = LockerData({
                locker: locker,
                ownerOf: ownerOf(tokenId),
                book: lockerBooks[locker]
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc ITreasury
    function tokenURI() public pure returns (string memory) {
        return "https://grindurus.xyz/treasury.json";
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert TokenNonexistent(tokenId);
        // casting to 'uint160' is safe because tokenId is always uint256(uint160(locker)) from mint
        // forge-lint: disable-next-line(unsafe-typecast)
        address locker = address(uint160(tokenId));
        LockerBook memory book = lockerBooks[locker];
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    TreasuryArt.tokenJson(
                        locker, ownerOf(tokenId), book.referrer, book.value, book.l1Value, book.l2Value
                    )
                )
            )
        );
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721EnumerableUpgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @dev Mint locker NFT if missing; does not set `referrer`. Uses `_mint` (not `_safeMint`)
    ///      so contract lockers/referrers without `onERC721Received` still bind on deposit.
    function _ensure(address locker) internal {
        uint256 id = uint256(uint160(locker));
        if (_ownerOf(id) == address(0)) {
            _mint(locker, id);
        }
    }

    /// @dev Reject protocol sinks as sticky upline / poach target so claim-time affiliate
    ///      pay cannot be redirected into GRAI inventory, Treasury, or WETH.
    function _requireValidReferrer(address account) internal view {
        if (account == address(grai) || account == address(this) || account == address(grai.weth())) {
            revert InvalidReferrer();
        }
    }

    /// @dev True if `locker.referrer = to` would cycle (`to`'s upline hits `locker` or a loop).
    ///      Self-root `to == locker` is allowed. Floyd tortoise/hare on `referrerOf` from `to`
    ///      (https://en.wikipedia.org/wiki/Cycle_detection) - no hop cap, so deep acyclic trees pass.
    function _hasReferralLoop(address locker, address to) internal view returns (bool) {
        if (to == locker) return false;

        address slow = to;
        address fast = to;
        while (true) {
            address slowRef = referrerOf(slow);
            if (slowRef == address(0) || slowRef == slow) return false;
            if (slowRef == locker || slowRef == to) return true;
            slow = slowRef;

            address fastRef = referrerOf(fast);
            if (fastRef == address(0) || fastRef == fast) return false;
            if (fastRef == locker || fastRef == to) return true;
            fast = fastRef;

            fastRef = referrerOf(fast);
            if (fastRef == address(0) || fastRef == fast) return false;
            if (fastRef == locker || fastRef == to) return true;
            fast = fastRef;

            if (slow == fast) return true;
        }
        return false; // unreachable; satisfies definite-assignment
    }

    function _trySendEth(address to, uint256 amount) internal returns (bool) {
        (bool ok,) = payable(to).call{value: amount}("");
        if (ok) return true;

        IWETH weth = grai.weth();
        try weth.deposit{value: amount}() {
            if (_trySafeTransfer(address(weth), to, amount)) return true;
            // Unwrap so a failed WETH delivery leaves ETH on Treasury for the beneficiar pass.
            try weth.withdraw(amount) {
                return false;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    /// @dev Soft-fail payout (no self-call). ETH → native, else WETH wrap; ERC20 via low-level
    ///      transfer matching SafeERC20 optional-return rules.
    function _trySend(address to, address asset, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        if (to == address(0)) return false;
        if (asset == address(0)) return _trySendEth(to, amount);
        return _trySafeTransfer(asset, to, amount);
    }

    /// @dev Same success predicate as OZ `SafeERC20._callOptionalReturnBool` for `transfer`.
    function _trySafeTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success) return false;
        if (ret.length == 0) return token.code.length > 0;
        if (ret.length == 32) return abi.decode(ret, (bool));
        return false;
    }

    function _onlyGrai() internal view {
        if (msg.sender != address(grai)) revert NotGrai();
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner()) revert NotGraiOwner();
    }

    function _authorizeUpgrade(address) internal view override {
        _onlyOwner();
    }
}
