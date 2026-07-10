// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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

    function tokenJson(uint256 tokenId, address custody, bytes32 kind) public view returns (string memory) {
        uint256 s = uint256(keccak256(abi.encodePacked("grindurus.grinder", block.chainid, tokenId, kind)));
        return string.concat(
            '{"name":"Grindurus Custodian #',
            tokenId.toString(),
            '","description":"On-chain Grindurus logo NFT for GRAI custodians.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(s))),
            '","attributes":[{"trait_type":"Custodian ID","value":',
            tokenId.toString(),
            '},{"trait_type":"Custody","value":"',
            custody.toHexString(),
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
