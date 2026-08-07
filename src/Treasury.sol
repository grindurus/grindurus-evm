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

/// @title Treasury
/// @notice Protocol fee sink, sticky referrer NFTs, and claim-time split between affiliates and `beneficiar`.
/// @dev Flow: GRAI `deposit` → `mint(locker, referrer)` once; GRAI `claim` → `distribute` pays L1/L2
///      from `revenueShareInfo`, unpaid levels + protocol slice → `beneficiar`.
///      UUPS; `mint`/`distribute` = only GRAI; upgrades = `GRAI.owner()`. Interact via ERC1967Proxy only.
contract Treasury is ITreasury, ERC721EnumerableUpgradeable, ERC2981Upgradeable, UUPSUpgradeable {
    using Strings for uint256;
    using Strings for address;

    uint16 public constant BPS = 100_00; // 100%

    /// @notice Linked GRAI that may call `mint` / `distribute`; upgrades authorized by its `owner`.
    IGRAI public grai;

    /// @notice Protocol fee recipient for the non-affiliate slice of claim-time treasury income.
    address public beneficiar;

    /// @notice Shared ERC-2981 royalty fraction (bps of sale price → locker of that token).
    uint16 public royaltyBps;

    /// @notice Per-level claim revenue-share weights in bps (`sum == BPS`).
    uint16[] public revenueShareBps;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ITreasury
    function initialize(address grai_) external initializer {
        if (grai_ == address(0)) revert ZeroAddress();
        __ERC721_init("Grinders Artificial Index Treasury", "GRAI-TREASURY");
        __ERC721Enumerable_init();
        __ERC2981_init();
        __UUPSUpgradeable_init();
        grai = IGRAI(grai_);
        royaltyBps = 500; // 5%
        revenueShareBps.push(8000); // L1 80%
        revenueShareBps.push(2000); // L2 20%
    }

    /// @inheritdoc ITreasury
    function setBeneficiar(address beneficiar_) public {
        _onlyGraiOwner();
        beneficiar = beneficiar_;
    }

    /// @inheritdoc ITreasury
    function setRoyaltyBps(uint16 royaltyBps_) external {
        _onlyGraiOwner();
        if (royaltyBps_ > BPS) revert BpsTooHigh();
        royaltyBps = royaltyBps_;
        emit RoyaltyBpsUpdate(royaltyBps_);
    }

    /// @inheritdoc ITreasury
    function setRevenueShareBps(uint16[] memory shares) external {
        _onlyGraiOwner();
        uint256 len = shares.length;
        if (len == 0) revert InvalidShares();
        uint256 sum;
        for (uint256 i; i < len; ++i) {
            sum += shares[i];
        }
        if (sum != BPS) revert InvalidShares();
        revenueShareBps = shares;
        emit RevenueShareUpdate(shares);
    }

    /// @inheritdoc ITreasury
    function mint(address locker, address referrer) external returns (uint256 tokenId) {
        _onlyGrai();
        if (locker == address(0)) revert ZeroAddress();
        if (referrer == address(0)) referrer = locker;
        tokenId = uint256(uint160(locker));
        if (_ownerOf(tokenId) != address(0)) revert AlreadyBound();
        _safeMint(referrer, tokenId);

        emit Mint(locker, referrer, tokenId);
    }

    receive() external payable {}

    /// @inheritdoc ITreasury
    /// @dev No-op if balance < `netProfitShare` so claim is not bricked and partial affiliate pays
    ///      never happen. Soft-fail per recipient via `_tryWithdraw` (no self-call); unpaid → `beneficiar`.
    function distribute(address asset, address locker, uint256 netProfitShare, uint256 revenueShare) public {
        _onlyGrai();
        uint256 bal = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        if (bal < netProfitShare) return;

        (address[] memory referrers, uint256[] memory shares) = revenueShareInfo(locker, revenueShare);

        revenueShare = 0;
        uint256 len = referrers.length;
        for (uint256 i; i < len;) {
            address ref = referrers[i];
            uint256 share = shares[i];
            if (_tryWithdraw(ref, asset, share)) {
                revenueShare += share;
                emit Distribute(asset, ref, share);
            }
            unchecked {
                ++i;
            }
        }

        uint256 toBeneficiar = netProfitShare - revenueShare;
        if (_tryWithdraw(beneficiar, asset, toBeneficiar)) {
            emit Distribute(asset, beneficiar, toBeneficiar);
        }
    }

    /// @inheritdoc ITreasury
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

            referrers[level] = ref;
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

    /// @dev Shared `royaltyBps` for all tokens; receiver is the bound locker.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        public
        view
        override
        returns (address receiver, uint256 amount)
    {
        if (_ownerOf(tokenId) == address(0)) return (address(0), 0);
        // casting to 'uint160' is safe because tokenId is always uint256(uint160(locker)) from mint
        // forge-lint: disable-next-line(unsafe-typecast)
        receiver = address(uint160(tokenId));
        amount = (salePrice * royaltyBps) / BPS;
    }

    /// @inheritdoc ITreasury
    function referrerOf(address locker) public view returns (address) {
        return _ownerOf(uint256(uint160(locker)));
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
        address affiliate = ownerOf(tokenId);
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"Treasury 0x',
                        tokenId.toString(),
                        '","description":"Tradable claim on GRAI revenue share for a depositor locker.",',
                        '"attributes":[{"trait_type":"Locker","value":"',
                        locker.toHexString(),
                        '"},{"trait_type":"Affiliate","value":"',
                        affiliate.toHexString(),
                        '"}]}'
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

    /// @dev Soft-fail payout (no self-call). ETH → native, else WETH wrap; ERC20 via low-level
    ///      transfer matching SafeERC20 optional-return rules.
    function _tryWithdraw(address to, address asset, uint256 amount) internal returns (bool) {
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

    function _onlyGrai() internal view {
        if (msg.sender != address(grai)) revert NotGrai();
    }

    function _onlyGraiOwner() internal view {
        if (msg.sender != grai.owner()) revert NotGraiOwner();
    }

    function _authorizeUpgrade(address) internal view override {
        _onlyGraiOwner();
    }
}
