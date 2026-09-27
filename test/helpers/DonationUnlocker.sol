// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AntiSandwichHook} from "../../src/AntiSandwichHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @dev Exercises donation during a caller-owned unlock, including rollback of that outer unlock.
contract DonationUnlocker is IUnlockCallback {
    IPoolManager immutable manager;
    error AbortDonation();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function run(AntiSandwichHook hook, PoolKey calldata key, bool abort) external {
        manager.unlock(abi.encode(hook, key, abort));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (AntiSandwichHook hook, PoolKey memory key, bool abort) = abi.decode(data, (AntiSandwichHook, PoolKey, bool));
        hook.donateCollected(key);
        if (abort) revert AbortDonation();
        return "";
    }
}
