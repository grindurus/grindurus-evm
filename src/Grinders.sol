// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
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
contract Grinders is IGrinders, ERC721EnumerableUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IGRAI public grai;

    mapping(bytes32 custodianKind => address) public custodianImplementations;

    mapping(uint256 custodianId => address) public custodians;

    mapping(address custodian => uint256) public custodianIds;

    /// @notice Issuance ledger: how much of `asset` was sent to `custodian` via `allocate`.
    /// @dev Not an escrow balance and not a cap on returns. Custodians swap base↔quote, so they may
    ///      `deallocate` an arbitrary amount of any held asset (often a different token than allocated).
    ///      On deallocate the ledger is floored toward zero for that asset only; it must not gate the pull.
    mapping(address custodian => mapping(address asset => uint256)) public allocated;

    mapping(address asset => uint256) public active;

    /// @dev Storage gap for future upgrades (includes slots formerly used by local liquidation state).
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
        _isCustodian(custodian);
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

    /// @notice Pull `amount` of `asset` from a custodian back to this contract.
    /// @dev Amount is not capped by `allocated`: after swaps the returned token/size need not match
    ///      what was allocated. Ledger is best-effort decreased (floored at 0) for accounting only.
    function deallocate(address asset, uint256 amount) external payable {
        address custodian = msg.sender;
        _isCustodian(custodian);
        if (amount == 0) revert AmountZero();

        if (asset == address(0)) {
            if (msg.value != amount) revert ValueMismatch();
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(custodian, address(this), amount);
        }

        // Issuance ledger only — do not require amount <= allocated (swaps change token/size).
        uint256 prevAllocated = allocated[custodian][asset];
        allocated[custodian][asset] = prevAllocated > amount ? prevAllocated - amount : 0;

        uint256 prevActive = active[asset];
        active[asset] = prevActive > amount ? prevActive - amount : 0;

        emit Deallocate(asset, custodian, amount);
    }

    /// @inheritdoc IGrinders
    /// @dev Permissionless while `grai.liquidation()` is open. Pages custodians, pulls eth/base/quote into
    ///      this contract, then forwards those amounts to GRAI as idle liquidation inventory for `redeem`.
    function liquidate(uint256 fromId, uint256 toId) external {
        if (!grai.liquidation()) revert NoLiquidation();
        if (fromId >= toId) revert InvalidLiquidationRange(fromId, toId);

        uint256 n = totalSupply();
        if (toId > n) toId = n;

        address[] memory assets = grai.getAssets();
        uint256 assetsLen = assets.length;
        for (uint256 i = fromId; i < toId; ++i) {
            address c = custodians[i];
            if (c == address(0)) continue;

            (uint256 ethOut, uint256 baseOut, uint256 quoteOut) = Custodian(payable(c)).liquidate();
            for (uint256 j; j < assetsLen; ++j) {
                address asset = assets[j];
                delete allocated[c][asset];
                delete active[asset];
            }

            IERC20 base = Custodian(payable(c)).baseAsset();
            IERC20 quote = Custodian(payable(c)).quoteAsset();
            _putLiquidated(address(0), ethOut);
            _putLiquidated(address(base), baseOut);
            _putLiquidated(address(quote), quoteOut);
        }

        emit Liquidate(fromId, toId, assetsLen);
    }

    function _putLiquidated(address asset, uint256 amount) private {
        if (amount == 0) return;
        if (asset == address(0)) {
            (bool ok,) = address(grai).call{value: amount}("");
            require(ok, "eth transfer failed");
        } else {
            IERC20(asset).safeTransfer(address(grai), amount);
        }
    }

    function set(bytes32 custodianKind, address implementation) public onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        bytes32 implKind = Custodian(payable(implementation)).custodianKind();
        if (implKind != custodianKind) revert CustodianKindMismatch(custodianKind, implKind);
        custodianImplementations[custodianKind] = implementation;
        emit CustodianImplementationUpdated(custodianKind, implementation);
    }

    /// @notice Deploy a custodian proxy, mint its Grinder NFT, and register it with `owner_`.
    function mint(bytes32 custodianKind, address baseAsset_, address quoteAsset_, address owner_)
        public
        onlyOwner
        returns (address custodian)
    {
        if (owner_ == address(0)) revert OwnerZero();

        address impl = custodianImplementations[custodianKind];
        if (impl == address(0)) revert UnknownCustodianKind(custodianKind);
        bytes32 implKind = Custodian(payable(impl)).custodianKind();
        if (implKind != custodianKind) revert CustodianKindMismatch(custodianKind, implKind);

        uint256 custodianId = totalSupply();

        custodian = address(
            new ERC1967Proxy(impl, abi.encodeCall(Custodian.initialize, (address(this), baseAsset_, quoteAsset_)))
        );

        custodians[custodianId] = custodian;
        custodianIds[custodian] = custodianId;
        _safeMint(owner_, custodianId);

        emit CustodianDeployed(custodianKind, custodian, owner_, baseAsset_, quoteAsset_);
    }

    /// @notice Register a pre-deployed custodian proxy and mint its Grinder NFT.
    function register(address custodian, address owner_) external onlyOwner {
        if (custodian == address(0)) revert CustodianZero();
        if (owner_ == address(0)) revert OwnerZero();
        if (isCustodian(custodian)) revert CustodianAlreadyRegistered(custodianIds[custodian]);
        if (address(Custodian(payable(custodian)).grinders()) != address(this)) revert GrindersMismatch();

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

    function _isCustodian(address account) internal view {
        if (!isCustodian(account)) revert UnknownCustodian();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
