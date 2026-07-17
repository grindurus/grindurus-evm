// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISeniorPool} from "./ISeniorPool.sol";

interface IHedgePool is IERC20, ISeniorPool {
    error ZeroAddress();
    error NotAdmin();
    error AmountZero();
    error InsufficientReserve();
    error InsufficientShares();
    error ValueMismatch();
    error UnexpectedValue();
    error EthTransferFailed();
    error DecimalsMismatch();
    error ClaimExceedsReserve();

    event Mint(address indexed underwriter, uint256 assets, uint256 shares);
    event Burn(address indexed underwriter, uint256 shares, uint256 assets);
    event Claim(address indexed from, uint256 graiAmount, uint256 hedgeOut);

    function balance() external view returns (uint256);
    function graiBalance() external view returns (uint256);

    /// @notice Hedge assets per share, scaled by `10 ** decimals()` (hedge asset decimals).
    function previewRate() external view returns (uint256);

    function previewMint(uint256 assets) external view returns (uint256 shares);
    function mint(uint256 assets) external payable returns (uint256 shares);

    function previewBurn(uint256 shares) external view returns (uint256 assets);
    function burn(uint256 shares) external returns (uint256 assets);

    function previewClaim(uint256 graiAmount) external view returns (uint256 hedgeOut);
    /// @notice Pull GRAI from caller; pay equivalent `hedgeAsset`.
    function claim(uint256 graiAmount) external returns (uint256 hedgeOut);
}
