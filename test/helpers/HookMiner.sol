// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeeSplitHook} from "../../src/FeeSplitHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

library HookMiner {
    function find(address deployer, IPoolManager manager) internal pure returns (bytes32 salt, address hook) {
        bytes32 initHash = keccak256(abi.encodePacked(type(FeeSplitHook).creationCode, abi.encode(manager)));
        for (uint256 i; i < 1_000_000; ++i) {
            hook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initHash))))
            );
            if (HookFlags.matches(hook, HookFlags.FEE_SPLIT)) return (bytes32(i), hook);
        }
        revert("salt search exhausted");
    }
}
