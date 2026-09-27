// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {FeeSplitHook} from "../src/FeeSplitHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract ClaimReceiver {
    FeeSplitHook private immutable hook;
    PoolKey private key;
    bool public reject;
    bool public sawZeroBalance;
    bool public blockedClaim;
    bool public blockedBurn;
    bool public blockedDonate;

    constructor(FeeSplitHook hook_, PoolKey memory key_) {
        hook = hook_;
        key = key_;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function claim() external {
        hook.claim();
    }

    receive() external payable {
        require(!reject, "receiver rejects ETH");
        sawZeroBalance = hook.pendingInterface(address(this)) == 0;
        (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(hook.claim, ()));
        blockedClaim = !ok && bytes4(reason) == FeeSplitHook.ReentrantPayout.selector;
        (ok, reason) = address(hook).call(abi.encodeCall(hook.burnAccrued, ()));
        blockedBurn = !ok && bytes4(reason) == FeeSplitHook.ReentrantPayout.selector;
        (ok, reason) = address(hook).call(abi.encodeCall(hook.donateAccrued, (key)));
        blockedDonate = !ok && bytes4(reason) == FeeSplitHook.ReentrantPayout.selector;
    }
}

contract NestedPayout is IUnlockCallback {
    IPoolManager private immutable manager;
    FeeSplitHook private immutable hook;

    constructor(IPoolManager manager_, FeeSplitHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function attempt() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        hook.burnAccrued();
        return "";
    }
}

contract PayoutSafetyTest is HookTestBase {
    using PoolIdLibrary for PoolKey;

    function test_claimZeroesBeforeTransferAndRejectsReentrancy() public {
        ClaimReceiver receiver = new ClaimReceiver(hook, key);
        _swap(key, true, -1 ether, abi.encode(address(receiver)));
        receiver.claim();
        assertEq(address(receiver).balance, 0.002 ether);
        assertTrue(receiver.sawZeroBalance());
        assertTrue(receiver.blockedClaim());
        assertTrue(receiver.blockedBurn());
        assertTrue(receiver.blockedDonate());
        assertEq(hook.pendingInterface(address(receiver)), 0);
        assertEq(hook.totalPendingBurn(), 0.005 ether);
        assertEq(hook.totalPendingLP(), 0.003 ether);
        _assertClaims();
    }

    function test_rejectingReceiverRollsBackClaimAndEpoch() public {
        ClaimReceiver receiver = new ClaimReceiver(hook, key);
        _swap(key, true, -1 ether, abi.encode(address(receiver)));
        _swap(secondKey, true, -1 ether, abi.encode(address(receiver)));
        receiver.setReject(true);
        vm.expectRevert();
        receiver.claim();
        assertEq(hook.pendingInterface(address(receiver)), 0.004 ether);
        assertEq(hook.pendingInterfaceForPool(key.toId(), address(receiver)), 0.002 ether);
        assertEq(hook.pendingInterfaceForPool(secondKey.toId(), address(receiver)), 0.002 ether);
        _assertClaims();
        receiver.setReject(false);
        receiver.claim();
        assertEq(address(receiver).balance, 0.004 ether);
        assertEq(hook.pendingInterfaceForPool(key.toId(), address(receiver)), 0);
        assertEq(hook.pendingInterfaceForPool(secondKey.toId(), address(receiver)), 0);
        _assertClaims();
    }

    function test_cannotPayoutInsideSomebodyElsesUnlock() public {
        _swap(key, true, -1 ether, abi.encode(ALICE));
        NestedPayout nested = new NestedPayout(manager, hook);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        nested.attempt();
        assertEq(hook.totalPendingBurn(), 0.005 ether);
        _assertClaims();
        hook.burnAccrued();
        _assertClaims();
    }

    function test_newLiquidityCanCaptureAccruedDonation() public {
        _swap(key, true, -1 ether, abi.encode(ALICE));
        // A distinct LP arrives after accrual and just before donation, with nine times the incumbent liquidity.
        PoolModifyLiquidityTest jit = new PoolModifyLiquidityTest(manager);
        token.approve(address(jit), type(uint256).max);
        jit.modifyLiquidity{value: 300_000 ether}(
            key, ModifyLiquidityParams(-600, 600, int256(9 * LIQUIDITY), 0), ""
        );
        hook.donateAccrued(key);
        BalanceDelta fees = jit.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 0, 0), "");
        assertApproxEqAbs(uint256(int256(fees.amount0())), 0.0027 ether, 1);
        assertEq(fees.amount1(), 0);
        _assertClaims();
    }
}
