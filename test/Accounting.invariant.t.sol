// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./AntiSandwichHook.t.sol";
import {AntiSandwichHook} from "../src/AntiSandwichHook.sol";
import {NOSAND} from "../src/NOSAND.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract AccountingHandler is Test {
    PoolSwapTest public router;
    AntiSandwichHook public hook;
    PoolKey[2] internal keys;
    mapping(PoolId => mapping(Currency => uint256)) public totalClipped;
    mapping(PoolId => mapping(Currency => uint256)) public totalDonated;
    uint256 public successfulSwaps;

    constructor(PoolSwapTest router_, AntiSandwichHook hook_, NOSAND token, PoolKey memory a, PoolKey memory b) {
        router = router_;
        hook = hook_;
        keys[0] = a;
        keys[1] = b;
        token.approve(address(router), type(uint256).max);
    }

    receive() external payable {}

    function trade(uint256 pool, uint96 rawSize, bool buy, bool exactOutput) external {
        uint256 size = bound(rawSize, 1, 50 ether);
        int256 amount = exactOutput ? int256(size) : -int256(size);
        vm.recordLogs();
        // A depleted checkpoint can legitimately refuse exact output. Reverts are atomic.
        try router.swap{value: buy ? 100 ether : 0}(
            keys[pool % 2],
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            ++successfulSwaps;
        } catch {}
        record();
    }

    function donate(uint256 pool) external {
        vm.recordLogs();
        hook.donateCollected(keys[pool % 2]);
        record();
    }

    function nextBlock() external {
        vm.roll(block.number + 1);
    }

    function record() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(hook)) continue;
            if (l.topics[0] == keccak256("Clipped(bytes32,uint256,address,uint256)")) {
                totalClipped[
                    PoolId.wrap(l.topics[1])
                ][Currency.wrap(address(uint160(uint256(l.topics[3]))))] += abi.decode(l.data, (uint256));
            } else if (l.topics[0] == keccak256("Donated(bytes32,address,uint256)")) {
                totalDonated[
                    PoolId.wrap(l.topics[1])
                ][Currency.wrap(address(uint160(uint256(l.topics[2]))))] += abi.decode(l.data, (uint256));
            }
        }
    }
}

contract AccountingInvariantTest is HookTestBase {
    using TransientStateLibrary for IPoolManager;
    AccountingHandler handler;
    PoolKey second;

    function setUp() public override {
        super.setUp();
        // Remove the broad position; both pools can run out of in-range liquidity.
        add(key, -60000, 60000, -1000 ether);
        add(key, -600, 600, 1000 ether);
        second = key;
        second.fee = 500;
        manager.initialize(second, Q96);
        add(second, -600, 600, 1000 ether);
        handler = new AccountingHandler(router, hook, token, key, second);
        token.transfer(address(handler), 1_000_000 ether);
        vm.deal(address(handler), 1_000_000 ether);
        // Start with a real zero-liquidity exit and retained claims, so the invariant is non-vacuous.
        handler.trade(0, 10 ether, true, false);
        handler.trade(0, 50 ether, false, false);
        assertGt(hook.collected(key.toId(), key.currency0), 0);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = AccountingHandler.trade.selector;
        selectors[1] = AccountingHandler.donate.selector;
        selectors[2] = AccountingHandler.nextBlock.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_claimsEqualCollectedMinusDonatedAcrossPools() public view {
        checkCurrency(key.currency0);
        checkCurrency(key.currency1);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function checkCurrency(Currency currency) internal view {
        uint256 a = handler.totalClipped(key.toId(), currency) - handler.totalDonated(key.toId(), currency);
        uint256 b = handler.totalClipped(second.toId(), currency) - handler.totalDonated(second.toId(), currency);
        assertEq(hook.collected(key.toId(), currency), a);
        assertEq(hook.collected(second.toId(), currency), b);
        assertEq(manager.balanceOf(address(hook), currency.toId()), a + b);
        assertEq(manager.currencyDelta(address(hook), currency), 0);
    }
}
