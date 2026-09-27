// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {THRW} from "../../src/THRW.sol";
import {FeeSplitHook} from "../../src/FeeSplitHook.sol";
import {HookMiner} from "./HookMiner.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

abstract contract HookTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant Q96 = 1 << 96;
    uint256 internal constant LIQUIDITY = 1_000_000 ether;
    bytes32 internal constant FEE_SPLIT_TOPIC =
        keccak256("FeeSplit(bytes32,address,uint256,uint256,uint256,uint256)");
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    IPoolManager internal manager;
    FeeSplitHook internal hook;
    THRW internal token;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal key;
    PoolKey internal secondKey;

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        (bytes32 salt, address predicted) = HookMiner.find(address(this), manager);
        hook = new FeeSplitHook{salt: salt}(manager);
        assertEq(address(hook), predicted);
        token = new THRW();
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
        vm.deal(address(this), 1_000_000 ether);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook))
        );
        secondKey = key;
        secondKey.fee = 500;
        _seed(key);
        _seed(secondKey);
    }

    function _seed(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, Q96);
        liquidityRouter.modifyLiquidity{value: 40_000 ether}(
            poolKey, ModifyLiquidityParams(-600, 600, int256(LIQUIDITY), 0), ""
        );
    }

    function _swap(PoolKey memory poolKey, bool buy, int256 amount, bytes memory data)
        internal
        returns (BalanceDelta delta)
    {
        return router.swap{value: buy ? 10 ether : 0}(
            poolKey,
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
    }

    function _assertClaims() internal view {
        assertEq(manager.balanceOf(address(hook), 0), hook.totalPending(), "claims == liabilities");
        assertEq(address(hook).balance, 0, "no ETH custody in hook");
        assertEq(hook.pendingLP(key.toId()) + hook.pendingLP(secondKey.toId()), hook.totalPendingLP());
        assertEq(hook.pendingBurn(key.toId()) + hook.pendingBurn(secondKey.toId()), hook.totalPendingBurn());
    }

    function _feeEvent(Vm.Log[] memory logs, PoolId id, address recipient, uint256 expectedFee)
        internal
        view
    {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != FEE_SPLIT_TOPIC) continue;
            ++count;
            assertEq(logs[i].topics[1], PoolId.unwrap(id));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(recipient))));
            (uint256 fee, uint256 interfaceShare, uint256 lpShare, uint256 burnShare) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(fee, expectedFee);
            assertEq(interfaceShare, recipient == address(0) ? 0 : fee * 20 / 100);
            assertEq(lpShare, fee * 30 / 100);
            assertEq(interfaceShare + lpShare + burnShare, fee);
        }
        assertEq(count, 1, "one FeeSplit per successful ETH-pool swap, including dust");
    }

    receive() external payable {}
}
