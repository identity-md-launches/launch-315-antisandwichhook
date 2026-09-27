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
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract SandwichHandler is Test {
    using StateLibrary for IPoolManager;
    PoolSwapTest immutable router;
    AntiSandwichHook immutable hook;
    NOSAND immutable token;
    IPoolManager immutable manager;
    PoolKey internal key;
    address public constant VICTIM = address(0xB1C71);
    uint256 public rounds;
    uint256 public spent;
    uint256 public received;
    uint256 public clipped;
    uint256 public donated;

    constructor(PoolSwapTest router_, AntiSandwichHook hook_, NOSAND token_, PoolKey memory key_) {
        router = router_;
        hook = hook_;
        token = token_;
        manager = hook_.poolManager();
        key = key_;
        token.approve(address(router), type(uint256).max);
    }

    receive() external payable {}

    /// @dev The handler is the attacker. Each action liquidates all acquired tokens, then the next
    /// action starts from the previous action's resulting pool state. Unexpected reverts fail the run.
    function roundTrip(uint96 frontSize, uint96 victimSize) external {
        uint256 front = bound(frontSize, 1e9, 2 ether);
        uint256 middle = bound(victimSize, 1e9, 20 ether);
        assertEq(token.balanceOf(address(this)), 0);
        uint256 ethBefore = address(this).balance;
        vm.roll(vm.getBlockNumber() + 1);
        uint256 sameBlock = vm.getBlockNumber();
        (uint160 openingPrice, int24 openingTick,,) = manager.getSlot0(key.toId());
        uint128 openingLiquidity = manager.getLiquidity(key.toId());
        vm.recordLogs();
        router.swap{value: front}(
            key,
            SwapParams(true, -int256(front), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 inventory = token.balanceOf(address(this));
        assertGt(inventory, 0);
        vm.prank(VICTIM);
        router.swap{value: middle}(
            key,
            SwapParams(true, -int256(middle), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        BalanceDelta back = router.swap(
            key,
            SwapParams(false, -int256(inventory), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        record();
        assertEq(vm.getBlockNumber(), sameBlock);
        assertEq(token.balanceOf(address(this)), 0);
        assertLe(address(this).balance, ethBefore, "profitable same-block round trip");
        assertEq(address(this).balance, ethBefore - front + uint128(back.amount0()));
        (uint256 b, uint160 price, int24 tick, uint128 liquidity,) = hook.checkpoint(key.toId());
        assertEq(b, sameBlock);
        assertEq(price, openingPrice, "sell quote mutated the checkpoint price");
        assertEq(tick, openingTick);
        assertEq(liquidity, openingLiquidity);
        ++rounds;
        spent += front;
        received += uint128(back.amount0());
    }

    function retryDonation() external {
        vm.recordLogs();
        hook.donateCollected(key);
        record();
    }

    function record() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(hook)) continue;
            if (l.topics[0] == keccak256("Clipped(bytes32,uint256,address,uint256)")) {
                assertEq(l.topics[1], PoolId.unwrap(key.toId()));
                assertEq(uint256(l.topics[2]), vm.getBlockNumber());
                assertEq(l.topics[3], bytes32(0));
                clipped += abi.decode(l.data, (uint256));
            } else if (l.topics[0] == keccak256("Donated(bytes32,address,uint256)")) {
                assertEq(l.topics[1], PoolId.unwrap(key.toId()));
                assertEq(l.topics[2], bytes32(0));
                donated += abi.decode(l.data, (uint256));
            }
        }
    }
}

contract SandwichInvariantTest is HookTestBase {
    using TransientStateLibrary for IPoolManager;
    SandwichHandler handler;
    uint256 constant ATTACKER_FUNDS = 100_000 ether;

    function setUp() public override {
        super.setUp();
        handler = new SandwichHandler(router, hook, token, key);
        vm.deal(address(handler), ATTACKER_FUNDS);
        vm.deal(handler.VICTIM(), 100_000 ether);
        // Make assertions non-vacuous even when a generated sequence only retries donations.
        handler.roundTrip(uint96(1 ether), uint96(10 ether));
        assertGt(handler.clipped(), 0);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = SandwichHandler.roundTrip.selector;
        selectors[1] = SandwichHandler.retryDonation.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_attackerCannotProfitAndAllClipsReachLps() public view {
        assertGt(handler.rounds(), 0);
        assertGt(handler.clipped(), 0);
        assertLe(handler.received(), handler.spent());
        assertEq(address(handler).balance, ATTACKER_FUNDS - handler.spent() + handler.received());
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(handler.clipped(), handler.donated());
        assertEq(hook.collected(key.toId(), key.currency0), 0);
        assertEq(hook.collected(key.toId(), key.currency1), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}
