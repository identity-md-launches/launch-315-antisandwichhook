// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AntiSandwichHook} from "../../src/AntiSandwichHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookFlags} from "../../src/HookFlags.sol";

/// @dev Uses real CREATE2 and constructor validation; never etches a hook address.
abstract contract HookDeployment {
    function deployHook(IPoolManager manager) internal returns (AntiSandwichHook hook) {
        bytes32 initHash = keccak256(abi.encodePacked(type(AntiSandwichHook).creationCode, abi.encode(manager)));
        for (uint256 i = 0; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
            if (HookFlags.matches(predicted, HookFlags.NOSAND_FLAGS)) {
                hook = new AntiSandwichHook{salt: salt}(manager);
                require(address(hook) == predicted);
                return hook;
            }
        }
        revert("salt not found");
    }
}
