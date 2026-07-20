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
    error InsufficientReserve();
    error CustodianNonexistent(uint256 custodianId);
    error CustodianAlreadyRegistered(uint256 custodianId);
    error GrindersMismatch();
    error NoLiquidation();
    error InvalidLiquidationRange(uint256 fromId, uint256 toId);
    error NotGrai();
    error SwapFailed();
    error Slippage();
    error TargetZero();
    error DataEmpty();

    event GraiTokenUpdate(address indexed graiToken);
    event Liquidate(uint256 fromId, uint256 toId, uint256 assets);
    event CustodianImplementationUpdated(bytes32 indexed custodianKind, address implementation);
    event CustodianDeployed(
        bytes32 indexed custodianKind,
        address indexed custodian,
        address indexed owner,
        address baseAsset,
        address quoteAsset
    );
    event CustodianRegistered(address indexed custodian, address indexed owner, uint256 indexed custodianId);
    event Allocate(address indexed asset, address indexed custodian, uint256 amount);
    event Deallocate(address indexed asset, address indexed custodian, uint256 amount);
    event IdleLiquidate(uint256 assets);

    /// @notice The GRAI token this yield pool backs.
    function grai() external view returns (IGRAI);

    function balance(address asset) external view returns (uint256);

    function custodianImplementations(bytes32 custodianKind) external view returns (address);
    function custodians(uint256 custodianId) external view returns (address);
    function custodianIds(address custodian) external view returns (uint256);
    /// @notice Registered NFT id for `account`, or `type(uint256).max` if not a custodian.
    function custodyIdOf(address account) external view returns (uint256);
    /// @notice Issuance ledger of `allocate` amounts (not a wallet balance / deallocate cap).
    function allocated(address custodian, address asset) external view returns (uint256);
    function totalAllocated(address asset) external view returns (uint256);

    function isCustodian(address custodian) external view returns (bool);

    function custodianKindOf(address custodian) external view returns (bytes32);

    function set(bytes32 custodianKind, address implementation) external;
    function mint(bytes32 custodianKind, address baseAsset_, address quoteAsset_, address owner_)
        external
        returns (address custodian);
    function register(address custodian, address owner_) external;
    function allocate(address custodian, address asset, uint256 amount) external;
    /// @notice Custodian returns `amount` of `asset`. Not capped by `allocated` (post-swap inventory).
    function deallocate(address asset, uint256 amount) external payable;

    /// @notice Permissionless while `grai.liquidation()`: liquidate custodians `[fromId, toId)` and transfer swept amounts to GRAI.
    function liquidate(uint256 fromId, uint256 toId) external;

    /// @notice Permissionless while `grai.liquidation()`: transfer all listed idle assets to GRAI.
    function liquidate() external;

    /// @notice Execute a GRAI buyback against settlement inventory held here (GRAI-only caller).
    /// @dev `data` = `abi.encode(target, swapCalldata)`. Swap logic is upgradeable on Grinders;
    ///      GRAI only forwards settlement and accounts for the returned GRAI balance delta.
    function buyback(bytes calldata data) external returns (uint256 payment, uint256 graiOut);
}
