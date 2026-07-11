// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Minimal multisig-style executor: role holder is `address(this)`, owners call `exec`.
contract MockMultisig {
    address[] internal _owners;
    uint256 internal _threshold;

    constructor(address[] memory owners_, uint256 threshold_) {
        require(owners_.length > 0, "no owners");
        require(threshold_ > 0 && threshold_ <= owners_.length, "bad threshold");
        _owners = owners_;
        _threshold = threshold_;
    }

    function owners() external view returns (address[] memory) {
        return _owners;
    }

    function threshold() external view returns (uint256) {
        return _threshold;
    }

    function exec(address target, bytes calldata data) external returns (bytes memory result) {
        require(_isOwner(msg.sender), "not owner");
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            if (ret.length > 0) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
            revert("exec failed");
        }
        return ret;
    }

    function _isOwner(address account) private view returns (bool) {
        uint256 len = _owners.length;
        for (uint256 i; i < len;) {
            if (_owners[i] == account) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
