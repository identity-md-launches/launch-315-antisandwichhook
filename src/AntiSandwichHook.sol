// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AntiSandwichHook as OZAntiSandwichHook} from "openzeppelin-uniswap-hooks/src/general/AntiSandwichHook.sol";
import {BaseHook} from "openzeppelin-uniswap-hooks/src/base/BaseHook.sol";
import {BaseDynamicAfterFee} from "openzeppelin-uniswap-hooks/src/fee/BaseDynamicAfterFee.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice OpenZeppelin v1.2 anti-sandwich pricing for native-ETH currency0 pools.
/// @dev See docs/DESIGN.md for the bounded checkpoint and partial-fill adaptations.
contract AntiSandwichHook is OZAntiSandwichHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant MAX_CHECKPOINT_TICKS = 100;

    // Separate storage is necessary because the upstream checkpoint mapping is private.
    struct BlockCheckpoint {
        uint256 blockNumber;
        bool initialized;
        uint16 ticksCopied;
        Pool.State state;
    }

    mapping(PoolId => BlockCheckpoint) private _checkpoints;
    mapping(PoolId => mapping(Currency => uint256)) public collected;

    event Clipped(PoolId indexed poolId, uint256 indexed blockNumber, Currency indexed currency, uint256 amount);
    event Donated(PoolId indexed poolId, Currency indexed currency, uint256 amount);

    error InvalidPool();
    error CheckpointCannotFillExactOutput();

    /// @dev BaseHook's constructor calls Hooks.validateHookPermissions on this deployment address.
    constructor(IPoolManager manager) BaseHook(manager) {}

    /// @notice The state immediately preceding this pool's first swap of its latest active block.
    function checkpoint(PoolId id)
        external
        view
        returns (uint256 blockNumber, uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint16 ticksCopied)
    {
        BlockCheckpoint storage cp = _checkpoints[id];
        return
            (cp.blockNumber, cp.state.slot0.sqrtPriceX96(), cp.state.slot0.tick(), cp.state.liquidity, cp.ticksCopied);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool first = false;
        if (key.currency0.isAddressZero()) {
            PoolId id = key.toId();
            BlockCheckpoint storage cp = _checkpoints[id];
            first = !cp.initialized || cp.blockNumber != block.number;
            if (first) {
                _checkpoint(key, id, cp);
            }
        }
        // Use the upstream transient target machinery, bypassing its unbounded checkpoint loop.
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            BaseDynamicAfterFee._beforeSwap(sender, key, params, data);
        _setTransientApplyTarget(key.currency0.isAddressZero() && !params.zeroForOne && !first);
        return (selector, delta, fee);
    }

    function _checkpoint(PoolKey calldata key, PoolId id, BlockCheckpoint storage cp) private {
        Slot0 current = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(id)));
        int24 currentTick = current.tick();
        // Required launch fix: never walk from the default tick zero on an empty checkpoint.
        int24 lastTick = cp.initialized ? cp.state.slot0.tick() : currentTick;
        cp.state.slot0 = current;
        cp.blockNumber = block.number;
        cp.initialized = true;
        int256 step = currentTick < lastTick ? int256(key.tickSpacing) : -int256(key.tickSpacing);
        uint16 count = 0;
        // Required gas bound: copy at most the 100 steps nearest the current tick.
        for (int256 tick = currentTick; count < MAX_CHECKPOINT_TICKS; tick += step) {
            if (step > 0 ? tick > lastTick : tick < lastTick) break;
            _copyTick(cp.state, id, int24(tick));
            ++count;
        }
        cp.ticksCopied = count;
        (cp.state.feeGrowthGlobal0X128, cp.state.feeGrowthGlobal1X128) = poolManager.getFeeGrowthGlobals(id);
        cp.state.liquidity = poolManager.getLiquidity(id);
    }

    function _copyTick(Pool.State storage state, PoolId id, int24 tick) private {
        Pool.TickInfo storage info = state.ticks[tick];
        (info.liquidityGross, info.liquidityNet, info.feeGrowthOutside0X128, info.feeGrowthOutside1X128) =
            poolManager.getTickInfo(id, tick);
    }

    /// @dev Quote after the real leg, using its filled specified amount (important for partial fills).
    function _getTargetUnspecified(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (uint256, bool)
    {
        return (0, false);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) internal override returns (bytes4, int128) {
        if (_transientApplyTarget()) {
            int256 specified = params.amountSpecified < 0 ? int256(delta.amount1()) : int256(delta.amount0());
            _setTransientTargetUnspecifiedAmount(_quote(key, specified));
        }
        return super._afterSwap(sender, key, params, delta, data);
    }

    function _quote(PoolKey calldata key, int256 specified) private returns (uint256) {
        Pool.State storage state = _checkpoints[key.toId()].state;
        if (specified == 0) return 0;
        // With no opening liquidity there is no executable baseline sell.
        if (state.liquidity == 0) {
            if (specified > 0) revert CheckpointCannotFillExactOutput();
            return 0;
        }
        Slot0 savedSlot = state.slot0;
        uint256 savedFeeGrowth = state.feeGrowthGlobal1X128;
        // As in OZ v1.2, this is a virtual constant-liquidity curve: no tick bitmap is populated.
        // The trader's price limit governs the real leg, not a different starting price in this quote.
        (BalanceDelta quoted,,,) = Pool.swap(
            state,
            Pool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: false,
                amountSpecified: specified,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1,
                lpFeeOverride: 0
            })
        );
        // Pool.swap writes storage despite upstream's comment saying it only calculates a result.
        // Restore it so the public checkpoint and each quote actually refer to the start of this block.
        state.slot0 = savedSlot;
        state.feeGrowthGlobal1X128 = savedFeeGrowth;
        if (specified > 0) {
            if (int256(quoted.amount0()) != specified) revert CheckpointCannotFillExactOutput();
            return uint256(-int256(quoted.amount1()));
        }
        return uint256(int256(quoted.amount0()));
    }

    function _afterSwapHandler(PoolKey calldata key, SwapParams calldata params, BalanceDelta, uint256, uint256 amount)
        internal
        override
    {
        Currency currency = params.amountSpecified < 0 ? key.currency0 : key.currency1;
        PoolId id = key.toId();
        collected[id][currency] += amount;
        emit Clipped(id, block.number, currency, amount);
        _donate(key);
    }

    /// @notice Permissionlessly donate retained claims to this pool's currently in-range LPs.
    /// @dev Supports both an ordinary external call and an already-open PoolManager unlock.
    function donateCollected(PoolKey calldata key) external {
        if (address(key.hooks) != address(this)) revert InvalidPool();
        if (!key.currency0.isAddressZero()) return;
        if (poolManager.isUnlocked()) _donate(key);
        else poolManager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        if (address(key.hooks) != address(this)) revert InvalidPool();
        _donate(key);
        return "";
    }

    function _donate(PoolKey memory key) private {
        PoolId id = key.toId();
        if (poolManager.getLiquidity(id) == 0) return;
        uint256 amount0 = collected[id][key.currency0];
        uint256 amount1 = collected[id][key.currency1];
        // Pool.donate accepts positive int128 amounts. Leave any excess for another call.
        uint256 limit = uint256(uint128(type(int128).max));
        if (amount0 > limit) amount0 = limit;
        if (amount1 > limit) amount1 = limit;
        if (amount0 == 0 && amount1 == 0) return;
        // A failed donate preserves the claims and cannot revert a swap.
        try poolManager.donate(key, amount0, amount1, "") returns (BalanceDelta) {
            if (amount0 != 0) {
                poolManager.burn(address(this), key.currency0.toId(), amount0);
                collected[id][key.currency0] -= amount0;
                emit Donated(id, key.currency0, amount0);
            }
            if (amount1 != 0) {
                poolManager.burn(address(this), key.currency1.toId(), amount1);
                collected[id][key.currency1] -= amount1;
                emit Donated(id, key.currency1, amount1);
            }
        } catch {}
    }
}
