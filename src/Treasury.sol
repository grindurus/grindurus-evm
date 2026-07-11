// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Custodian} from "./Custodian.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {GrinderArt} from "./GrinderArt.sol";

/// @title Treasury (implementation)
/// @notice Grinders' treasury: ERC721 seats for grinders, each bound to a custody wallet, plus the sink for GRAI yield.
/// @dev Mechanics:
///      - Owner registers custody implementations by `custodyKind` (`setCustodyImplementation`).
///      - Owner `mint`s a grinder NFT and deploys an ERC1967 custody proxy for that token; NFT owner controls the custody.
///      - `tokenURI` is on-chain GrinderArt pixel metadata keyed by tokenId / custody / kind.
///      - GRAI `distribute` sends the protocol's treasury yield share here; owner `withdraw`s ETH/ERC20.
///      - `isCustody` is the registry GRAI uses when allocating junior capital to grinders.
///      Interact only via the ERC1967Proxy, not this implementation.
contract Treasury is ITreasury, OwnableUpgradeable, ERC721EnumerableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    address public grai;

    /// @dev Registry key for a custodian implementation family. Each `Custodian` impl exposes
    ///      `custodianKind()` as `keccak256("grindurus.custodian.<name>")` (e.g. `...cow`, `...lifi`);
    ///      bump to `...<name>.v2` only when storage/API is incompatible. UUPS upgrades within
    ///      the same kind reuse this key via `setCustodyImplementation`; `mint` looks up the impl here.
    mapping(bytes32 custodianKind => address) public custodyImplementations;

    mapping(uint256 custodianId => address) public custodians;
    mapping(address custodian => uint256) public custodianIds;

    /// @dev Storage gap for future upgrades.
    uint256[46] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(address owner_, address grai_) public initializer {
        if (owner_ == address(0) || grai_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ERC721_init("Grinders Treasury", "GRINDERS");
        __ERC721Enumerable_init();

        grai = grai_;
    }

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function isCustody(address custody) public view returns (bool) {
        return custodians[custodianIds[custody]] == custody;
    }

    /// @notice On-chain Grindurus logo pixel art metadata for the custodian NFT.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        address custody = custodians[tokenId];
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(GrinderArt.tokenJson(tokenId, custody, _custodianKind(custody))))
        );
    }

    function _custodianKind(address custody) internal view returns (bytes32 kind) {
        if (custody == address(0)) return kind;
        if (custody.code.length == 0) return bytes32(0);
        try Custodian(payable(custody)).custodianKind() returns (bytes32 k) {
            return k;
        } catch {
            return kind;
        }
    }

    function setCustodyImplementation(bytes32 custodyKind, address implementation) public onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        bytes32 implKind = Custodian(payable(implementation)).custodianKind();
        if (implKind != custodyKind) revert CustodyKindMismatch(custodyKind, implKind);
        custodyImplementations[custodyKind] = implementation;
        emit CustodyImplementationUpdated(custodyKind, implementation);
    }

    /// @notice Deploy a custodian proxy for `owner_`, mint its NFT (`tokenId = custodianId`), and register it.
    function mint(bytes32 custodyKind, address owner_, IERC20 baseAsset_, IERC20 quoteAsset_)
        public
        onlyOwner
        returns (address custody)
    {
        if (owner_ == address(0)) revert OwnerZero();

        address impl = custodyImplementations[custodyKind];
        if (impl == address(0)) revert UnknownCustodyKind(custodyKind);
        bytes32 implKind = Custodian(payable(impl)).custodianKind();
        if (implKind != custodyKind) revert CustodyKindMismatch(custodyKind, implKind);

        uint256 custodianId = totalSupply();

        _mint(owner_, custodianId);

        custody = address(
            new ERC1967Proxy(
                impl,
                abi.encodeCall(
                    Custodian.initialize,
                    (address(this), custodianId, baseAsset_, quoteAsset_)
                )
            )
        );

        custodians[custodianId] = custody;
        custodianIds[custody] = custodianId;

        emit CustodyDeployed(custodyKind, custody, owner_, address(baseAsset_), address(quoteAsset_));
    }

    /// @notice Withdraw ETH or ERC20 held by the treasury.
    function withdraw(address asset, address to, uint256 amount) public onlyOwner {
        if (to == address(0)) revert ToZero();
        if (amount == 0) revert AmountZero();

        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }

        emit Withdraw(asset, to, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
