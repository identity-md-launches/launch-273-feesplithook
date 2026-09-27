// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {THRW} from "../../src/THRW.sol";
import {FeeSplitHook} from "../../src/FeeSplitHook.sol";
import {LaunchParameters} from "../../script/LaunchParameters.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Local rehearsal of the supplied factory behavior, not the unpublished production factory source.
contract LaunchFactory is IUnlockCallback {
    IPoolManager public immutable manager;
    THRW public token;
    FeeSplitHook public hook;
    PoolKey public key;
    uint256 public supplyReceived;
    uint256 public seededTokens;
    uint256 public liquidity;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(bytes32 salt) external returns (PoolKey memory) {
        require(address(token) == address(0), "already launched");
        token = new THRW();
        supplyReceived = token.balanceOf(address(this));
        require(supplyReceived == token.totalSupply(), "supply mismatch");
        hook = new FeeSplitHook{salt: salt}(manager);
        key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(token)),
            LaunchParameters.POOL_FEE,
            LaunchParameters.TICK_SPACING,
            IHooks(address(hook))
        );
        manager.initialize(key, LaunchParameters.SQRT_PRICE_X96);
        liquidity = FullMath.mulDiv(
            LaunchParameters.SEED_THRW,
            1 << 96,
            TickMath.getSqrtPriceAtTick(LaunchParameters.TICK_UPPER)
                - TickMath.getSqrtPriceAtTick(LaunchParameters.TICK_LOWER)
        );
        manager.unlock("");
        return key;
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                LaunchParameters.TICK_LOWER, LaunchParameters.TICK_UPPER, int256(liquidity), 0
            ),
            ""
        );
        require(delta.amount0() == 0 && delta.amount1() < 0, "seed must be only THRW");
        seededTokens = uint256(-int256(delta.amount1()));
        manager.sync(key.currency1);
        require(token.transfer(address(manager), seededTokens));
        manager.settle();
        return "";
    }
}
