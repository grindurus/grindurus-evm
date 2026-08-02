// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GrinderArt} from "./GrinderArt.sol";
import {IGrinders} from "./interfaces/IGrinders.sol";
import {ICustodian} from "./interfaces/ICustodian.sol";
import {IERC1046} from "./interfaces/IERC1046.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";

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
