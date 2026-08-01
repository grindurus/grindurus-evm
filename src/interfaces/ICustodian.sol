// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    error FeatureDelay();
    error NotGrinders(address caller);
    error EthTransferFailed();
    error LiquidationOpen();

    event SetAssets(address indexed baseAsset, address indexed quoteAsset);
    event Deallocate(address indexed asset, uint256 amount);
    event Distribute(address indexed asset, uint256 amount);
    event Liquidate(uint256 ethOut, uint256 baseOut, uint256 quoteOut);
    event UpgradesReenableScheduled(uint48 reenableAt);
    event UpgradesDisabled();
    event UpgradesReenabled();

    function initialize(address grinders_) external;
    function custodianKind() external view returns (bytes32);
    function grinders() external view returns (IGrinders);
    function baseAsset() external view returns (IERC20);
    function quoteAsset() external view returns (IERC20);
    function setAssets(address baseAsset_, address quoteAsset_) external;
    function deallocate(address asset, uint256 amount) external;
    function distribute(address asset, uint256 yieldAmount) external;
    function liquidate() external returns (uint256 ethOut, uint256 baseOut, uint256 quoteOut);
}
