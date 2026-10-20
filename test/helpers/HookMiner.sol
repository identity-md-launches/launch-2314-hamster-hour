// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @dev Test-only bounded CREATE2 search. Production salts are mined by the IMD deployer.
library HookMiner {
    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function find(address deployer, bytes32 initCodeHash, uint256 start)
        internal
        pure
        returns (address predicted, bytes32 salt)
    {
        for (uint256 i = start; i < start + 200_000; ++i) {
            salt = bytes32(i);
            predicted = predict(deployer, salt, initCodeHash);
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == Hooks.BEFORE_INITIALIZE_FLAG) {
                return (predicted, salt);
            }
        }
        revert("No valid hook salt in search range");
    }
}
