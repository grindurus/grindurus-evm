// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IERC1046} from "./IERC1046.sol";

import {IGRAI} from "./IGRAI.sol";

interface IGrinders is IERC721Enumerable, IERC1046 {
    error ZeroAddress();
    error OwnerZero();
    error GraiTokenZero();
    error AmountZero();
    error EthTransferFailed();
    error ValueMismatch();
    error UnexpectedValue();
    error UnknownCustodianKind(bytes32 custodianKind);
    error CustodianKindMismatch(bytes32 expected, bytes32 actual);
    error CustodianZero();
    error UnknownCustodian();
    error NotCustodianOwner();
    error InsufficientReserve();
    error CustodianNonexistent(uint256 custodianId);
    error CustodianAlreadyRegistered(uint256 custodianId);
    error GrindersMismatch();
    error LiquidationNotConfirmed();
    error LiquidationNotOpen();
    error NotGrai();
    error InvalidLiquidationRange(uint256 fromId, uint256 toId);
    error InvalidCustodianRange(uint256 fromId, uint256 toId);

    /// @notice View row for `getCustodiansData`.
    struct CustodianData {
        address custodian;
        uint256 id;
        address owner;
        bytes32 kind;
        address baseAsset;
        address quoteAsset;
        uint256 ethBalance;
        uint256 baseBalance;
        uint256 quoteBalance;
    }

    event GraiTokenUpdate(address indexed graiToken);
    event Confirm(bool confirmed);
    event Liquidate(uint256 fromId, uint256 toId);
    event CustodianImplementationUpdated(bytes32 indexed custodianKind, address implementation);
    event CustodianDeployed(
        bytes32 indexed custodianKind,
        address indexed custodian,
        address indexed owner,
        address baseAsset,
        address quoteAsset
    );
    event CustodianRegistered(address indexed custodian, address indexed owner, uint256 indexed custodianId);
    event IdleLiquidate(uint256 assets);
    /// @notice Junior capital sent from Grinders to `custodian` (`asset == address(0)` = ETH).
    event Allocate(address indexed custodian, address indexed asset, uint256 amount);
    /// @notice Junior capital pulled from `custodian` back to Grinders (`asset == address(0)` = ETH).
    event Deallocate(address indexed custodian, address indexed asset, uint256 amount);

    /// @notice The GRAI token this yield pool backs.
    function grai() external view returns (IGRAI);

    /// @notice Grinders-owner limb of GRAI 2-of-2 liquidation (armed via `confirm`).
    function confirmed() external view returns (bool);

    /// @notice Whether linked GRAI reports open liquidation. Empty `grai` code or missing /
    ///         reverting `liquidation()` → `true` (no external gate). Else GRAI's flag.
    function liquidation() external view returns (bool);

    /// @notice Toggle liquidation arm. Only `owner()`.
    ///         Arm stays set through open/sweeps until `revive` or ownership accept.
    function confirm() external;

    /// @notice Clear the arm when GRAI closes liquidation. Only callable by the linked GRAI.
    function revive() external;

    function balance(address asset) external view returns (uint256);

    function custodianImplementations(bytes32 custodianKind) external view returns (address);
    function custodians(uint256 custodianId) external view returns (address);
    function custodianIds(address custodian) external view returns (uint256);
    /// @notice Registered NFT id for `account`, or `type(uint256).max` if not a custodian.
    function custodianIdOf(address account) external view returns (uint256);

    function isCustodian(address custodian) external view returns (bool);

    function custodianKindOf(address custodian) external view returns (bytes32);

    /// @notice Custodian snapshots for NFT ids in `[fromId, toId)` (`totalSupply` clipped).
    ///         Empty slots (`custodians[id] == 0`) return a zeroed row with that `id`.
    function getCustodiansData(uint256 fromId, uint256 toId) external view returns (CustodianData[] memory list);

    function set(bytes32 custodianKind, address implementation) external;
    /// @notice Retarget the linked GRAI core (liquidation checks / asset routing).
    function setGrai(address grai_) external;
    function mint(bytes32 custodianKind, address owner_, address baseAsset_, address quoteAsset_)
        external
        returns (address custodian);
    function register(address custodian, address owner_) external;
    /// @notice Protocol owner sets trading assets on a registered custodian.
    function setAssets(address custodian, address baseAsset_, address quoteAsset_) external;
    function allocate(address custodian, address asset, uint256 amount) external;
    /// @notice Protocol owner pulls `amount` of `asset` from `custodian`.
    function deallocate(address custodian, address asset, uint256 amount) external;
    /// @notice Protocol owner forwards yield `amount` of `asset` from `custodian` to GRAI.
    function distribute(address custodian, address asset, uint256 amount) external;

    /// @notice Permissionless while `confirmed` and `grai.liquidation()`: liquidate custodians
    ///         `[fromId, toId)` and transfer swept amounts to GRAI. GRAI opens by flipping
    ///         REDEMPTION before calling this; keepers re-page during consolidation under the same gates.
    function liquidate(uint256 fromId, uint256 toId) external;
}
