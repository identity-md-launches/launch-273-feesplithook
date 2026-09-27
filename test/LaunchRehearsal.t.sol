// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {THRW} from "../src/THRW.sol";
import {FeeSplitHook} from "../src/FeeSplitHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {LaunchParameters} from "../script/LaunchParameters.sol";
import {LaunchFactory} from "./helpers/LaunchFactory.sol";
import {HookMiner} from "./helpers/HookMiner.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract LaunchRehearsalTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager private manager;
    LaunchFactory private factory;
    FeeSplitHook private hook;
    THRW private token;
    PoolSwapTest private router;
    PoolKey private key;

    function setUp() public {
        vm.chainId(LaunchParameters.CHAIN_ID);
        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new LaunchFactory(manager);
        (bytes32 salt, address expected) = HookMiner.find(address(factory), manager);
        key = factory.launch(salt);
        hook = factory.hook();
        token = factory.token();
        assertEq(address(hook), expected);
        assertEq(HookFlags.flagsOf(address(hook)), 0x00CC);
        router = new PoolSwapTest(manager);
        token.approve(address(router), type(uint256).max);
        vm.deal(address(this), 100 ether);
    }

    function test_factoryReceivesSupplyAndSeedsWithoutETH() public view {
        assertEq(factory.supplyReceived(), 1_000_000_000 ether);
        assertEq(address(manager).balance, 0);
        assertEq(address(factory).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(hook.totalPending(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertGt(factory.seededTokens(), 999_999_999 ether);
        assertEq(token.balanceOf(address(manager)), factory.seededTokens());
        assertEq(token.balanceOf(address(factory)) + factory.seededTokens(), token.totalSupply());
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, LaunchParameters.SQRT_PRICE_X96);
        assertEq(manager.getLiquidity(key.toId()), 0, "one-sided position lies below starting price");
    }

    function test_firstExactInputBuyThenAllModesAndPayouts() public {
        assertEq(address(manager).balance, 0);
        BalanceDelta buy = _swap(true, -1 ether);
        assertEq(buy.amount0(), -1 ether);
        assertGt(buy.amount1(), 0);
        assertEq(address(manager).balance, 1 ether);
        assertEq(hook.totalPending(), 0.01 ether);
        assertGt(manager.getLiquidity(key.toId()), 0);
        assertEq(_swap(true, 1_000_000 ether).amount1(), 1_000_000 ether);
        assertEq(_swap(false, -1_000_000 ether).amount1(), -1_000_000 ether);
        assertEq(_swap(false, 0.001 ether).amount0(), 0.001 ether);
        assertEq(manager.balanceOf(address(hook), 0), hook.totalPending());
        hook.donateAccrued(key);
        hook.burnAccrued();
        hook.claim();
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.totalPending(), 0);
        assertEq(address(hook).balance, 0);
    }

    function test_firstExactOutputBuyIntoETHLessPool() public {
        assertEq(address(manager).balance, 0);
        BalanceDelta delta = _swap(true, 10_000_000 ether);
        assertEq(delta.amount1(), 10_000_000 ether);
        uint256 paid = uint256(-int256(delta.amount0()));
        uint256 fee = manager.balanceOf(address(hook), 0);
        assertGt(fee, 0);
        assertEq(fee, (paid - fee) / 100);
        assertEq(address(manager).balance, paid);
        assertEq(fee, hook.totalPending());
    }

    function test_runtimeHasNoEscapeHatches() public view {
        _scan(address(token).code);
        _scan(address(hook).code);
    }

    function _scan(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff);
        }
    }

    function _swap(bool buy, int256 amount) private returns (BalanceDelta) {
        return router.swap{value: buy ? 2 ether : 0}(
            key,
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(this))
        );
    }

    receive() external payable {}
}
