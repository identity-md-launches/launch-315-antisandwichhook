// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./AntiSandwichHook.t.sol";
import {DonationUnlocker} from "./helpers/DonationUnlocker.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract SwapAccountingExtensionsTest is HookTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function testFuzz_exactOutputClipAddsLpGrowthAboveOrdinarySwapFees(uint96 buySize, uint96 sellSize) public {
        PoolKey memory control = key;
        control.hooks = IHooks(address(0));
        manager.initialize(control, Q96);
        add(control, -60000, 60000, 1000 ether);
        int256 buy = -int256(bound(buySize, 1 ether, 100 ether));
        int256 sell = int256(bound(sellSize, 1e12, 5 ether));
        swap(control, true, buy);
        swap(key, true, buy);
        BalanceDelta ordinary = swap(control, false, sell);
        vm.recordLogs();
        BalanceDelta protectedDelta = swap(key, false, sell);
        uint256 clip = clipped(vm.getRecordedLogs(), key, key.currency1);
        assertGt(clip, 0, "must exercise the hook fee");
        assertEq(protectedDelta.amount0(), ordinary.amount0());
        assertEq(int256(ordinary.amount1()) - int256(protectedDelta.amount1()), int256(clip));
        (uint256 ordinaryGrowth0, uint256 ordinaryGrowth1) = manager.getFeeGrowthGlobals(control.toId());
        (uint256 hookedGrowth0, uint256 hookedGrowth1) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(hookedGrowth0, ordinaryGrowth0);
        assertEq(hookedGrowth1 - ordinaryGrowth1, clip * (1 << 128) / 1000 ether);

        // Poke the positions and actually receive the donation, beyond observing a storage counter.
        ModifyLiquidityParams memory poke = ModifyLiquidityParams(-60000, 60000, 0, bytes32(0));
        BalanceDelta controlFees = lp.modifyLiquidity(control, poke, "");
        BalanceDelta hookedFees = lp.modifyLiquidity(key, poke, "");
        assertEq(hookedFees.amount0(), controlFees.amount0());
        assertApproxEqAbs(uint256(int256(hookedFees.amount1()) - int256(controlFees.amount1())), clip, 2);
        assertEq(hook.collected(key.toId(), key.currency1), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertSettled();
    }

    function test_deferredEthDonationWithinUnlockIsAtomicAndIdempotent() public {
        deferredDonation(false);
    }

    function test_deferredTokenDonationWithinUnlockIsAtomicAndIdempotent() public {
        deferredDonation(true);
    }

    function deferredDonation(bool exactOutput) internal {
        PoolKey memory narrow = key;
        narrow.fee = 500;
        manager.initialize(narrow, Q96);
        add(narrow, -600, 600, 1000 ether);
        swap(narrow, true, -10 ether);
        Currency currency = exactOutput ? narrow.currency1 : narrow.currency0;
        vm.recordLogs();
        BalanceDelta exitDelta = swapLimit(
            narrow, false, exactOutput ? int256(100 ether) : -int256(100 ether), TickMath.getSqrtPriceAtTick(600)
        );
        uint256 claim = clipped(vm.getRecordedLogs(), narrow, currency);
        assertGt(claim, 0);
        assertEq(manager.getLiquidity(narrow.toId()), 0);
        if (exactOutput) assertLt(exitDelta.amount0(), 100 ether, "exercise partial exact output");
        else assertLt(-int256(exitDelta.amount1()), 100 ether, "exercise partial exact input");
        assertEq(hook.collected(narrow.toId(), currency), claim);
        assertEq(manager.balanceOf(address(hook), currency.toId()), claim);
        DonationUnlocker unlocker = new DonationUnlocker(manager);
        unlocker.run(hook, narrow, false);
        hook.donateCollected(narrow);
        assertEq(hook.collected(narrow.toId(), currency), claim, "empty range retains all claims");
        add(narrow, -600, 1200, 500 ether);
        (uint256 before0, uint256 before1) = manager.getFeeGrowthGlobals(narrow.toId());
        vm.expectRevert(DonationUnlocker.AbortDonation.selector);
        unlocker.run(hook, narrow, true);
        assertEq(hook.collected(narrow.toId(), currency), claim);
        assertEq(manager.balanceOf(address(hook), currency.toId()), claim);
        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(narrow.toId());
        assertEq(after0, before0);
        assertEq(after1, before1);
        assertSettled();

        vm.recordLogs();
        vm.prank(address(0xCA11));
        unlocker.run(hook, narrow, false);
        assertEq(donated(vm.getRecordedLogs(), narrow, currency), claim);
        (after0, after1) = manager.getFeeGrowthGlobals(narrow.toId());
        uint256 growth = claim * (1 << 128) / 500 ether;
        assertEq(after0 - before0, exactOutput ? 0 : growth);
        assertEq(after1 - before1, exactOutput ? growth : 0);
        assertEq(hook.collected(narrow.toId(), currency), 0);
        assertEq(manager.balanceOf(address(hook), currency.toId()), 0);

        vm.recordLogs();
        hook.donateCollected(narrow);
        unlocker.run(hook, narrow, false);
        assertEq(donated(vm.getRecordedLogs(), narrow, currency), 0, "retry must not pay twice");
        (uint256 final0, uint256 final1) = manager.getFeeGrowthGlobals(narrow.toId());
        assertEq(final0, after0);
        assertEq(final1, after1);
        assertSettled();
    }

    function testFuzz_checkpointGasBoundInBothDirections(uint24 tickDistance, bool up) public {
        int24 distance = int24(int256(bound(tickDistance, 6060, 30000)));
        uint160 target = TickMath.getSqrtPriceAtTick(up ? distance : -distance);
        swapLimit(key, !up, -10_000 ether, target);
        (uint160 openingPrice, int24 openingTick,,) = manager.getSlot0(key.toId());
        assertEq(openingPrice, target);
        vm.roll(vm.getBlockNumber() + 1);
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(router));
        vm.cool(address(token));
        uint256 beforeGas = gasleft();
        swap(key, true, -1 ether);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("checkpoint swap gas after more than 100 tick spacings", used);
        assertLt(used, 3_000_000, "checkpoint call exceeds bounded gas budget");
        (uint256 b, uint160 cpPrice, int24 cpTick, uint128 liquidity, uint16 copied) = hook.checkpoint(key.toId());
        assertEq(b, vm.getBlockNumber());
        assertEq(cpPrice, openingPrice);
        assertEq(cpTick, openingTick);
        assertEq(liquidity, 1000 ether);
        assertEq(copied, 100);
        assertSettled();
    }

    function clipped(Vm.Log[] memory logs, PoolKey memory k, Currency currency) internal view returns (uint256 sum) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(hook) || l.topics[0] != keccak256("Clipped(bytes32,uint256,address,uint256)")) {
                continue;
            }
            assertEq(l.topics[1], PoolId.unwrap(k.toId()));
            assertEq(uint256(l.topics[2]), vm.getBlockNumber());
            assertEq(address(uint160(uint256(l.topics[3]))), Currency.unwrap(currency));
            sum += abi.decode(l.data, (uint256));
        }
    }

    function donated(Vm.Log[] memory logs, PoolKey memory k, Currency currency) internal view returns (uint256 sum) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(hook) || l.topics[0] != keccak256("Donated(bytes32,address,uint256)")) continue;
            assertEq(l.topics[1], PoolId.unwrap(k.toId()));
            assertEq(address(uint160(uint256(l.topics[2]))), Currency.unwrap(currency));
            sum += abi.decode(l.data, (uint256));
        }
    }

    function assertSettled() internal view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
    }
}
