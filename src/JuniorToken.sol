// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Custodian} from "./Custodian.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IGRAI} from "./interfaces/IGRAI.sol";
import {IJuniorToken} from "./interfaces/IJuniorToken.sol";
import {GrinderArt} from "./GrinderArt.sol";

/// @title JuniorToken (implementation)
/// @notice Junior principal tranche (JT, ERC20) plus native custodian registry and capital routing.
/// @dev Interact via ERC1967Proxy only.
contract JuniorToken is IJuniorToken, ERC20Upgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    address public grai;

    /// @notice Junior-tranche NAV in USD (6 decimals). JT price ≈ `totalValue / totalSupply()`.
    uint256 public totalValue;

    uint256 public custodianCount;

    mapping(bytes32 custodianKind => address) public custodianImplementations;

    mapping(uint256 custodianId => address) public custodians;
    mapping(address custodian => uint256) public custodianIds;
    mapping(address custodian => address) public custodianOwners;
    mapping(address custodian => mapping(address asset => uint256)) public allocatedAmount;
    mapping(address custodian => mapping(address asset => uint256)) public yieldGenerated;

    mapping(address asset => uint256) public activeAmount;

    /// @dev Storage gap for future upgrades.
    uint256[36] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(address grai_) public initializer {
        if (grai_ == address(0)) revert ZeroAddress();

        __UUPSUpgradeable_init();
        __ERC20_init("Grinders Junior Token", "JT");

        grai = grai_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function isCustodian(address custodian) public view returns (bool) {
        return custodians[custodianIds[custodian]] == custodian;
    }

    /// @notice Grinder owner for custodian `custodianId` (ERC-721-compatible lookup by id).
    function ownerOf(uint256 custodianId) public view returns (address) {
        address custodian = custodians[custodianId];
        if (custodian == address(0)) revert CustodianNonexistent(custodianId);
        return custodianOwners[custodian];
    }

    /// @notice Mint JT when junior principal enters (`value` in USD, 6 decimals).
    function mint(address to, uint256 value) external returns (uint256 jtOut) {
        _onlyGrai();
        if (to == address(0)) revert ZeroAddress();
        if (value == 0) revert AmountZero();

        uint256 supply = totalSupply();
        if (supply == 0 || totalValue == 0) {
            jtOut = value;
        } else {
            jtOut = (value * supply) / totalValue;
        }
        if (jtOut == 0) revert AmountZero();

        totalValue += value;
        _mint(to, jtOut);
        emit JuniorMint(to, jtOut, value);
    }

    /// @notice Burn JT and reduce junior-tranche NAV (`valueOut` in USD, 6 decimals).
    function burn(address from, uint256 jtAmount) external returns (uint256 valueOut) {
        _onlyGrai();
        if (jtAmount == 0) revert AmountZero();

        uint256 supply = totalSupply();
        if (supply == 0) revert AmountZero();

        valueOut = (jtAmount * totalValue) / supply;
        totalValue -= valueOut;
        _burn(from, jtAmount);
        emit JuniorBurn(from, jtAmount, valueOut);
    }

    /// @notice Reduce junior-tranche NAV without burning JT (e.g. asset delist).
    function reduceValue(uint256 value) external {
        _onlyGrai();
        if (value == 0) revert AmountZero();
        if (value > totalValue) revert ValueExceedsNav();
        totalValue -= value;
        emit JuniorValueReduced(value);
    }

    function withdraw(address asset, address to, uint256 amount) external {
        _onlyGrai();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function allocate(address asset, address custodian, uint256 amount) external {
        _onlyAdmin();
        IGRAI graiContract = IGRAI(grai);
        if (custodian == address(0)) revert CustodianZero();
        if (amount == 0) revert AmountZero();
        if (!isCustodian(custodian)) revert UnknownCustodian();
        (bool exists,,,,,,) = graiContract.assets(asset);
        if (!exists) revert AssetUnknown();

        allocatedAmount[custodian][asset] += amount;
        activeAmount[asset] += amount;
        if (balance(asset) < amount) revert InsufficientReserve();
        if (asset == address(0)) {
            (bool ok,) = custodian.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(custodian, amount);
        }
        emit Allocate(asset, custodian, amount);
    }

    function deallocate(address asset, uint256 amount) external payable {
        address custodian = msg.sender;
        if (!isCustodian(custodian)) revert UnknownCustodian();
        if (amount == 0) revert AmountZero();

        uint256 allocated = allocatedAmount[custodian][asset];
        allocatedAmount[custodian][asset] = allocated > amount ? allocated - amount : 0;

        uint256 active = activeAmount[asset];
        activeAmount[asset] = active > amount ? active - amount : 0;

        (bool exists,,,,,,) = IGRAI(grai).assets(asset);
        if (!exists) revert AssetUnknown();

        if (asset == address(0)) {
            if (msg.value != amount) revert ValueMismatch();
        } else {
            if (msg.value != 0) revert UnexpectedValue();
            IERC20(asset).safeTransferFrom(custodian, address(this), amount);
        }

        emit Deallocate(asset, custodian, amount);
    }

    function recordYield(address custodian, address asset, uint256 yieldAmount) external {
        if (msg.sender != custodian || !isCustodian(custodian)) revert UnknownCustodian();
        if (yieldAmount == 0) revert AmountZero();
        yieldGenerated[custodian][asset] += yieldAmount;
    }

    function tokenURI(uint256 custodianId) public view returns (string memory) {
        address custodian = custodians[custodianId];
        if (custodian == address(0)) revert CustodianNonexistent(custodianId);
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(GrinderArt.tokenJson(custodianId, custodian, _custodianKind(custodian))))
        );
    }

    function setCustodianImplementation(bytes32 custodianKind, address implementation) public {
        _onlyAdmin();
        if (implementation == address(0)) revert ZeroAddress();
        bytes32 implKind = Custodian(payable(implementation)).custodianKind();
        if (implKind != custodianKind) revert CustodianKindMismatch(custodianKind, implKind);
        custodianImplementations[custodianKind] = implementation;
        emit CustodianImplementationUpdated(custodianKind, implementation);
    }

    /// @notice Deploy a custodian proxy and register it with `owner_`.
    function mintCustodian(bytes32 custodianKind, address owner_, IERC20 baseAsset_, IERC20 quoteAsset_)
        public
        returns (address custodian)
    {
        _onlyAdmin();
        if (owner_ == address(0)) revert OwnerZero();

        address impl = custodianImplementations[custodianKind];
        if (impl == address(0)) revert UnknownCustodianKind(custodianKind);
        bytes32 implKind = Custodian(payable(impl)).custodianKind();
        if (implKind != custodianKind) revert CustodianKindMismatch(custodianKind, implKind);

        uint256 custodianId = custodianCount;

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
        custodianOwners[custodian] = owner_;
        custodianCount = custodianId + 1;

        emit CustodianDeployed(custodianKind, custodian, owner_, address(baseAsset_), address(quoteAsset_));
    }

    function transferCustodianOwnership(address custodian, address newOwner) external {
        address currentOwner = custodianOwners[custodian];
        if (currentOwner == address(0)) revert UnknownCustodian();
        if (msg.sender != currentOwner) revert NotCustodianOwner(msg.sender);
        if (newOwner == address(0)) revert CustodianOwnerZero();
        custodianOwners[custodian] = newOwner;
        emit CustodianOwnershipTransferred(custodian, currentOwner, newOwner);
    }

    function _custodianKind(address custodian) internal view returns (bytes32 kind) {
        if (custodian == address(0)) return kind;
        if (custodian.code.length == 0) return bytes32(0);
        try Custodian(payable(custodian)).custodianKind() returns (bytes32 k) {
            return k;
        } catch {
            return kind;
        }
    }

    function _onlyGrai() private view {
        if (msg.sender != grai) revert NotGrai();
    }

    function _onlyAdmin() private view {
        if (grai.code.length == 0) {
            if (msg.sender != grai) revert NotAdmin();
        } else {
            IGRAI graiContract = IGRAI(grai);
            if (!IAccessControl(address(graiContract)).hasRole(graiContract.ADMIN_ROLE(), msg.sender)) {
                revert NotAdmin();
            }
        }
    }

    function _authorizeUpgrade(address) internal view override {
        bytes32 defaultAdminRole = AccessControlUpgradeable(grai).DEFAULT_ADMIN_ROLE();
        if (!IAccessControl(grai).hasRole(defaultAdminRole, msg.sender)) revert NotAdmin();
    }
}