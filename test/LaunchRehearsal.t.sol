// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookDeployment} from "./helpers/HookDeployment.sol";
import {FactoryRehearsal} from "./helpers/FactoryRehearsal.sol";
import {AntiSandwichHook} from "../src/AntiSandwichHook.sol";
import {NOSAND} from "../src/NOSAND.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Every test starts with a mined hook and an ETH-less manager, using the accepted factory fixture's
/// launch price and range. No RPC, relocated bytecode, storage edits, or environmental configuration.
contract LaunchRehearsalTest is Test, HookDeployment {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager manager;
    AntiSandwichHook hook;
    FactoryRehearsal factory;
    NOSAND token;
    PoolSwapTest router;
    PoolKey key;
    address attacker = address(0xA771);
    address victim = address(0xB1C7);

    function setUp() public {
        vm.roll(100);
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = deployHook(manager);
        factory = new FactoryRehearsal(manager);
        (token, key) = factory.launch(IHooks(address(hook)));
        router = new PoolSwapTest(manager);
        vm.deal(attacker, 1000 ether);
        vm.deal(victim, 1000 ether);
        vm.prank(attacker);
        token.approve(address(router), type(uint256).max);
        vm.prank(victim);
        token.approve(address(router), type(uint256).max);
        assertEq(address(manager).balance, 0, "seed must not borrow ETH from another pool");
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertGt(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(address(manager)), token.totalSupply());
    }

    function trade(address who, bool buy, int256 amount) internal returns (BalanceDelta) {
        vm.prank(who);
        return router.swap{value: buy ? 100 ether : 0}(
            key,
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function testFuzz_factoryFirstBuyBothModes(uint96 size, bool exactOutput) public {
        uint256 amount = exactOutput ? bound(size, 1, 10_000_000 ether) : bound(size, 1, 10 ether);
        uint256 ethBefore = victim.balance;
        BalanceDelta delta = trade(victim, true, exactOutput ? int256(amount) : -int256(amount));
        if (exactOutput) assertEq(uint128(delta.amount1()), amount);
        else assertEq(-int256(delta.amount0()), int256(amount));
        assertEq(victim.balance, ethBefore - uint256(-int256(delta.amount0())));
        assertEq(token.balanceOf(victim), uint128(delta.amount1()));
        assertEq(address(manager).balance, ethBefore - victim.balance);
        (uint256 b, uint160 price,, uint128 liquidity, uint16 copied) = hook.checkpoint(key.toId());
        assertEq(b, vm.getBlockNumber());
        assertEq(price, factory.LAUNCH_SQRT_PRICE_X96());
        assertEq(liquidity, 0);
        assertEq(copied, 1, "empty checkpoint must not walk from tick zero");
        assertSettled();
    }

    function test_firstExactOutputBuyGasAtLaunchPrice() public {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(router));
        vm.cool(address(token));
        uint256 beforeGas = gasleft();
        BalanceDelta delta = trade(victim, true, 1_000_000 ether);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("first exact-output buy at launch gas", used);
        assertLt(used, 1_000_000);
        assertEq(delta.amount1(), 1_000_000 ether);
        (,,,, uint16 copied) = hook.checkpoint(key.toId());
        assertEq(copied, 1);
        assertSettled();
    }

    function testFuzz_separateWalletSandwichAtLaunchAndLaterBlocks(uint96 front, uint96 middle, bool launchBlock)
        public
    {
        if (!launchBlock) {
            trade(victim, true, -50 ether);
            vm.roll(vm.getBlockNumber() + 1);
        }
        uint256 amount = bound(front, 1e12, 10 ether);
        uint256 victimAmount = bound(middle, 1e12, 20 ether);
        uint256 openingBalance = attacker.balance;
        uint256 sameBlock = vm.getBlockNumber();
        trade(attacker, true, -int256(amount));
        uint256 inventory = token.balanceOf(attacker);
        assertGt(inventory, 0);
        assertEq(attacker.balance, openingBalance - amount);
        trade(victim, true, -int256(victimAmount));
        BalanceDelta back = trade(attacker, false, -int256(inventory));
        assertEq(vm.getBlockNumber(), sameBlock);
        assertEq(token.balanceOf(attacker), 0, "round trip must liquidate the entire inventory");
        assertEq(attacker.balance, openingBalance - amount + uint128(back.amount0()));
        assertLe(attacker.balance, openingBalance, "attacker profited before gas");
        assertSettled();
    }

    function test_exactOutputLaunchSellFailureIsAtomicAndRetryWorksNextBlock() public {
        trade(attacker, true, -10 ether);
        trade(victim, true, -20 ether);
        bytes32 beforeState = stateDigest();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(AntiSandwichHook.CheckpointCannotFillExactOutput.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        trade(attacker, false, 1 ether);
        assertEq(stateDigest(), beforeState, "failed quote must undo price, fees, claims, and transfers");
        assertSettled();
        vm.roll(vm.getBlockNumber() + 1);
        vm.recordLogs();
        BalanceDelta delta = trade(attacker, false, 1 ether);
        assertEq(delta.amount0(), 1 ether);
        assertNoClips(vm.getRecordedLogs());
        assertSettled();
    }

    function testFuzz_exactOutputBackrunCannotRecoverSpend(uint96 front, uint96 middle) public {
        trade(victim, true, -50 ether);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 spend = bound(front, 1e12, 10 ether);
        trade(attacker, true, -int256(spend));
        trade(victim, true, -int256(bound(middle, 1e12, 20 ether)));
        bytes32 beforeState = stateDigest();
        // The hook charges the opening-curve input. The attacker owns only its front-run proceeds.
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        trade(attacker, false, int256(spend));
        assertEq(stateDigest(), beforeState, "settlement failure must roll back the hook donation too");
        assertSettled();
    }

    function testFuzz_loneSellAfterLaunchIsUnclipped(uint96 size, bool exactOutput) public {
        trade(attacker, true, -50 ether);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 amount = exactOutput ? bound(size, 1, 5 ether) : bound(size, 1, 5_000_000 ether);
        vm.recordLogs();
        BalanceDelta delta = trade(attacker, false, exactOutput ? int256(amount) : -int256(amount));
        if (exactOutput) assertEq(uint128(delta.amount0()), amount);
        else assertEq(-int256(delta.amount1()), int256(amount));
        assertNoClips(vm.getRecordedLogs());
        assertSettled();
    }

    function stateDigest() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        bytes32 poolState =
            keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1, manager.getLiquidity(key.toId())));
        (uint256 b, uint160 cpPrice, int24 cpTick, uint128 liq, uint16 copied) = hook.checkpoint(key.toId());
        return keccak256(
            abi.encode(
                poolState,
                b,
                cpPrice,
                cpTick,
                liq,
                copied,
                attacker.balance,
                token.balanceOf(attacker),
                address(manager).balance,
                token.balanceOf(address(manager)),
                hook.collected(key.toId(), key.currency0),
                hook.collected(key.toId(), key.currency1),
                manager.balanceOf(address(hook), 0),
                manager.balanceOf(address(hook), key.currency1.toId())
            )
        );
    }

    function assertNoClips(Vm.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook)) {
                assertTrue(logs[i].topics[0] != keccak256("Clipped(bytes32,uint256,address,uint256)"));
            }
        }
    }

    function assertSettled() internal view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
