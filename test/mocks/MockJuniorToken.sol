// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJuniorToken} from "../../src/interfaces/IJuniorToken.sol";

/// @dev Minimal JuniorToken stand-in for vault tests: JT mint/burn, custodian registry, allocate.
contract MockJuniorToken {
    address public grai;
    uint256 public totalValue;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) public custodians;
    mapping(address => uint256) public custodianIds;
    mapping(address custodian => mapping(address asset => uint256)) public allocatedAmount;
    mapping(address asset => uint256) public activeAmount;
    mapping(address custodian => mapping(address asset => uint256)) public yieldGenerated;
    mapping(address custodian => address) public custodianOwners;

    function setGrai(address grai_) external {
        grai = grai_;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 value) external returns (uint256 jtOut) {
        if (msg.sender != grai) revert IJuniorToken.NotGrai();
        if (to == address(0)) revert IJuniorToken.ZeroAddress();
        if (value == 0) revert IJuniorToken.AmountZero();

        uint256 supply = _totalSupply;
        if (supply == 0 || totalValue == 0) {
            jtOut = value;
        } else {
            jtOut = (value * supply) / totalValue;
        }
        if (jtOut == 0) revert IJuniorToken.AmountZero();

        totalValue += value;
        _totalSupply += jtOut;
        _balances[to] += jtOut;
    }

    function burn(address from, uint256 jtAmount) external returns (uint256 valueOut) {
        if (msg.sender != grai) revert IJuniorToken.NotGrai();
        if (jtAmount == 0) revert IJuniorToken.AmountZero();
        if (_totalSupply == 0) revert IJuniorToken.AmountZero();

        valueOut = (jtAmount * totalValue) / _totalSupply;
        totalValue -= valueOut;
        _totalSupply -= jtAmount;
        _balances[from] -= jtAmount;
    }

    function reduceValue(uint256 value) external {
        if (msg.sender != grai) revert IJuniorToken.NotGrai();
        if (value == 0) revert IJuniorToken.AmountZero();
        if (value > totalValue) revert IJuniorToken.ValueExceedsNav();
        totalValue -= value;
    }

    function withdraw(address asset, address to, uint256 amount) external {
        if (msg.sender != grai) revert IJuniorToken.NotGrai();
        if (to == address(0)) revert IJuniorToken.ZeroAddress();
        if (amount == 0) revert IJuniorToken.AmountZero();
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert IJuniorToken.EthTransferFailed();
        } else {
            IERC20(asset).transfer(to, amount);
        }
    }

    function setCustodianOwner(address custodian, address owner) external {
        custodianOwners[custodian] = owner;
    }

    function setCustodian(address custodian, uint256 custodianId) external {
        custodians[custodianId] = custodian;
        custodianIds[custodian] = custodianId;
    }

    function isCustodian(address custodian) external view returns (bool) {
        return custodians[custodianIds[custodian]] == custodian;
    }

    function ownerOf(uint256 custodianId) external view returns (address) {
        address custodian = custodians[custodianId];
        if (custodian == address(0)) revert IJuniorToken.CustodianNonexistent(custodianId);
        return custodianOwners[custodian];
    }

    function balance(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function allocate(address asset, address custodian, uint256 amount) external {
        if (custodians[custodianIds[custodian]] != custodian) revert IJuniorToken.UnknownCustodian();
        if (amount == 0) revert IJuniorToken.AmountZero();
        if (balance(asset) < amount) revert IJuniorToken.InsufficientReserve();
        allocatedAmount[custodian][asset] += amount;
        activeAmount[asset] += amount;
        if (asset == address(0)) {
            (bool ok,) = custodian.call{value: amount}("");
            if (!ok) revert IJuniorToken.EthTransferFailed();
        } else {
            IERC20(asset).transfer(custodian, amount);
        }
    }

    function deallocate(address asset, uint256 amount) external payable {
        address custodian = msg.sender;
        if (custodians[custodianIds[custodian]] != custodian) revert IJuniorToken.UnknownCustodian();
        if (amount == 0) revert IJuniorToken.AmountZero();

        uint256 allocated = allocatedAmount[custodian][asset];
        allocatedAmount[custodian][asset] = allocated > amount ? allocated - amount : 0;

        uint256 active = activeAmount[asset];
        activeAmount[asset] = active > amount ? active - amount : 0;

        if (asset == address(0)) {
            if (msg.value != amount) revert IJuniorToken.ValueMismatch();
        } else {
            if (msg.value != 0) revert IJuniorToken.UnexpectedValue();
            IERC20(asset).transferFrom(custodian, address(this), amount);
        }
    }

    function recordYield(address custodian, address asset, uint256 yieldAmount) external {
        if (msg.sender != custodian) revert IJuniorToken.UnknownCustodian();
        if (custodians[custodianIds[custodian]] != custodian) revert IJuniorToken.UnknownCustodian();
        if (yieldAmount == 0) revert IJuniorToken.AmountZero();
        yieldGenerated[custodian][asset] += yieldAmount;
    }

    receive() external payable {}
}
