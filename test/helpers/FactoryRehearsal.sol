// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NOSAND} from "../../src/NOSAND.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @dev Factory-shaped deploy -> initialize -> one-sided seed; no environment or external RPC.
contract FactoryRehearsal is IUnlockCallback {
    uint160 public constant LAUNCH_SQRT_PRICE_X96 = 79228162514264337593543950336000;
    int24 public constant LOWER = -887220;
    int24 public constant UPPER = 138120;
    uint256 public constant SEED = 900_000_000 ether;
    IPoolManager public immutable manager;
    NOSAND public token;
    PoolKey public key;
    uint128 public liquidity;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(IHooks hook) external returns (NOSAND, PoolKey memory) {
        require(address(token) == address(0));
        token = new NOSAND();
        require(token.balanceOf(address(this)) == 1_000_000_000 ether);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, hook);
        manager.initialize(key, LAUNCH_SQRT_PRICE_X96);
        liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(UPPER), SEED
        );
        manager.unlock("");
        return (token, key);
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key, ModifyLiquidityParams(LOWER, UPPER, int256(uint256(liquidity)), bytes32(0)), ""
        );
        require(delta.amount0() == 0 && delta.amount1() < 0, "seed must be NOSAND only");
        manager.sync(key.currency1);
        token.transfer(address(manager), uint256(-int256(delta.amount1())));
        manager.settle();
        return "";
    }
}
