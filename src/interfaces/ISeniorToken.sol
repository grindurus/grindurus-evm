// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISeniorToken is IERC20 {
    function grai() external view returns (address);

    function totalValue() external view returns (uint256);

    function balance(address asset) external view returns (uint256);

    function mint(address to, uint256 value) external returns (uint256 stOut);

    function accrueValue(uint256 value) external;

    function reduceValue(uint256 value) external;

    function burn(address from, uint256 stAmount) external returns (uint256 valueOut);

    function withdraw(address asset, address to, uint256 amount) external;
}
