// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IGrinders} from "./interfaces/IGrinders.sol";
import {ICustodian} from "./interfaces/ICustodian.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";

/// @title On-chain Grindurus logo pixel art (from brand mark) for Treasury NFTs.
/// @dev Fresh 24×24 quantization of logo.png: bg / navy / white / pink + seed palettes.
library GrinderArt {
    using Strings for uint256;
    using Strings for address;

    bytes private constant DIGITS = "0123456789";

    /// @dev 24×24, 2 bits/px row-major: 0=bg, 1=body, 2=white, 3=pink accent.
    bytes private constant MASK =
        hex"00000000001800000000006800aaa40001a802aa900006ac02aaaa901aa002aaa5aa1a8001aa5ea6aa800005562e95aa000957959a000025555680000815555bae00285775560820285d755608a09c7d7f54aab08c75555000008c76956000008c36954000004336a50000000375a500000000d5a96aaa8000356a6aa800000d6a5aa00000005a950000000000a00000";

    bytes private constant BG = hex"0000000a06121a0a221408280e10200c1830184020201850";
    bytes private constant BODY = hex"1c24441a20381e28501c2a48142238101830141c40182038";
    bytes private constant HI = hex"fffffff0f4fff5e6c8e8f0ffe0e8f0fff8e0f0fff0fff0e8";
    bytes private constant ACC = hex"ff2d8cff4d8dff1a6eff6ab0ff3d00ffd4002dff9a00e5ff";

    // 16 horn / metal tints applied to white pixels on the upper horn band.
    bytes private constant HORN =
        hex"f5e6c8ffd700e8dcc8c0c0c8ffb6c1b87333fff8ffff2a4ad4af37e6c35cff8c42a8e6cff0e68ce0b0ff98d8c8ffe4c4";

    /// @dev Inlined into `Grinders` (internal library — no separate deploy / link).
    function tokenJson(uint256 tokenId, address custodian, bytes32 kind) internal view returns (string memory) {
        uint256 s = uint256(keccak256(abi.encodePacked("grindurus.grinder", block.chainid, tokenId, kind)));
        return string.concat(
            '{"name":"Grindurus Custodian #',
            tokenId.toString(),
            '","description":"On-chain Grindurus logo NFT for GRAI custodians.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(s))),
            '","attributes":[{"trait_type":"Custodian ID","value":',
            tokenId.toString(),
            '},{"trait_type":"Custodian","value":"',
            custodian.toHexString(),
            '"},{"trait_type":"Kind","value":"',
            uint256(kind).toHexString(32),
            '"},{"trait_type":"Background","value":',
            ((s >> 4) % 8).toString(),
            '},{"trait_type":"Body","value":',
            ((s >> 8) % 8).toString(),
            '},{"trait_type":"Highlight","value":',
            ((s >> 12) % 8).toString(),
            '},{"trait_type":"Accent","value":',
            ((s >> 16) % 8).toString(),
            '},{"trait_type":"Horn","value":',
            ((s >> 20) % 16).toString(),
            '},{"trait_type":"Facing","value":"Right"}]}'
        );
    }

    function _rgb(bytes memory t, uint256 i) private pure returns (uint256) {
        unchecked {
            i *= 3;
            return (uint256(uint8(t[i])) << 16) | (uint256(uint8(t[i + 1])) << 8) | uint8(t[i + 2]);
        }
    }

    function _svg(uint256 s) private pure returns (string memory out) {
        uint256 bg = _rgb(BG, (s >> 4) % 8);
        uint256 body = _rgb(BODY, (s >> 8) % 8);
        uint256 hi = _rgb(HI, (s >> 12) % 8);
        uint256 acc = _rgb(ACC, (s >> 16) % 8);
        uint256 horn = _rgb(HORN, (s >> 20) % 16);

        out = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' shape-rendering='crispEdges'>",
            _r(0, 0, 24, 24, bg)
        );

        uint256 bit;
        for (uint256 y; y < 24;) {
            uint256 x;
            while (x < 24) {
                uint256 byteIndex = bit >> 2;
                uint256 shift = 6 - ((bit & 3) << 1);
                uint256 c = (uint8(MASK[byteIndex]) >> shift) & 3;
                unchecked {
                    ++bit;
                }
                if (c == 0) {
                    unchecked {
                        ++x;
                    }
                    continue;
                }
                uint256 x0 = x;
                unchecked {
                    ++x;
                }
                while (x < 24) {
                    uint256 bi2 = bit >> 2;
                    uint256 sh2 = 6 - ((bit & 3) << 1);
                    uint256 c2 = (uint8(MASK[bi2]) >> sh2) & 3;
                    if (c2 != c) break;
                    unchecked {
                        ++bit;
                        ++x;
                    }
                }
                uint256 color;
                if (c == 1) {
                    color = body;
                } else if (c == 3) {
                    color = acc;
                } else {
                    // White mark: horn tint on the upper horn band, else highlight.
                    color = y <= 5 ? horn : hi;
                }
                out = string.concat(out, _r(x0, y, x - x0, 1, color));
            }
            unchecked {
                ++y;
            }
        }
        out = string.concat(out, "</svg>");
    }

    function _u(uint256 v) private pure returns (string memory) {
        unchecked {
            if (v < 10) {
                bytes memory one = new bytes(1);
                one[0] = DIGITS[v];
                return string(one);
            }
            bytes memory two = new bytes(2);
            two[0] = DIGITS[v / 10];
            two[1] = DIGITS[v % 10];
            return string(two);
        }
    }

    function _r(uint256 x, uint256 y, uint256 w, uint256 h, uint256 color) private pure returns (string memory) {
        return string.concat(
            "<rect x='", _u(x), "' y='", _u(y), "' width='", _u(w), "' height='", _u(h), "' fill='", _hex(color), "'/>"
        );
    }

    function _hex(uint256 rgb) private pure returns (string memory) {
        bytes16 H = "0123456789abcdef";
        bytes memory o = new bytes(7);
        o[0] = "#";
        unchecked {
            for (uint256 i; i < 6; ++i) {
                o[6 - i] = H[rgb & 0xf];
                rgb >>= 4;
            }
        }
        return string(o);
    }
}

/// @title Grinders (implementation)
/// @notice Protocol registry: custodian NFTs and junior capital from GRAI.
/// @dev Do not call this contract directly. Use the ERC1967Proxy address only.
contract Grinders is IGrinders, ERC721EnumerableUpgradeable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Linked GRAI core contract for liquidation-state checks and asset routing.
    IGRAI public grai;

    /// @notice Registered custodian implementations by custody kind hash.
    mapping(bytes32 custodianKind => address) public custodianImplementations;

    /// @notice Custodian proxy address by NFT id (sparse-safe; removed slots may be zero).
    mapping(uint256 custodianId => address) public custodians;

    /// @notice Reverse index: registered custodian address => NFT id.
    mapping(address custodian => uint256) public custodianIds;

    /// @dev Storage gap for future upgrades (includes slots formerly used by local liquidation
    ///      state and the removed `allocated` / `totalAllocated` issuance ledgers).
    uint256[43] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address grai_) public initializer {
        if (owner_ == address(0)) owner_ = msg.sender;
        if (grai_ == address(0)) grai_ = owner_;
        __ERC721_init("Grinders Custodians", "GRINDERS");
        __ERC721Enumerable_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        grai = IGRAI(grai_);
    }

    /// @notice Retarget the linked GRAI core. Call before `GRAI.setGrinders` when rewiring
    ///         (that setter requires `grinders.grai() == address(grai)`).
    function setGrai(address grai_) public onlyOwner {
        if (grai_ == address(0)) revert GraiTokenZero();
        grai = IGRAI(grai_);
        emit GraiTokenUpdate(grai_);
    }

    receive() external payable {}

    function set(bytes32 custodianKind, address implementation) public onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        bytes32 implKind = ICustodian(payable(implementation)).custodianKind();
        if (implKind != custodianKind) revert CustodianKindMismatch(custodianKind, implKind);
        custodianImplementations[custodianKind] = implementation;
        emit CustodianImplementationUpdated(custodianKind, implementation);
    }

    /// @notice Deploy a custodian proxy, mint its Grinder NFT, and register it with `owner_`.
    function mint(
        bytes32 custodianKind,
        address owner_,
        address baseAsset_,
        address quoteAsset_
    ) public onlyOwner returns (address custodian) {
        if (owner_ == address(0)) owner_ = owner();

        address impl = custodianImplementations[custodianKind];
        if (impl == address(0)) revert UnknownCustodianKind(custodianKind);
        bytes32 implKind = ICustodian(payable(impl)).custodianKind();
        if (implKind != custodianKind) revert CustodianKindMismatch(custodianKind, implKind);

        uint256 custodianId = totalSupply();

        custodian = address(new ERC1967Proxy(impl, abi.encodeCall(ICustodian.initialize, (address(this)))));

        custodians[custodianId] = custodian;
        custodianIds[custodian] = custodianId;
        _safeMint(owner_, custodianId);

        ICustodian(payable(custodian)).setAssets(baseAsset_, quoteAsset_);

        emit CustodianDeployed(custodianKind, custodian, owner_, baseAsset_, quoteAsset_);
    }

    /// @notice Register a pre-deployed custodian proxy and mint its Grinder NFT.
    function register(address custodian, address owner_) public onlyOwner {
        if (custodian == address(0)) revert CustodianZero();
        if (owner_ == address(0)) owner_ = owner();
        if (isCustodian(custodian)) revert CustodianAlreadyRegistered(custodianIds[custodian]);
        if (address(ICustodian(payable(custodian)).grinders()) != address(this)) revert GrindersMismatch();

        uint256 custodianId = totalSupply();
        if (custodians[custodianId] != address(0)) revert CustodianAlreadyRegistered(custodianId);

        custodians[custodianId] = custodian;
        custodianIds[custodian] = custodianId;
        _safeMint(owner_, custodianId);

        emit CustodianRegistered(custodian, owner_, custodianId);
    }

    /// @notice Set trading assets on a registered custodian (protocol owner only).
    function setAssets(address custodian, address baseAsset_, address quoteAsset_) public onlyOwner {
        _requireCustodian(custodian);
        ICustodian(payable(custodian)).setAssets(baseAsset_, quoteAsset_);
    }

    function allocate(address custodian, address asset, uint256 amount) public onlyOwner {
        _requireCustodian(custodian);
        if (balance(asset) < amount) revert InsufficientReserve();

        if (asset == address(0)) {
            (bool ok,) = custodian.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(custodian, amount);
        }

        emit Allocate(custodian, asset, amount);
    }

    /// @notice Pull `amount` of `asset` from a custodian back to this contract.
    /// @dev Protocol owner only. Not capped by prior allocations — after swaps the returned
    ///      token/size need not match what was sent. Track `Allocate` / `Deallocate` off-chain.
    function deallocate(address custodian, address asset, uint256 amount) public onlyOwner {
        _requireCustodian(custodian);
        if (amount == 0) revert AmountZero();

        ICustodian(payable(custodian)).deallocate(asset, amount);

        emit Deallocate(custodian, asset, amount);
    }

    /// @notice Forward custodian yield `amount` of `asset` to GRAI.distribute.
    /// @dev Protocol owner only.
    function distribute(address custodian, address asset, uint256 yieldAmount) public onlyOwner {
        _requireCustodian(custodian);
        ICustodian(payable(custodian)).distribute(asset, yieldAmount);
    }

    /// @inheritdoc IGrinders
    /// @dev Permissionless while `grai.liquidation()` is open. Pages custodians by registered id,
    ///      pulls eth/base/quote into this contract, then forwards those amounts to GRAI as idle
    ///      liquidation inventory for `liquidate`. Return amounts are trusted: only registered
    ///      custodian wallets are iterated, under the Grinders NFT custody model.
    function liquidate(uint256 fromId, uint256 toId) public {
        _requireLiquidation();
        if (fromId >= toId) {
            fromId = type(uint256).max;
            toId = type(uint256).max;
            IGRAI.DutchAuction[] memory assets;
            try grai.getAssets() returns (IGRAI.DutchAuction[] memory list) {
                assets = list;
            } catch {
                return;
            }
            uint256 len = assets.length;
            for (uint256 i; i < len; ++i) {
                address asset = assets[i].asset;
                _liquidate(asset, balance(asset));
            }
        } else {
            uint256 n = totalSupply();
            if (toId > n) toId = n;
            for (uint256 i = fromId; i < toId; ++i) {
                address custodian = custodians[i];
                if (custodian == address(0)) continue;
                ICustodian c = ICustodian(payable(custodian));
                (uint256 ethOut, uint256 baseOut, uint256 quoteOut) = c.liquidate();
                _liquidate(address(0), ethOut);
                _liquidate(c.baseAsset(), baseOut);
                _liquidate(c.quoteAsset(), quoteOut);
            }
        }
        emit Liquidate(fromId, toId);
    }

    function _liquidate(address asset, uint256 amount) private {
        if (amount == 0) return;
        if (asset == address(0)) {
            (bool ok,) = address(grai).call{value: amount}("");
            require(ok, "eth transfer failed");
        } else {
            IERC20(asset).safeTransfer(address(grai), amount);
        }
    }

    /// @inheritdoc IGrinders
    function getCustodiansData(uint256 fromId, uint256 toId) public view returns (CustodianData[] memory list) {
        if (fromId >= toId) revert InvalidCustodianRange(fromId, toId);
        uint256 n = totalSupply();
        if (toId > n) toId = n;
        uint256 len = toId - fromId;
        list = new CustodianData[](len);
        for (uint256 i; i < len;) {
            uint256 id = fromId + i;
            address custodian = custodians[id];
            list[i].id = id;
            list[i].custodian = custodian;
            if (custodian != address(0)) {
                ICustodian c = ICustodian(payable(custodian));
                list[i].owner = _ownerOf(id);
                list[i].kind = custodianKindOf(custodian);
                list[i].baseAsset = c.baseAsset();
                list[i].quoteAsset = c.quoteAsset();
                list[i].ethBalance = custodian.balance;
                list[i].baseBalance = list[i].baseAsset == address(0)
                    ? custodian.balance
                    : IERC20(list[i].baseAsset).balanceOf(custodian);
                list[i].quoteBalance = list[i].quoteAsset == address(0)
                    ? custodian.balance
                    : IERC20(list[i].quoteAsset).balanceOf(custodian);
            }
            unchecked { ++i; }
        }
    }

    function custodianKindOf(address custodian) public view returns (bytes32 kind) {
        if (custodian == address(0)) return kind;
        if (custodian.code.length == 0) return bytes32(0);
        try ICustodian(payable(custodian)).custodianKind() returns (bytes32 k) {
            return k;
        } catch {
            return kind;
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721EnumerableUpgradeable, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC1046
    function tokenURI() public pure returns (string memory) {
        return "https://grindurus.xyz/metadata.json";
    }

    function tokenURI(uint256 custodianId) public view override returns (string memory) {
        address custodian = custodians[custodianId];
        if (custodian == address(0)) revert CustodianNonexistent(custodianId);
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(GrinderArt.tokenJson(custodianId, custodian, custodianKindOf(custodian))))
        );
    }

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function isCustodian(address custodian) public view returns (bool) {
        if (custodian == address(0)) return false;
        return custodians[custodianIds[custodian]] == custodian;
    }

    /// @notice Registered NFT id for `account`, or `type(uint256).max` if unregistered.
    function custodyIdOf(address account) public view returns (uint256) {
        if (!isCustodian(account)) return type(uint256).max;
        return custodianIds[account];
    }

    function _requireCustodian(address account) internal view {
        if (!isCustodian(account)) revert UnknownCustodian();
    }

    function _requireLiquidation() internal view {
        if (address(grai).code.length == 0) return;
        try grai.liquidation() returns (bool liquidation) {
            if (!liquidation) revert NoLiquidation();
        } catch {
            return;
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
