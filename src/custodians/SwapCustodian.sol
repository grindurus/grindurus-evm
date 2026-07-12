// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Custodian} from "../Custodian.sol";

/// @title SwapCustodian (implementation)
/// @notice Junior-capital custody wallet with owner-gated arbitrary swap calls.
/// @dev Grinder builds off-chain calldata for a router/aggregator and executes it via `swap`.
///      A swap succeeds only when base/quote balances move in opposite directions and the
///      execution price `quote per 1 base` (18 decimals) satisfies `limitPrice`:
///      - sell base: `executionPrice >= limitPrice`
///      - buy base: `executionPrice <= limitPrice`
///      Proceeds remain on this contract; principal/yield still exit through `deallocate` / `distribute`.
///      Use the ERC1967Proxy address only, not the implementation.
contract SwapCustodian is Custodian {
    using SafeERC20 for IERC20;

    uint256 private constant PRICE_DECIMALS = 18;

    error TargetZero();
    error DataEmpty();
    error SwapFailed();
    error NotTradingAsset();
    error NoTrade();
    error ExceededPriceLimit();

    bytes32 private constant _CUSTODY_KIND =
        0xed402d39d17fde1cee5497b1836db076721aeed07c6337ad6f981559e69383ad; // keccak256("grindurus.custodian.explicit_swap")

    event Swap(
        address indexed target,
        uint256 baseDelta,
        uint256 quoteDelta,
        uint256 executionPrice,
        uint256 limitPrice,
        bytes result
    );

    /// @inheritdoc Custodian
    function custodianKind() public pure override returns (bytes32) {
        return _CUSTODY_KIND;
    }

    function initialize(
        address juniorToken_,
        IERC20 baseAsset_,
        IERC20 quoteAsset_
    ) public override initializer {
        __Custodian_init(juniorToken_, baseAsset_, quoteAsset_);
    }

    /// @notice Execute a low-level call to `target` and enforce a post-trade price limit.
    /// @param limitPrice Minimum `quote per 1 base` when selling base; maximum when buying base (18 decimals).
    /// @dev Only the Treasury NFT owner may call. ETH value is not forwarded; use WETH routers when needed.
    function swap(uint256 limitPrice, address target, bytes calldata data) external returns (bytes memory result) {
        _onlyOwner();
        if (target == address(0)) revert TargetZero();
        if (data.length == 0) revert DataEmpty();

        uint256 baseBefore = balance(address(baseAsset));
        uint256 quoteBefore = balance(address(quoteAsset));

        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert SwapFailed();

        uint256 baseAfter = balance(address(baseAsset));
        uint256 quoteAfter = balance(address(quoteAsset));

        uint256 baseDelta;
        uint256 quoteDelta;
        uint256 executionPrice;

        if (baseAfter < baseBefore && quoteAfter > quoteBefore) {
            baseDelta = baseBefore - baseAfter;
            quoteDelta = quoteAfter - quoteBefore;
            executionPrice = _quotePerBase(baseDelta, quoteDelta);
            if (executionPrice < limitPrice) revert ExceededPriceLimit();
        } else if (baseAfter > baseBefore && quoteAfter < quoteBefore) {
            baseDelta = baseAfter - baseBefore;
            quoteDelta = quoteBefore - quoteAfter;
            executionPrice = _quotePerBase(baseDelta, quoteDelta);
            if (executionPrice > limitPrice) revert ExceededPriceLimit();
        } else {
            revert NoTrade();
        }

        emit Swap(target, baseDelta, quoteDelta, executionPrice, limitPrice, ret);
        return ret;
    }

    /// @notice Approve a router/spender for a trading asset before `swap`.
    function approve(IERC20 token, address spender, uint256 amount) external {
        _onlyOwner();
        if (token != baseAsset && token != quoteAsset) revert NotTradingAsset();
        token.forceApprove(spender, amount);
    }

    function _quotePerBase(uint256 baseDelta, uint256 quoteDelta) internal view returns (uint256) {
        uint8 baseDec = IERC20Metadata(address(baseAsset)).decimals();
        uint8 quoteDec = IERC20Metadata(address(quoteAsset)).decimals();
        return (quoteDelta * (10 ** PRICE_DECIMALS) * (10 ** baseDec)) / (baseDelta * (10 ** quoteDec));
    }
}
