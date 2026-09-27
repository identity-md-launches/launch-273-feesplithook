// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {FeeSplitHook} from "../src/FeeSplitHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract FeeSplitHookTest is HookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_exactPermissionsAndImmutableConstants() public view {
        Hooks.Permissions memory expected;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        expected.beforeSwapReturnDelta = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0x00CC);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.FEE_BPS(), 100);
        assertEq(hook.INTERFACE_BPS(), 2000);
        assertEq(hook.LP_BPS(), 3000);
        assertEq(hook.BURN_BPS(), 5000);
        assertEq(hook.BPS(), 10000);
        assertEq(hook.BURN_ADDRESS(), address(0xdead));
    }

    function test_constructorRejectsWrongFlagsAndZeroManager() public {
        bytes32 initHash = keccak256(abi.encodePacked(type(FeeSplitHook).creationCode, abi.encode(manager)));
        bytes32 salt;
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))))
        );
        assertTrue(HookFlags.flagsOf(predicted) != 0x00CC);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new FeeSplitHook{salt: salt}(manager);
        vm.expectRevert(FeeSplitHook.InvalidPoolManager.selector);
        new FeeSplitHook(IPoolManager(address(0)));
    }

    function test_allImplementedCallbacksRequireManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, Q96 / 2);
        vm.expectRevert(FeeSplitHook.NotPoolManager.selector);
        hook.beforeSwap(address(router), key, params, "");
        vm.expectRevert(FeeSplitHook.NotPoolManager.selector);
        hook.afterSwap(address(router), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(FeeSplitHook.NotPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(FeeSplitHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function test_fourSwapModes() public {
        _checkSwap(true, -1 ether, ALICE);
        _checkSwap(false, 0.25 ether, ALICE);
        _checkSwap(true, 0.5 ether, BOB);
        _checkSwap(false, -0.5 ether, BOB);
    }

    function testFuzz_fourModesAndFeeClosure(uint96 raw, uint8 mode, bool identity) public {
        int256 amount = int256(bound(uint256(raw), 1, 2 ether));
        mode %= 4;
        _checkSwap(mode < 2, mode % 2 == 0 ? -amount : amount, identity ? ALICE : address(0));
    }

    function _checkSwap(bool buy, int256 specified, address recipient) internal {
        uint256 claimBefore = manager.balanceOf(address(hook), 0);
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta delta = _swap(key, buy, specified, abi.encode(recipient));
        uint256 fee = manager.balanceOf(address(hook), 0) - claimBefore;
        bool ethSpecified = buy == (specified < 0);
        assertEq(
            int256(ethSpecified ? delta.amount0() : delta.amount1()), specified, "specified amount exact"
        );
        assertEq(int256(address(this).balance) - int256(ethBefore), int256(delta.amount0()));
        assertEq(int256(token.balanceOf(address(this))) - int256(tokenBefore), int256(delta.amount1()));

        uint256 base;
        if (ethSpecified) base = uint256(specified < 0 ? -specified : specified);
        else if (buy) base = uint256(-int256(delta.amount0())) - fee;
        else base = uint256(int256(delta.amount0())) + fee;
        assertEq(fee, base / 100, "fee is floor 1% of ETH leg");
        _feeEvent(vm.getRecordedLogs(), key.toId(), recipient, fee);
        _assertClaims();
    }

    function test_dustAllModes() public {
        _checkSwap(true, -1, ALICE);
        _checkSwap(true, 1, ALICE);
        _checkSwap(false, -1, ALICE);
        _checkSwap(false, 1, ALICE);
        assertEq(hook.totalPending(), 0);
    }

    function test_roundingRemainderGoesToBurn() public {
        vm.recordLogs();
        _swap(key, true, -199, abi.encode(ALICE));
        _feeEvent(vm.getRecordedLogs(), key.toId(), ALICE, 1);
        assertEq(hook.pendingInterface(ALICE), 0);
        assertEq(hook.pendingLP(key.toId()), 0);
        assertEq(hook.pendingBurn(key.toId()), 1);
        _assertClaims();
    }

    function test_invalidIdentityNeverCreditsRouter() public {
        bytes[6] memory invalid = [
            bytes(""),
            hex"01",
            abi.encode(address(0)),
            abi.encode(type(uint256).max),
            abi.encodePacked(ALICE),
            abi.encode(ALICE, BOB)
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.recordLogs();
            _swap(key, true, -1 ether, invalid[i]);
            _feeEvent(vm.getRecordedLogs(), key.toId(), address(0), 0.01 ether);
        }
        assertEq(hook.pendingInterface(address(router)), 0);
        assertEq(hook.totalPendingInterface(), 0);
        assertEq(hook.pendingLP(key.toId()), 0.018 ether);
        assertEq(hook.pendingBurn(key.toId()), 0.042 ether);
        _assertClaims();
    }

    function test_partialFillAllFourModesRollsBack() public {
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            int256 specified = mode % 2 == 0 ? -int256(1 ether) : int256(1 ether);
            uint160 limit = buy ? Q96 - 1 : Q96 + 1;
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.afterSwap.selector,
                    abi.encodeWithSelector(FeeSplitHook.PartialFill.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            router.swap{value: buy ? 2 ether : 0}(
                key,
                SwapParams(buy, specified, limit),
                PoolSwapTest.TestSettings(false, false),
                abi.encode(ALICE)
            );
            assertEq(manager.balanceOf(address(hook), 0), 0);
            assertEq(hook.totalPending(), 0);
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, Q96);
        }
    }

    function test_extremeSpecifiedAmountsRefuseUnsafeCasts() public {
        vm.startPrank(address(manager));
        vm.expectRevert(FeeSplitHook.SwapAmountTooLarge.selector);
        hook.beforeSwap(address(router), key, SwapParams(true, type(int256).min, 1), "");
        vm.expectRevert(FeeSplitHook.SwapAmountTooLarge.selector);
        hook.beforeSwap(address(router), key, SwapParams(false, type(int256).max, 1), "");
        vm.stopPrank();
    }

    function test_claimAndBurnAcrossPoolsAndNewEpochs() public {
        _swap(key, true, -1 ether, abi.encode(ALICE));
        _swap(secondKey, false, 1 ether, abi.encode(ALICE));
        _swap(key, false, -1 ether, abi.encode(BOB));
        uint256 alice = hook.pendingInterface(ALICE);
        uint256 bob = hook.pendingInterface(BOB);
        uint256 lp = hook.totalPendingLP();
        uint256 burn = hook.totalPendingBurn();
        vm.prank(address(0xBADD));
        assertEq(hook.claim(), 0, "cannot claim somebody else's fees");
        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeSplitHook.Claimed(ALICE, alice);
        vm.prank(ALICE);
        assertEq(hook.claim(), alice);
        assertEq(ALICE.balance, alice);
        assertEq(hook.pendingInterface(ALICE), 0);
        assertEq(hook.pendingInterfaceForPool(key.toId(), ALICE), 0);
        assertEq(hook.pendingInterfaceForPool(secondKey.toId(), ALICE), 0);
        assertEq(hook.pendingInterface(BOB), bob);
        vm.expectEmit(false, false, false, true, address(hook));
        emit FeeSplitHook.Burned(burn);
        assertEq(hook.burnAccrued(), burn);
        assertEq(address(0xdead).balance, burn);
        assertEq(hook.pendingBurn(key.toId()), 0);
        assertEq(hook.pendingBurn(secondKey.toId()), 0);
        assertEq(hook.totalPendingLP(), lp);
        assertEq(hook.burnAccrued(), 0);
        vm.prank(ALICE);
        assertEq(hook.claim(), 0);
        _swap(secondKey, true, -1 ether, abi.encode(ALICE));
        assertEq(hook.pendingInterfaceForPool(secondKey.toId(), ALICE), 0.002 ether);
        assertEq(hook.pendingInterfaceForPool(key.toId(), ALICE), 0);
        assertEq(hook.pendingBurn(secondKey.toId()), 0.005 ether);
        assertEq(hook.pendingBurn(key.toId()), 0);
        (uint256 lifetimeInterface, uint256 lifetimeLP, uint256 lifetimeBurn) =
            hook.lifetimeTotals(secondKey.toId());
        assertEq(lifetimeInterface, 0.004 ether);
        assertEq(lifetimeLP, 0.006 ether);
        assertEq(lifetimeBurn, 0.01 ether);
        _assertClaims();
    }

    function test_donationIsDeferredAndPoolSpecific() public {
        _swap(key, true, -1 ether, abi.encode(ALICE));
        _swap(secondKey, true, -1 ether, abi.encode(ALICE));
        (uint256 beforeGrowth,) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 secondGrowth,) = manager.getFeeGrowthGlobals(secondKey.toId());
        uint256 managerETH = address(manager).balance;
        uint256 claims = manager.balanceOf(address(hook), 0);
        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeSplitHook.Donated(key.toId(), 0.003 ether);
        vm.prank(BOB);
        assertEq(hook.donateAccrued(key), 0.003 ether);
        assertEq(hook.pendingLP(key.toId()), 0);
        assertEq(hook.pendingLP(secondKey.toId()), 0.003 ether);
        assertEq(manager.balanceOf(address(hook), 0), claims - 0.003 ether);
        assertEq(address(manager).balance, managerETH, "donation burns claims, no native transfer");
        (uint256 afterGrowth,) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 secondAfter,) = manager.getFeeGrowthGlobals(secondKey.toId());
        assertEq(afterGrowth - beforeGrowth, uint256(0.003 ether) * (1 << 128) / LIQUIDITY);
        assertEq(secondAfter, secondGrowth);
        assertEq(hook.donateAccrued(key), 0);
        _assertClaims();
    }

    function test_donationWithNoLiquidityRestoresBucket() public {
        _swap(key, true, -1 ether, abi.encode(ALICE));
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, -int256(LIQUIDITY), 0), "");
        assertEq(manager.getLiquidity(key.toId()), 0);
        uint256 claims = manager.balanceOf(address(hook), 0);
        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        hook.donateAccrued(key);
        assertEq(hook.pendingLP(key.toId()), 0.003 ether);
        assertEq(manager.balanceOf(address(hook), 0), claims);
        // Re-adding liquidity makes the same accumulated bucket distributable.
        liquidityRouter.modifyLiquidity{value: 40_000 ether}(
            key, ModifyLiquidityParams(-600, 600, int256(LIQUIDITY), 0), ""
        );
        assertEq(hook.donateAccrued(key), 0.003 ether);
        _assertClaims();
    }

    function test_wrongPoolCannotSpendAnotherPoolsBucket() public {
        _swap(key, true, -1 ether, abi.encode(ALICE));
        PoolKey memory wrong = key;
        wrong.hooks = IHooks(address(0));
        vm.expectRevert(FeeSplitHook.InvalidPool.selector);
        hook.donateAccrued(wrong);
        wrong = key;
        wrong.fee = 100;
        assertEq(hook.donateAccrued(wrong), 0);
        assertEq(hook.pendingLP(key.toId()), 0.003 ether);
        _assertClaims();
    }

    function test_nonEthPoolHasNoEffectsInAllModes() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1_000_000 ether);
        other.approve(address(router), type(uint256).max);
        other.approve(address(liquidityRouter), type(uint256).max);
        (address first, address second) = address(token) < address(other)
            ? (address(token), address(other))
            : (address(other), address(token));
        PoolKey memory nonEth =
            PoolKey(Currency.wrap(first), Currency.wrap(second), 3000, 60, IHooks(address(hook)));
        manager.initialize(nonEth, Q96);
        liquidityRouter.modifyLiquidity(nonEth, ModifyLiquidityParams(-600, 600, int256(LIQUIDITY), 0), "");
        vm.recordLogs();
        for (uint256 mode; mode < 4; ++mode) {
            router.swap(
                nonEth,
                SwapParams(
                    mode < 2,
                    mode % 2 == 0 ? -int256(1 ether) : int256(1 ether),
                    mode < 2 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                abi.encode(ALICE)
            );
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 n; n < logs.length; ++n) {
            assertTrue(logs[n].emitter != address(hook), "non-ETH pool must not emit hook events");
        }
        assertEq(hook.totalPending(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        (uint256 i, uint256 l, uint256 b) = hook.lifetimeTotals(nonEth.toId());
        assertEq(i + l + b, 0);
        vm.prank(address(manager));
        (, BeforeSwapDelta beforeDelta,) =
            hook.beforeSwap(address(router), nonEth, SwapParams(true, -1 ether, 0), "");
        vm.prank(address(manager));
        (, int128 afterDelta) =
            hook.afterSwap(address(router), nonEth, SwapParams(false, 1 ether, 0), BalanceDelta.wrap(0), "");
        assertEq(BeforeSwapDelta.unwrap(beforeDelta), 0);
        assertEq(afterDelta, 0);
    }
}
