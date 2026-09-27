// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {FeeSplitHook} from "../src/FeeSplitHook.sol";
import {THRW} from "../src/THRW.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Ghost accounting spans two pools, three independent recipients, all swap modes and all payouts.
/// @dev Expected fees are checked against actual swap deltas; expected splits do not read hook buckets.
contract FeeHandler is Test {
    using PoolIdLibrary for PoolKey;

    FeeSplitHook private immutable hook;
    IPoolManager private immutable manager;
    PoolSwapTest private immutable router;
    PoolKey[2] private keys;
    address[3] private recipients = [address(0xA11CE), address(0xB0B), address(0xCA11)];

    uint256[3][2] private ghostInterface;
    uint256[2] private ghostLP;
    uint256[2] private ghostBurn;
    uint256[3][2] private ghostLifetime;
    uint256 public feesAccrued;
    uint256 public feesPaid;
    uint256 public swaps;

    constructor(
        FeeSplitHook hook_,
        IPoolManager manager_,
        PoolSwapTest router_,
        THRW token_,
        PoolKey memory first,
        PoolKey memory second
    ) {
        hook = hook_;
        manager = manager_;
        router = router_;
        keys[0] = first;
        keys[1] = second;
        token_.approve(address(router_), type(uint256).max);
    }

    function swap(uint256 poolSeed, uint256 modeSeed, uint256 size, uint256 identitySeed) external {
        uint256 poolIndex = poolSeed % 2;
        uint256 identity = identitySeed % 4;
        uint256 fee = _executeSwap(poolIndex, modeSeed % 4, size, identity);
        uint256 interfaceShare = identity == 3 ? 0 : fee / 5;
        uint256 lpShare = fee * 3 / 10;
        uint256 burnShare = fee - interfaceShare - lpShare;
        if (identity != 3) ghostInterface[poolIndex][identity] += interfaceShare;
        ghostLP[poolIndex] += lpShare;
        ghostBurn[poolIndex] += burnShare;
        ghostLifetime[poolIndex][0] += interfaceShare;
        ghostLifetime[poolIndex][1] += lpShare;
        ghostLifetime[poolIndex][2] += burnShare;
        feesAccrued += fee;
        ++swaps;
    }

    function _executeSwap(uint256 poolIndex, uint256 mode, uint256 size, uint256 identity)
        private
        returns (uint256 fee)
    {
        bool buy = mode < 2;
        int256 magnitude = int256(bound(size, 1, 2 ether));
        int256 specified = mode % 2 == 0 ? -magnitude : magnitude;
        bytes memory data = identity == 3 ? bytes("") : abi.encode(recipients[identity]);
        uint256 beforeClaims = manager.balanceOf(address(hook), 0);
        BalanceDelta delta = router.swap{value: buy ? 10 ether : 0}(
            keys[poolIndex],
            SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
        fee = manager.balanceOf(address(hook), 0) - beforeClaims;
        bool ethSpecified = buy == (specified < 0);
        assertEq(int256(ethSpecified ? delta.amount0() : delta.amount1()), specified);
        uint256 ethBase = ethSpecified
            ? uint256(magnitude)
            : (buy ? uint256(-int256(delta.amount0())) - fee : uint256(int256(delta.amount0())) + fee);
        assertEq(fee, ethBase / 100);
    }

    function claim(uint256 seed) external {
        uint256 index = seed % 3;
        uint256 expected = ghostInterface[0][index] + ghostInterface[1][index];
        uint256 beforeBalance = recipients[index].balance;
        vm.prank(recipients[index]);
        assertEq(hook.claim(), expected);
        assertEq(recipients[index].balance - beforeBalance, expected);
        feesPaid += expected;
        ghostInterface[0][index] = 0;
        ghostInterface[1][index] = 0;
    }

    function burn() external {
        uint256 expected = ghostBurn[0] + ghostBurn[1];
        uint256 beforeBalance = address(0xdead).balance;
        assertEq(hook.burnAccrued(), expected);
        assertEq(address(0xdead).balance - beforeBalance, expected);
        feesPaid += expected;
        ghostBurn[0] = 0;
        ghostBurn[1] = 0;
    }

    function donate(uint256 seed) external {
        uint256 index = seed % 2;
        uint256 expected = ghostLP[index];
        uint256 managerETH = address(manager).balance;
        assertEq(hook.donateAccrued(keys[index]), expected);
        assertEq(address(manager).balance, managerETH);
        feesPaid += expected;
        ghostLP[index] = 0;
    }

    function assertAccounting() external view {
        uint256 interfaceSum;
        uint256 lpSum;
        uint256 burnSum;
        for (uint256 p; p < 2; ++p) {
            PoolId id = keys[p].toId();
            assertEq(hook.pendingLP(id), ghostLP[p]);
            assertEq(hook.pendingBurn(id), ghostBurn[p]);
            lpSum += ghostLP[p];
            burnSum += ghostBurn[p];
            for (uint256 r; r < 3; ++r) {
                assertEq(hook.pendingInterfaceForPool(id, recipients[r]), ghostInterface[p][r]);
                interfaceSum += ghostInterface[p][r];
            }
            (uint256 i, uint256 l, uint256 b) = hook.lifetimeTotals(id);
            assertEq(i, ghostLifetime[p][0]);
            assertEq(l, ghostLifetime[p][1]);
            assertEq(b, ghostLifetime[p][2]);
        }
        for (uint256 r; r < 3; ++r) {
            assertEq(hook.pendingInterface(recipients[r]), ghostInterface[0][r] + ghostInterface[1][r]);
        }
        assertEq(hook.totalPendingInterface(), interfaceSum);
        assertEq(hook.totalPendingLP(), lpSum);
        assertEq(hook.totalPendingBurn(), burnSum);
        uint256 claims = manager.balanceOf(address(hook), 0);
        assertEq(claims, interfaceSum + lpSum + burnSum, "independent sum of outstanding buckets");
        assertEq(claims, hook.totalPending());
        assertEq(claims + feesPaid, feesAccrued, "all historical fees either paid or pending");
        assertEq(address(hook).balance, 0);
    }

    receive() external payable {}
}

contract FeeSplitInvariantTest is HookTestBase {
    FeeHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new FeeHandler(hook, manager, router, token, key, secondKey);
        vm.deal(address(handler), 100_000 ether);
        token.transfer(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.burn.selector;
        selectors[3] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        // Give every campaign liabilities in both pools before randomized state transitions begin.
        handler.swap(0, 0, 1 ether, 0);
        handler.swap(1, 3, 1 ether, 1);
    }

    function invariant_claimsEqualEveryOutstandingBucket() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.claim(0);
        handler.claim(1);
        handler.claim(2);
        handler.donate(0);
        handler.donate(1);
        handler.burn();
        handler.assertAccounting();
        assertEq(hook.totalPending(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }
}
