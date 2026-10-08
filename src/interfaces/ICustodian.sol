// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IGrinders} from "./IGrinders.sol";

interface ICustodian {
    error NotOwner(address caller);
    error GrindersZero();
    error AmountZero();
    error BaseZero();
    error QuoteZero();
    error SameAsset();
    error NonZeroBalance();
    error FeatureDisabled();
    error NotGrinders(address caller);
    error EthTransferFailed();
    error LiquidationOpen();
    /// @notice UUPS target is not the Grinders-registered implementation for this kind.
    error UnauthorizedImplementation(address implementation);

    event RegisterPending(address indexed previousGrinders, address indexed pendingGrinders);
    event RegisterApproved(address indexed grinders);
    event SetAssets(address indexed baseAsset, address indexed quoteAsset);
    event Deallocate(address indexed asset, uint256 amount);
    event Distribute(address indexed asset, uint256 amount);
    event Liquidate(uint256 ethOut, uint256 baseOut, uint256 quoteOut);

    function initialize(address grinders_) external;
    function custodianKind() external view returns (bytes32);
    function grinders() external view returns (IGrinders);
    function baseAsset() external view returns (address);
    function quoteAsset() external view returns (address);
    /// @notice 2-step grinders handoff: current `grinders` nominates; pending accepts with `register(self)`.
    function register(address newGrinders) external;
    function setAssets(address baseAsset_, address quoteAsset_) external;
    function deallocate(address asset, uint256 amount) external;
    function distribute(address asset, uint256 yieldAmount) external;
    function liquidate()
        external
        returns (address baseAsset, address quoteAsset, uint256 baseOut, uint256 quoteOut, uint256 ethOut);

    /// @notice USD NAV of base + quote balances (`USD_DECIMALS`).
    function nav() external view returns (uint256);
}
