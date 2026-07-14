// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Custodian} from "./Custodian.sol";
import {GrinderArt} from "./GrinderArt.sol";
import {IGrinders} from "./interfaces/IGrinders.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";

/// @title Grinders (implementation)
/// @notice Protocol registry: custodian NFTs and junior capital from GRAI.
/// @dev Do not call this contract directly. Use the ERC1967Proxy address only.
contract Grinders is
    IGrinders,
    ERC721EnumerableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 100_00; // 100%
    uint16 public constant DEFAULT_YIELD_SPLIT = 80_00; // 80%

    IGRAI public grai;

    mapping(bytes32 custodianKind => address) public custodianImplementations;
    mapping(uint256 custodianId => address) public custodians;
    mapping(address custodian => uint256) public custodianIds;
    mapping(address custodian => mapping(address asset => uint256)) public allocated;
    mapping(address asset => uint256) public active;

    /// @dev Storage gap for future upgrades.
    uint256[41] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address grai_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (grai_ == address(0)) revert GraiTokenZero();
        __ERC721_init("Grinders Custodians", "GRINDERS");
        __ERC721Enumerable_init();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        grai = IGRAI(grai_);
        emit GraiTokenUpdate(grai_);
    }

    receive() external payable {}

    function sweep(address asset) public onlyOwner {
        address to = payable(msg.sender);
        uint256 amount = balance(asset);
        if (amount == 0) return;

        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
        emit Sweep(asset, to, amount);
    }

    function allocate(address custodian, address asset, uint256 amount) public onlyOwner {
        _onlyCustodian(custodian);
        if (amount == 0) revert AmountZero();
        if (balance(asset) < amount) revert InsufficientReserve();

        if (asset == address(0)) {
            (bool ok,) = custodian.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(custodian, amount);
        }

        allocated[custodian][asset] += amount;
        active[asset] += amount;

        emit Allocate(asset, custodian, amount);
    }

    function deallocate(address asset, uint256 amount) external payable {
        address custodian = msg.sender;
        _onlyCustodian(custodian);
        if (amount == 0) revert AmountZero();

        if (asset == address(0)) {
            if (msg.value != amount) revert ValueMismatch();
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(custodian, address(this), amount);
        }

        uint256 prevAllocated = allocated[custodian][asset];
        allocated[custodian][asset] = prevAllocated > amount ? prevAllocated - amount : 0;

        uint256 prevActive = active[asset];
        active[asset] = prevActive > amount ? prevActive - amount : 0;

        emit Deallocate(asset, custodian, amount);
    }

    function setCustodianImplementation(bytes32 custodianKind, address implementation) public onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        bytes32 implKind = Custodian(payable(implementation)).custodianKind();
        if (implKind != custodianKind) revert CustodianKindMismatch(custodianKind, implKind);
        custodianImplementations[custodianKind] = implementation;
        emit CustodianImplementationUpdated(custodianKind, implementation);
    }

    /// @notice Deploy a custodian proxy, mint its Grinder NFT, and register it with `owner_`.
    function mint(bytes32 custodianKind, address owner_, IERC20 baseAsset_, IERC20 quoteAsset_) public onlyOwner returns (address custodian) {
        if (owner_ == address(0)) revert OwnerZero();

        address impl = custodianImplementations[custodianKind];
        if (impl == address(0)) revert UnknownCustodianKind(custodianKind);
        bytes32 implKind = Custodian(payable(impl)).custodianKind();
        if (implKind != custodianKind) revert CustodianKindMismatch(custodianKind, implKind);

        uint256 custodianId = totalSupply();

        custodian = address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(
                    Custodian.initialize,
                    (address(this), baseAsset_, quoteAsset_)
                )
            )
        );

        custodians[custodianId] = custodian;
        custodianIds[custodian] = custodianId;
        _safeMint(owner_, custodianId);

        emit CustodianDeployed(custodianKind, custodian, owner_, address(baseAsset_), address(quoteAsset_));
    }

    /// @notice Register a pre-deployed custodian proxy and mint its Grinder NFT.
    function register(address custodian, address owner_) external onlyOwner {
        if (custodian == address(0)) revert CustodianZero();
        if (owner_ == address(0)) revert OwnerZero();
        uint256 custodianId = totalSupply();

        if (custodians[custodianId] != address(0)) revert CustodianAlreadyRegistered(custodianId);

        custodians[custodianId] = custodian;
        custodianIds[custodian] = custodianId;
        _safeMint(owner_, custodianId);

        emit CustodianRegistered(custodian, owner_, custodianId);
    }

    function custodianKindOf(address custodian) public view returns (bytes32 kind) {
        if (custodian == address(0)) return kind;
        if (custodian.code.length == 0) return bytes32(0);
        try Custodian(payable(custodian)).custodianKind() returns (bytes32 k) {
            return k;
        } catch {
            return kind;
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721EnumerableUpgradeable, IERC165) returns (bool) {
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

    function _onlyCustodian(address account) internal view {
        if (!isCustodian(account)) revert UnknownCustodian();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
