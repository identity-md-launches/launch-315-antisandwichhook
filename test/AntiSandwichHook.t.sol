// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AntiSandwichHook} from "../src/AntiSandwichHook.sol";
import {NOSAND} from "../src/NOSAND.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {BaseHook} from "openzeppelin-uniswap-hooks/src/base/BaseHook.sol";
import {HookDeployment} from "./helpers/HookDeployment.sol";
import {FactoryRehearsal} from "./helpers/FactoryRehearsal.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

abstract contract HookTestBase is Test, HookDeployment {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 constant Q96 = 79228162514264337593543950336;
    IPoolManager manager;
    AntiSandwichHook hook;
    NOSAND token;
    PoolSwapTest router;
    PoolModifyLiquidityTest lp;
    PoolKey key;

    function setUp() public virtual {
        vm.roll(10);
        vm.deal(address(this), 1_000_000 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = deployHook(manager);
        token = new NOSAND();
        router = new PoolSwapTest(manager);
        lp = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(lp), type(uint256).max);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, Q96);
        add(key, -60000, 60000, 1000 ether);
    }

    receive() external payable {}

    function add(PoolKey memory k, int24 low, int24 high, int256 amount) internal {
        lp.modifyLiquidity{value: 20_000 ether}(k, ModifyLiquidityParams(low, high, amount, bytes32(0)), "");
    }

    function swap(PoolKey memory k, bool buy, int256 amount) internal returns (BalanceDelta) {
        return swapLimit(k, buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function swapLimit(PoolKey memory k, bool buy, int256 amount, uint160 limit) internal returns (BalanceDelta) {
        return router.swap{value: buy ? 20_000 ether : 0}(
            k, SwapParams(buy, amount, limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }
}

contract AntiSandwichHookTest is HookTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_permissionsAndConstructorValidation() public {
        Hooks.Permissions memory expected;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0xC4);
        // A normal CREATE address does not carry the required flags.
        vm.expectRevert();
        new AntiSandwichHook(manager);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_allCallbacksAndUnlockRefuseDirectCallers() public {
        SwapParams memory p = SwapParams(true, -1, Q96 / 2);
        ModifyLiquidityParams memory m = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        bytes[11] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), key, Q96)),
            abi.encodeCall(IHooks.afterInitialize, (address(this), key, Q96, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, m, "")),
            abi.encodeCall(
                IHooks.afterAddLiquidity,
                (address(this), key, m, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, "")
            ),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, m, "")),
            abi.encodeCall(
                IHooks.afterRemoveLiquidity,
                (address(this), key, m, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, "")
            ),
            abi.encodeCall(IHooks.beforeSwap, (address(this), key, p, "")),
            abi.encodeCall(IHooks.afterSwap, (address(this), key, p, BalanceDeltaLibrary.ZERO_DELTA, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(AntiSandwichHook.unlockCallback, (abi.encode(key)))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory result) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(BaseHook.NotPoolManager.selector));
        }
    }

    function test_factoryLaunchFirstBuyUnderOneMillionGas() public {
        // Fresh manager is essential: it must contain no ETH from other pools.
        IPoolManager freshManager = IPoolManager(address(new PoolManager(address(this))));
        AntiSandwichHook freshHook = deployHook(freshManager);
        FactoryRehearsal factory = new FactoryRehearsal(freshManager);
        (NOSAND freshToken, PoolKey memory freshKey) = factory.launch(IHooks(address(freshHook)));
        assertEq(address(freshManager).balance, 0);
        assertEq(freshManager.getLiquidity(freshKey.toId()), 0);
        PoolSwapTest freshRouter = new PoolSwapTest(freshManager);
        vm.cool(address(freshManager));
        vm.cool(address(freshHook));
        vm.cool(address(freshToken));
        vm.cool(address(freshRouter));
        uint256 beforeGas = gasleft();
        BalanceDelta delta = freshRouter.swap{value: 1 ether}(
            freshKey,
            SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("factory first buy gas", used);
        assertLt(used, 1_000_000);
        assertEq(delta.amount0(), -1 ether);
        assertGt(delta.amount1(), 0);
        assertEq(freshToken.balanceOf(address(this)), uint128(delta.amount1()));
        (uint256 b, uint160 price,,, uint16 copied) = freshHook.checkpoint(freshKey.toId());
        assertEq(b, block.number);
        assertEq(price, factory.LAUNCH_SQRT_PRICE_X96());
        assertEq(copied, 1);
    }

    function test_loneFreshBlockSellIsNotClipped() public {
        vm.recordLogs();
        BalanceDelta d = swap(key, false, -10 ether);
        assertGt(d.amount0(), 0);
        assertEq(clips(vm.getRecordedLogs(), key.currency0), 0);
        vm.roll(block.number + 1);
        vm.recordLogs();
        d = swap(key, false, 1 ether);
        assertEq(d.amount0(), 1 ether);
        assertEq(clips(vm.getRecordedLogs(), key.currency1), 0);
    }

    function test_exactInputSellClippedAndDonatedToLps() public {
        swap(key, true, -100 ether);
        (uint256 beforeGrowth,) = manager.getFeeGrowthGlobals(key.toId());
        vm.recordLogs();
        BalanceDelta d = swap(key, false, -10 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 clipped = clips(logs, key.currency0);
        assertGt(clipped, 0);
        (uint256 afterGrowth,) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(afterGrowth - beforeGrowth, clipped * (1 << 128) / 1000 ether);
        assertLe(uint128(d.amount0()), 10 ether);
        assertEq(hook.collected(key.toId(), key.currency0), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(donations(logs, key.currency0), clipped);
        assertSettled();
    }

    function test_exactOutputSellClipsTokenInput() public {
        swap(key, true, -100 ether);
        vm.recordLogs();
        BalanceDelta d = swap(key, false, 10 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 clipped = clips(logs, key.currency1);
        assertGt(clipped, 0);
        assertEq(d.amount0(), 10 ether);
        assertGe(-int256(d.amount1()), 10 ether);
        assertEq(donations(logs, key.currency1), clipped);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertSettled();
    }

    function test_buysBothModesHaveNoHookFee() public {
        vm.recordLogs();
        BalanceDelta a = swap(key, true, -1 ether);
        BalanceDelta b = swap(key, true, 1 ether);
        assertEq(a.amount0(), -1 ether);
        assertEq(b.amount1(), 1 ether);
        assertEq(clips(vm.getRecordedLogs(), key.currency0), 0);
        assertSettled();
    }

    function testFuzz_buySandwichCannotProfit(uint96 front, uint96 victim) public {
        uint256 frontAmount = bound(front, 1e9, 200 ether);
        uint256 victimAmount = bound(victim, 1e9, 200 ether);
        BalanceDelta a = swap(key, true, -int256(frontAmount));
        swap(key, true, -int256(victimAmount));
        BalanceDelta back = swap(key, false, -int256(a.amount1()));
        assertLe(uint128(back.amount0()), frontAmount);
        assertSettled();
    }

    function test_exactOutputBackrunCannotRecoverFrontBuySpend() public {
        address attacker = address(0xBAD);
        vm.deal(attacker, 20 ether);
        vm.startPrank(attacker);
        token.approve(address(router), type(uint256).max);
        router.swap{value: 20 ether}(
            key, SwapParams(true, -20 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        vm.stopPrank();
        swap(key, true, -100 ether);
        // Recovering even the original 20 ETH requires more NOSAND than the attacker bought.
        vm.expectRevert();
        vm.prank(attacker);
        router.swap(
            key, SwapParams(false, 20 ether, TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(attacker.balance, 0);
        assertSettled();
    }

    function testFuzz_sellPriceNeverBeatsOpeningPrice(uint96 buyAmount, uint96 sellAmount, bool exactOut) public {
        swap(key, true, -int256(bound(buyAmount, 1e9, 100 ether)));
        int256 amount = int256(bound(sellAmount, 1e9, 50 ether));
        BalanceDelta d = swap(key, false, exactOut ? amount : -amount);
        assertLe(int256(d.amount0()), -int256(d.amount1()));
        (uint256 b, uint160 price,, uint128 liquidity,) = hook.checkpoint(key.toId());
        assertEq(b, block.number);
        assertEq(price, Q96);
        assertEq(liquidity, 1000 ether);
        assertSettled();
    }

    function test_dustAndPartialFillsBothDirections() public {
        swap(key, true, -1);
        swap(key, false, -1);
        swap(key, true, 1);
        swap(key, false, 1);
        swap(key, true, -100 ether);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        // Limit below the checkpoint price must not be reused in the virtual quote.
        BalanceDelta d = swapLimit(key, false, -100 ether, price + price / 10_000);
        assertLt(-int256(d.amount1()), 100 ether);
        assertLe(int256(d.amount0()), -int256(d.amount1()));
        (price,,,) = manager.getSlot0(key.toId());
        d = swapLimit(key, false, 100 ether, price + price / 10_000);
        assertLt(d.amount0(), 100 ether);
        assertLe(int256(d.amount0()), -int256(d.amount1()));
        assertSettled();
    }

    function test_liquidityChangeDoesNotResetBaseline() public {
        swap(key, true, -100 ether);
        add(key, -60000, 60000, 5000 ether);
        BalanceDelta d = swap(key, false, -50 ether);
        assertLe(int256(d.amount0()), -int256(d.amount1()));
        (,,, uint128 liquidity,) = hook.checkpoint(key.toId());
        assertEq(liquidity, 1000 ether);
        add(key, -60000, 60000, -5500 ether);
        d = swap(key, false, 10 ether);
        assertLe(int256(d.amount0()), -int256(d.amount1()));
    }

    function test_zeroLiquidityRetainsClaimsThenPermissionlessDonation() public {
        PoolKey memory narrow = key;
        narrow.fee = 500;
        manager.initialize(narrow, Q96);
        add(narrow, -600, 600, 1000 ether);
        swap(narrow, true, -10 ether);
        vm.recordLogs();
        swapLimit(narrow, false, -100 ether, TickMath.getSqrtPriceAtTick(600));
        uint256 clipped = clips(vm.getRecordedLogs(), narrow.currency0);
        assertGt(clipped, 0);
        assertEq(manager.getLiquidity(narrow.toId()), 0);
        assertEq(hook.collected(narrow.toId(), narrow.currency0), clipped);
        assertEq(manager.balanceOf(address(hook), 0), clipped);
        hook.donateCollected(narrow);
        assertEq(manager.balanceOf(address(hook), 0), clipped);
        add(narrow, -600, 1200, 500 ether);
        (uint256 growth,) = manager.getFeeGrowthGlobals(narrow.toId());
        vm.prank(address(0xBEEF));
        hook.donateCollected(narrow);
        (uint256 afterGrowth,) = manager.getFeeGrowthGlobals(narrow.toId());
        assertEq(afterGrowth - growth, clipped * (1 << 128) / 500 ether);
        assertEq(hook.collected(narrow.toId(), narrow.currency0), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        hook.donateCollected(narrow);
        assertSettled();
    }

    function test_nonNativePoolIsUntouched() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 100_000 ether);
        other.approve(address(router), type(uint256).max);
        other.approve(address(lp), type(uint256).max);
        (Currency a, Currency b) = address(other) < address(token)
            ? (Currency.wrap(address(other)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(other)));
        PoolKey memory k = PoolKey(a, b, 3000, 60, IHooks(address(hook)));
        manager.initialize(k, Q96);
        add(k, -60000, 60000, 1000 ether);
        vm.recordLogs();
        swap(k, true, -10 ether);
        swap(k, false, -10 ether);
        swap(k, true, 1 ether);
        swap(k, false, 1 ether);
        assertEq(clips(vm.getRecordedLogs(), a), 0);
        (uint256 blockNumber, uint160 price,,,) = hook.checkpoint(k.toId());
        assertEq(blockNumber, 0);
        assertEq(price, 0);
        hook.donateCollected(k);
    }

    function test_largeTickMoveCheckpointIsCapped() public {
        swap(key, true, -3000 ether);
        vm.roll(block.number + 1);
        uint256 beforeGas = gasleft();
        swap(key, true, -1 ether);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("checkpoint after large move gas", used);
        assertLt(used, 3_000_000);
        (,,,, uint16 count) = hook.checkpoint(key.toId());
        assertEq(count, 100);
    }

    function test_poolIdIsolationAndInvalidDonationKey() public {
        swap(key, true, -100 ether);
        PoolKey memory second = key;
        second.fee = 500;
        manager.initialize(second, Q96 * 2);
        add(second, -60000, 60000, 1000 ether);
        swap(second, false, -1 ether);
        (, uint160 p1,,,) = hook.checkpoint(key.toId());
        (, uint160 p2,,,) = hook.checkpoint(second.toId());
        assertEq(p1, Q96);
        assertEq(p2, Q96 * 2);
        second.hooks = IHooks(address(0));
        vm.expectRevert(AntiSandwichHook.InvalidPool.selector);
        hook.donateCollected(second);
    }

    function test_runtimeHasNoEscapeHatches() public view {
        scan(address(hook).code);
        scan(address(token).code);
    }

    function test_bothSellModesMatchUnmovedReferencePool() public {
        PoolKey memory baselineKey = key;
        baselineKey.hooks = IHooks(address(0));
        manager.initialize(baselineKey, Q96);
        add(baselineKey, -60000, 60000, 1000 ether);
        uint256 snapshot = vm.snapshotState();
        BalanceDelta baseline = swap(baselineKey, false, -20 ether);
        swap(key, true, -100 ether);
        BalanceDelta result = swap(key, false, -20 ether);
        assertEq(result.amount0(), baseline.amount0());
        assertTrue(vm.revertToState(snapshot));
        baseline = swap(baselineKey, false, 20 ether);
        swap(key, true, -100 ether);
        result = swap(key, false, 20 ether);
        assertEq(result.amount1(), baseline.amount1());
    }

    function test_donateFailureDoesNotRevertSwapAndRetryBurnsClaims() public {
        swap(key, true, -100 ether);
        vm.mockCallRevert(address(manager), abi.encodeWithSelector(IPoolManager.donate.selector), "donation failed");
        vm.recordLogs();
        swap(key, false, -10 ether);
        uint256 clipped = clips(vm.getRecordedLogs(), key.currency0);
        assertGt(clipped, 0);
        assertEq(hook.collected(key.toId(), key.currency0), clipped);
        assertEq(manager.balanceOf(address(hook), 0), clipped);
        assertSettled();
        vm.clearMockedCalls();
        hook.donateCollected(key);
        assertEq(hook.collected(key.toId(), key.currency0), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertSettled();
    }

    function test_exactOutputZeroLiquidityEndRetainsTokenClaims() public {
        PoolKey memory narrow = key;
        narrow.fee = 500;
        manager.initialize(narrow, Q96);
        add(narrow, -600, 600, 1000 ether);
        swap(narrow, true, -10 ether);
        vm.recordLogs();
        swapLimit(narrow, false, 100 ether, TickMath.getSqrtPriceAtTick(600));
        uint256 clipped = clips(vm.getRecordedLogs(), narrow.currency1);
        assertGt(clipped, 0);
        assertEq(manager.getLiquidity(narrow.toId()), 0);
        assertEq(hook.collected(narrow.toId(), narrow.currency1), clipped);
        assertEq(manager.balanceOf(address(hook), narrow.currency1.toId()), clipped);
        add(narrow, -600, 1200, 500 ether);
        hook.donateCollected(narrow);
        assertEq(manager.balanceOf(address(hook), narrow.currency1.toId()), 0);
        assertEq(hook.collected(narrow.toId(), narrow.currency1), 0);
    }

    function test_emptyOpeningLiquidityCannotBypassExactOutputProtection() public {
        PoolKey memory empty = key;
        empty.fee = 500;
        manager.initialize(empty, TickMath.getSqrtPriceAtTick(600));
        add(empty, -600, 600, 1000 ether);
        swap(empty, true, -10 ether);
        // A zero-liquidity checkpoint has no executable sell: exact-in output is all clipped.
        BalanceDelta d = swap(empty, false, -1 ether);
        assertEq(d.amount0(), 0);
        // The analogous exact-output trade must refuse, rather than receive ETH at zero target input.
        vm.expectRevert();
        swap(empty, false, 1 ether);
        assertSettled();
        vm.roll(block.number + 1);
        d = swap(empty, false, 1 ether);
        assertEq(d.amount0(), 1 ether);
    }

    function test_invalidPriceLimitAndZeroSwapRevert() public {
        vm.expectRevert();
        swapLimit(key, true, -1 ether, Q96 + 1);
        vm.expectRevert();
        swap(key, false, 0);
    }

    function test_twoPoolsCannotDonateEachOthersClaims() public {
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, Q96);
        add(other, -60000, 60000, 1000 ether);
        swap(key, true, -100 ether);
        swap(other, true, -100 ether);
        vm.mockCallRevert(address(manager), abi.encodeWithSelector(IPoolManager.donate.selector), "defer");
        swap(key, false, -10 ether);
        swap(other, false, -10 ether);
        uint256 a = hook.collected(key.toId(), key.currency0);
        uint256 b = hook.collected(other.toId(), key.currency0);
        assertGt(a, 0);
        assertGt(b, 0);
        assertEq(manager.balanceOf(address(hook), 0), a + b);
        vm.clearMockedCalls();
        hook.donateCollected(key);
        assertEq(hook.collected(key.toId(), key.currency0), 0);
        assertEq(hook.collected(other.toId(), key.currency0), b);
        assertEq(manager.balanceOf(address(hook), 0), b);
        hook.donateCollected(other);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_jitLpReceivesItsDonationShare() public {
        // Records the requested design's JIT limitation for the independent reviewer.
        swap(key, true, -100 ether);
        PoolModifyLiquidityTest jit = new PoolModifyLiquidityTest(manager);
        token.approve(address(jit), type(uint256).max);
        jit.modifyLiquidity{value: 20_000 ether}(key, ModifyLiquidityParams(-60000, 60000, 9000 ether, bytes32(0)), "");
        vm.recordLogs();
        swap(key, false, -10 ether);
        uint256 clipped = clips(vm.getRecordedLogs(), key.currency0);
        BalanceDelta fees = jit.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, 0, bytes32(0)), "");
        assertGt(clipped, 0);
        // Native fees on a token-input sell come only from the hook donation.
        assertApproxEqAbs(uint128(fees.amount0()), clipped * 9 / 10, 1);
    }

    function scan(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function clips(Vm.Log[] memory logs, Currency currency) internal view returns (uint256 result) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook)
                    && logs[i].topics[0] == keccak256("Clipped(bytes32,uint256,address,uint256)")
            ) {
                assertEq(uint256(logs[i].topics[2]), block.number);
                if (address(uint160(uint256(logs[i].topics[3]))) == Currency.unwrap(currency)) {
                    result += abi.decode(logs[i].data, (uint256));
                }
            }
        }
    }

    function donations(Vm.Log[] memory logs, Currency currency) internal view returns (uint256 result) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook) && logs[i].topics[0] == keccak256("Donated(bytes32,address,uint256)")
                    && address(uint160(uint256(logs[i].topics[2]))) == Currency.unwrap(currency)
            ) result += abi.decode(logs[i].data, (uint256));
        }
    }

    function assertSettled() internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
    }
}
