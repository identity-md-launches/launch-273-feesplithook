// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RehearsalTestBase} from "./helpers/RehearsalTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {FeeSplitHook} from "../src/FeeSplitHook.sol";
import {LaunchParameters} from "../script/LaunchParameters.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice An interface recipient that trades directly against the manager while its claim is being paid.
/// @dev The claim's ETH arrives inside the hook's own unlock, so the manager is unlocked and `swap` is callable
/// by anyone. The swap nominates the recipient again, so a fresh credit lands in the epoch the claim just opened.
contract ClaimTimeSwapper {
    IPoolManager private immutable manager;
    FeeSplitHook private immutable hook;
    PoolKey private key;
    bool public swapped;
    uint256 public innerFee;

    constructor(IPoolManager manager_, FeeSplitHook hook_, PoolKey memory key_) {
        manager = manager_;
        hook = hook_;
        key = key_;
    }

    function claim() external returns (uint256) {
        return hook.claim();
    }

    receive() external payable {
        if (swapped) return;
        swapped = true;
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        BalanceDelta delta = manager.swap(
            key,
            SwapParams(true, -int256(msg.value / 2), TickMath.MIN_SQRT_PRICE + 1),
            abi.encode(address(this))
        );
        innerFee = manager.balanceOf(address(hook), 0) - claimsBefore;
        manager.settle{value: uint256(-int256(delta.amount0()))}();
        manager.take(key.currency1, address(this), uint256(int256(delta.amount1())));
    }
}

contract LaunchRehearsalFuzzTest is RehearsalTestBase, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    struct Direct {
        bool viaAfterSwap;
        SwapParams params;
        BalanceDelta delta;
        bytes hookData;
        uint256 expectedFee;
    }

    // ---------------------------------------------------------------------------------------------
    // Shares sum to the fee for fuzzed amounts, on the factory-launched pool through a real manager.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_sharesSumToTheFeeOnTheLaunchPool(uint96 raw, uint8 modeSeed, uint8 identitySeed)
        public
    {
        _bootstrapLaunchPool(2 ether);
        uint256 mode = modeSeed % 4;
        bool buy = mode < 2;
        bool exactIn = mode % 2 == 0;
        int256 specified;
        if (buy && exactIn) specified = -int256(bound(raw, 1, 1 ether));
        else if (buy) specified = int256(bound(raw, 1, 1_000_000 ether));
        else if (exactIn) specified = -int256(bound(raw, 1, token.balanceOf(address(this)) / 10));
        else specified = int256(bound(raw, 1, 0.1 ether));

        bytes memory data;
        uint256 shape = identitySeed % 4;
        if (shape == 0) data = abi.encode(ALICE);
        else if (shape == 1) data = abi.encode(BOB);
        else if (shape == 2) data = "";
        else data = abi.encode((uint256(1) << 160) | uint160(ALICE));
        address recipient = _identity(data);

        _checkedSwap(launchKey, launchId, buy, specified, data, recipient);
    }

    function testFuzz_sharesSumToTheFeeOnTheOtherPool(uint96 raw, uint8 modeSeed, bool identity) public {
        uint256 mode = modeSeed % 4;
        int256 magnitude = int256(bound(raw, 1, 2 ether));
        int256 specified = mode % 2 == 0 ? -magnitude : magnitude;
        bytes memory data = identity ? abi.encode(CAROL) : bytes("");
        _checkedSwap(otherKey, otherId, mode < 2, specified, data, identity ? CAROL : address(0));
    }

    struct Buckets {
        uint256 claims;
        uint256 interfaceAll;
        uint256 interfacePool;
        uint256 totalInterface;
        uint256 lp;
        uint256 burn;
        uint256 lifeI;
        uint256 lifeL;
        uint256 lifeB;
    }

    function _buckets(PoolId id, address rcpt) private view returns (Buckets memory b) {
        b.claims = _claims();
        b.interfaceAll = hook.pendingInterface(rcpt);
        b.interfacePool = hook.pendingInterfaceForPool(id, rcpt);
        b.totalInterface = hook.totalPendingInterface();
        b.lp = hook.pendingLP(id);
        b.burn = hook.pendingBurn(id);
        (b.lifeI, b.lifeL, b.lifeB) = hook.lifetimeTotals(id);
    }

    function _checkedSwap(
        PoolKey memory k,
        PoolId id,
        bool buy,
        int256 specified,
        bytes memory data,
        address rcpt
    ) private {
        Buckets memory pre = _buckets(id, rcpt);
        vm.recordLogs();
        BalanceDelta delta = _swap(k, buy, specified, data, 10 ether);
        Split memory s = _onlyFeeSplit(vm.getRecordedLogs());
        Buckets memory post = _buckets(id, rcpt);
        uint256 fee = post.claims - pre.claims;
        assertEq(fee, _ethLeg(buy, specified, delta, fee) / 100, "fee is floor(1%) of the ETH leg");
        _verifySplit(s, id, rcpt, fee);
        _verifyBuckets(pre, post, s);
    }

    function _ethLeg(bool buy, int256 specified, BalanceDelta delta, uint256 fee)
        private
        pure
        returns (uint256)
    {
        bool ethSpecified = buy == (specified < 0);
        assertEq(
            int256(ethSpecified ? delta.amount0() : delta.amount1()), specified, "specified amount honoured"
        );
        if (ethSpecified) return uint256(specified < 0 ? -specified : specified);
        if (buy) return uint256(-int256(delta.amount0())) - fee;
        return uint256(int256(delta.amount0())) + fee;
    }

    function _verifySplit(Split memory s, PoolId id, address rcpt, uint256 fee) private pure {
        (uint256 i, uint256 l, uint256 b) = _split(fee, rcpt != address(0));
        assertEq(PoolId.unwrap(s.id), PoolId.unwrap(id));
        assertEq(s.recipient, rcpt, "event names the decoded identity or nobody");
        assertEq(s.fee, fee);
        assertEq(s.interfaceShare, i);
        assertEq(s.lpShare, l);
        assertEq(s.burnShare, b);
        assertEq(s.interfaceShare + s.lpShare + s.burnShare, s.fee, "three shares close the fee exactly");
        assertGe(s.burnShare, fee / 2, "burn never receives less than its floor share");
    }

    function _verifyBuckets(Buckets memory pre, Buckets memory post, Split memory s) private view {
        assertEq(post.interfaceAll - pre.interfaceAll, s.interfaceShare, "interface bucket grew by its share");
        assertEq(post.interfacePool - pre.interfacePool, s.interfaceShare);
        assertEq(post.totalInterface - pre.totalInterface, s.interfaceShare);
        assertEq(post.lp - pre.lp, s.lpShare, "LP bucket grew by its share");
        assertEq(post.burn - pre.burn, s.burnShare, "burn bucket grew by its share");
        assertEq(post.lifeI - pre.lifeI, s.interfaceShare);
        assertEq(post.lifeL - pre.lifeL, s.lpShare);
        assertEq(post.lifeB - pre.lifeB, s.burnShare);
        assertEq(hook.pendingInterface(address(0)), 0, "the zero address is never credited");
        assertEq(hook.pendingInterface(address(router)), 0, "the router is never credited");
        _assertClaimsBacked();
    }

    // ---------------------------------------------------------------------------------------------
    // The same closure over the whole int128 domain, driving the callbacks directly inside an unlock.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_specifiedModesCloseAcrossTheWholeInt128Domain(uint256 raw, bool buy, bytes32 word)
        public
    {
        int256 magnitude = int256(bound(raw, 1, uint256(uint128(type(int128).max))));
        // ETH is the specified currency for exact-in buys and exact-out sells.
        SwapParams memory params = SwapParams(buy, buy ? -magnitude : magnitude, 0);
        uint256 expectedFee = uint256(magnitude) / 100;
        bytes memory data = abi.encode(word);
        _driveDirect(Direct(false, params, BalanceDelta.wrap(0), data, expectedFee), _identity(data));
    }

    function testFuzz_unspecifiedModesCloseAcrossTheWholeInt128Domain(
        uint256 rawTokens,
        uint256 rawEth,
        bool buy,
        bytes32 word
    ) public {
        int256 tokens = int256(bound(rawTokens, 1, uint256(uint128(type(int128).max))));
        int128 ethMoved = int128(int256(bound(rawEth, 0, uint256(uint128(type(int128).max)))));
        // THRW is the specified currency for exact-out buys and exact-in sells; ETH moved is read from the delta.
        SwapParams memory params = SwapParams(buy, buy ? tokens : -tokens, 0);
        BalanceDelta delta =
            buy ? toBalanceDelta(-ethMoved, int128(tokens)) : toBalanceDelta(ethMoved, -int128(tokens));
        uint256 expectedFee = uint256(uint128(ethMoved)) / 100;
        bytes memory data = abi.encode(word);
        _driveDirect(Direct(true, params, delta, data, expectedFee), _identity(data));
    }

    function _driveDirect(Direct memory d, address recipient) private {
        vm.deal(address(this), type(uint200).max);
        uint256 claimsBefore = _claims();
        uint256 managerEthBefore = address(manager).balance;
        uint256 interfaceBefore = hook.pendingInterface(recipient);
        uint256 lpBefore = hook.pendingLP(launchId);
        uint256 burnBefore = hook.pendingBurn(launchId);
        (uint256 i, uint256 l, uint256 b) = _split(d.expectedFee, recipient != address(0));

        vm.expectEmit(true, true, false, true, address(hook));
        emit FeeSplitHook.FeeSplit(launchId, recipient, d.expectedFee, i, l, b);
        manager.unlock(abi.encode(d));

        assertEq(_claims() - claimsBefore, d.expectedFee, "claims minted equal the fee");
        assertEq(address(manager).balance - managerEthBefore, d.expectedFee, "the fee was settled in ETH");
        assertEq(hook.pendingInterface(recipient) - interfaceBefore, i);
        assertEq(hook.pendingLP(launchId) - lpBefore, l);
        assertEq(hook.pendingBurn(launchId) - burnBefore, b);
        assertEq(i + l + b, d.expectedFee, "closure at the boundary of the domain");
        _assertClaimsBacked();
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        Direct memory d = abi.decode(raw, (Direct));
        vm.startPrank(address(manager));
        if (d.viaAfterSwap) {
            // The other callback must stay silent for ETH-unspecified swaps.
            (bytes4 sel, BeforeSwapDelta quiet, uint24 lpFee) =
                hook.beforeSwap(address(router), launchKey, d.params, d.hookData);
            assertEq(sel, IHooks.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(quiet), 0, "no specified-side fee when THRW is specified");
            assertEq(lpFee, 0);

            // A pool that filled one wei less or more than the specified THRW is a partial fill.
            BalanceDelta off = toBalanceDelta(d.delta.amount0(), d.delta.amount1() - 1);
            vm.expectRevert(FeeSplitHook.PartialFill.selector);
            hook.afterSwap(address(router), launchKey, d.params, off, d.hookData);
            if (d.delta.amount1() < type(int128).max) {
                off = toBalanceDelta(d.delta.amount0(), d.delta.amount1() + 1);
                vm.expectRevert(FeeSplitHook.PartialFill.selector);
                hook.afterSwap(address(router), launchKey, d.params, off, d.hookData);
            }

            (bytes4 afterSel, int128 unspecified) =
                hook.afterSwap(address(router), launchKey, d.params, d.delta, d.hookData);
            assertEq(afterSel, IHooks.afterSwap.selector);
            assertEq(uint256(uint128(unspecified)), d.expectedFee, "unspecified delta is the fee");
        } else {
            (bytes4 sel, BeforeSwapDelta delta, uint24 lpFee) =
                hook.beforeSwap(address(router), launchKey, d.params, d.hookData);
            assertEq(sel, IHooks.beforeSwap.selector);
            assertEq(uint256(uint128(delta.getSpecifiedDelta())), d.expectedFee, "specified delta is the fee");
            assertEq(delta.getUnspecifiedDelta(), 0);
            assertEq(lpFee, 0, "never overrides the pool's LP fee");
        }
        vm.stopPrank();
        // The hook minted itself claims; a router would settle this ETH at the end of the swap.
        if (d.expectedFee != 0) manager.settleFor{value: d.expectedFee}(address(hook));
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // A missing interface routes exactly the interface share to the burn.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_missingInterfaceRoutesItsShareToTheBurn(uint96 raw, uint8 shapeSeed) public {
        _bootstrapLaunchPool(2 ether);
        uint256 ethIn = bound(raw, 1, 1 ether);
        bytes[7] memory invalid = [
            bytes(""),
            new bytes(31),
            new bytes(33),
            abi.encode(address(0)),
            abi.encode((uint256(1) << 160) | uint160(ALICE)),
            abi.encodePacked(ALICE),
            abi.encode(ALICE, uint256(1))
        ];
        bytes memory data = invalid[shapeSeed % invalid.length];
        assertEq(_identity(data), address(0), "shape is invalid under the identity rule");

        // Reference: the same exact-in size with a valid identity. Exact-in fees depend only on the size.
        vm.recordLogs();
        _swap(launchKey, true, -int256(ethIn), abi.encode(ALICE), 10 ether);
        Split memory withIdentity = _onlyFeeSplit(vm.getRecordedLogs());

        uint256 interfaceTotalBefore = hook.totalPendingInterface();
        uint256 aliceBefore = hook.pendingInterface(ALICE);
        uint256 burnBefore = hook.pendingBurn(launchId);
        uint256 lpBefore = hook.pendingLP(launchId);
        (uint256 lifeI,,) = hook.lifetimeTotals(launchId);

        vm.recordLogs();
        _swap(launchKey, true, -int256(ethIn), data, 10 ether);
        Split memory without = _onlyFeeSplit(vm.getRecordedLogs());

        assertEq(without.fee, withIdentity.fee, "same size, same fee");
        assertEq(without.recipient, address(0), "nobody is named");
        assertEq(without.interfaceShare, 0, "nobody is credited");
        assertEq(without.lpShare, withIdentity.lpShare, "LPs are unaffected by the missing interface");
        assertEq(
            without.burnShare,
            withIdentity.burnShare + withIdentity.interfaceShare,
            "the whole interface share moves to the burn"
        );
        assertEq(without.lpShare + without.burnShare, without.fee, "two shares close the fee");

        assertEq(hook.totalPendingInterface(), interfaceTotalBefore, "no interface liability was created");
        assertEq(hook.pendingInterface(ALICE), aliceBefore);
        assertEq(hook.pendingInterface(address(0)), 0);
        assertEq(hook.pendingInterface(address(router)), 0);
        assertEq(hook.pendingInterface(address(this)), 0);
        assertEq(hook.pendingInterfaceForPool(launchId, address(0)), 0);
        assertEq(hook.pendingBurn(launchId) - burnBefore, without.burnShare);
        assertEq(hook.pendingLP(launchId) - lpBefore, without.lpShare);
        (uint256 lifeIAfter,,) = hook.lifetimeTotals(launchId);
        assertEq(lifeIAfter, lifeI, "lifetime interface total records nothing for a missing interface");
        _assertClaimsBacked();
    }

    // ---------------------------------------------------------------------------------------------
    // donateAccrued raises in-range fee growth by exactly the donation, and only in-range positions see it.
    // ---------------------------------------------------------------------------------------------

    struct Growth {
        uint256 global0;
        uint256 global1;
        uint256 insideSeed;
        uint256 insideAbove;
        uint256 claims;
        uint256 managerEth;
        uint256 lpTotal;
        uint256 lifetimeLP;
    }

    int24 private constant ABOVE_LOWER = LaunchParameters.TICK_UPPER;
    int24 private constant ABOVE_UPPER = LaunchParameters.TICK_UPPER + 60;

    function _growth() private view returns (Growth memory g) {
        (g.global0, g.global1) = manager.getFeeGrowthGlobals(launchId);
        (g.insideSeed,) =
            manager.getFeeGrowthInside(launchId, LaunchParameters.TICK_LOWER, LaunchParameters.TICK_UPPER);
        (g.insideAbove,) = manager.getFeeGrowthInside(launchId, ABOVE_LOWER, ABOVE_UPPER);
        g.claims = _claims();
        g.managerEth = address(manager).balance;
        g.lpTotal = hook.totalPendingLP();
        (, g.lifetimeLP,) = hook.lifetimeTotals(launchId);
    }

    function testFuzz_donateRaisesInRangeFeeGrowthByExactlyTheDonation(uint96 raw) public {
        uint256 ethIn = bound(raw, 1_000, 3 ether);
        _bootstrapLaunchPool(ethIn);
        // A position parked entirely above the price holds only ETH and is not in range.
        liquidityRouter.modifyLiquidity{value: 1 ether}(
            launchKey, ModifyLiquidityParams(ABOVE_LOWER, ABOVE_UPPER, 1 ether, 0), ""
        );

        uint256 amount = hook.pendingLP(launchId);
        assertEq(amount, (ethIn / 100) * 3_000 / 10_000, "LP bucket is the LP share of the first buy");
        uint128 active = manager.getLiquidity(launchId);
        assertEq(uint256(active), factory.liquidity(), "only the factory seed is in range");
        (, uint256 factoryLast0,) = manager.getPositionInfo(
            launchId, address(factory), LaunchParameters.TICK_LOWER, LaunchParameters.TICK_UPPER, bytes32(0)
        );
        Growth memory before = _growth();

        if (amount == 0) {
            vm.recordLogs();
            assertEq(hook.donateAccrued(launchKey), 0, "empty bucket pays nothing");
            assertEq(vm.getRecordedLogs().length, 0, "and emits nothing");
            return;
        }

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeSplitHook.Donated(launchId, amount);
        vm.prank(CAROL);
        assertEq(hook.donateAccrued(launchKey), amount, "anyone may trigger the donation");

        Growth memory post = _growth();
        uint256 expectedGrowth = FullMath.mulDiv(amount, Q128, active);
        assertEq(post.global0 - before.global0, expectedGrowth, "ETH fee growth rose by donation / liquidity");
        assertEq(post.global1, before.global1, "no THRW was donated");
        assertEq(
            post.insideSeed - before.insideSeed, expectedGrowth, "the in-range seed position sees all of it"
        );
        assertEq(post.insideAbove, before.insideAbove, "the out-of-range position sees none of it");

        // What the seed LP could collect from the donation alone, on top of the buy's own pool fee.
        uint256 owed = FullMath.mulDiv(post.insideSeed - before.insideSeed, active, Q128);
        assertLe(owed, amount, "the seed LP can never collect more than was donated");
        assertGe(owed + 1, amount, "and loses at most one wei to fee-growth rounding");
        assertGe(post.insideSeed, factoryLast0, "position checkpoint is never ahead of pool growth");

        assertEq(before.claims - post.claims, amount, "claims burned equal the donation");
        assertEq(post.managerEth, before.managerEth, "donation moves no ETH out of the manager");
        assertEq(hook.pendingLP(launchId), 0, "bucket emptied");
        assertEq(before.lpTotal - post.lpTotal, amount);
        assertEq(post.lifetimeLP, before.lifetimeLP, "lifetime totals never reset");
        assertEq(hook.donateAccrued(launchKey), 0, "a second donation has nothing to pay");
        _assertClaimsBacked();
    }

    function testFuzz_inRangeLPCollectsTheDonationAndOutOfRangeLPCollectsNothing(uint96 raw, bool identity)
        public
    {
        int256 ethIn = int256(bound(raw, 100, 2 ether));
        // An ETH-only position above the 1:1 price, with a distinct salt so it is separate from the seed.
        liquidityRouter.modifyLiquidity{value: 40_000 ether}(
            otherKey, ModifyLiquidityParams(1_200, 1_800, int256(OTHER_LIQUIDITY), bytes32(uint256(1))), ""
        );
        _swap(otherKey, true, -ethIn, identity ? abi.encode(ALICE) : bytes(""), 10 ether);
        // Flush the swap's own LP fees so what is collected next is only the donation.
        liquidityRouter.modifyLiquidity(otherKey, ModifyLiquidityParams(OTHER_LOWER, OTHER_UPPER, 0, 0), "");

        uint256 amount = hook.pendingLP(otherId);
        assertEq(amount, uint256(ethIn) / 100 * 3_000 / 10_000);
        assertEq(hook.donateAccrued(otherKey), amount);

        BalanceDelta inRange = liquidityRouter.modifyLiquidity(
            otherKey, ModifyLiquidityParams(OTHER_LOWER, OTHER_UPPER, 0, 0), ""
        );
        BalanceDelta outOfRange = liquidityRouter.modifyLiquidity(
            otherKey, ModifyLiquidityParams(1_200, 1_800, 0, bytes32(uint256(1))), ""
        );
        uint256 collected = uint256(int256(inRange.amount0()));
        assertLe(collected, amount, "cannot collect more than the donation");
        assertGe(collected + 1, amount, "collects the donation less at most one wei of rounding");
        assertEq(inRange.amount1(), 0, "nothing was donated in the other token");
        assertEq(outOfRange.amount0(), 0, "out-of-range liquidity gets no part of the donation");
        assertEq(outOfRange.amount1(), 0);
        _assertClaimsBacked();
    }

    // ---------------------------------------------------------------------------------------------
    // Zero-liquidity paths: revert cleanly, keep the bucket, release the lock, recover.
    // ---------------------------------------------------------------------------------------------

    function test_donateBeforeAnyTradeOnTheETHLessPoolIsANoOp() public {
        assertEq(manager.getLiquidity(launchId), 0);
        vm.recordLogs();
        assertEq(hook.donateAccrued(launchKey), 0, "nothing accrued, nothing to donate, no revert");
        assertEq(hook.burnAccrued(), 0);
        assertEq(hook.claim(), 0);
        assertEq(vm.getRecordedLogs().length, 0, "empty payouts emit nothing");
        assertEq(_claims(), 0);
    }

    function testFuzz_donateWithZeroLiquidityRevertsCleanlyAndKeepsEveryBucket(uint96 raw, bool identity)
        public
    {
        // At least 1000 wei so the 1% fee funds a nonzero LP share; the empty bucket is a no-op elsewhere.
        int256 ethIn = int256(bound(raw, 1_000, 2 ether));
        bytes memory data = identity ? abi.encode(ALICE) : bytes("");
        _swap(otherKey, true, -ethIn, data, 10 ether);
        liquidityRouter.modifyLiquidity(
            otherKey, ModifyLiquidityParams(OTHER_LOWER, OTHER_UPPER, -int256(OTHER_LIQUIDITY), 0), ""
        );
        assertEq(manager.getLiquidity(otherId), 0, "the only position was withdrawn");

        uint256 lp = hook.pendingLP(otherId);
        uint256 burn = hook.pendingBurn(otherId);
        uint256 alice = hook.pendingInterface(ALICE);
        uint256 claims = _claims();
        uint256 total = hook.totalPending();

        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        hook.donateAccrued(otherKey);
        assertEq(hook.pendingLP(otherId), lp, "LP bucket intact");
        assertEq(hook.totalPendingLP(), lp);
        assertEq(hook.pendingBurn(otherId), burn, "burn bucket untouched");
        assertEq(hook.pendingInterface(ALICE), alice, "interface bucket untouched");
        assertEq(_claims(), claims, "no claims were burned");
        assertEq(hook.totalPending(), total);

        // The payout lock was released with the revert: other payouts and a retry still work.
        assertEq(hook.burnAccrued(), burn);
        vm.prank(ALICE);
        assertEq(hook.claim(), alice);
        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        hook.donateAccrued(otherKey);
        assertEq(hook.pendingLP(otherId), lp, "still intact after the retry");

        liquidityRouter.modifyLiquidity{value: 40_000 ether}(
            otherKey, ModifyLiquidityParams(OTHER_LOWER, OTHER_UPPER, int256(OTHER_LIQUIDITY), 0), ""
        );
        assertEq(hook.donateAccrued(otherKey), lp, "the same bucket pays once liquidity returns");
        assertEq(hook.totalPending(), 0);
        assertEq(_claims(), 0);
        _assertClaimsBacked();
    }

    /// @dev Holders selling everything back push the price onto the seed's upper tick, where no liquidity is
    /// active. The LP bucket accrued along the way is stranded, not lost: the next buy re-enters the range.
    function test_sellingBackAboveTheSeedRangeStrandsTheLPBucketUntilTheNextBuy() public {
        _bootstrapLaunchPool(1 ether);
        uint256 bucketAfterBuy = hook.pendingLP(launchId);

        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(LaunchParameters.TICK_UPPER);
        uint128 active = manager.getLiquidity(launchId);
        // Sell exactly what moves the price onto the upper tick. The single-step estimate never overshoots
        // (per-step rounding only adds), so a sell that crosses several bitmap words lands short and the
        // next iteration finishes the job from within one step. The buyer is short by the pool's own LP
        // fee, so a later holder's tokens stand in for the difference.
        int256 ethOut;
        for (uint256 n; n < 8 && manager.getLiquidity(launchId) != 0; ++n) {
            (uint160 sqrtNow,,,) = manager.getSlot0(launchId);
            uint256 amountIn = SqrtPriceMath.getAmount1Delta(sqrtNow, sqrtUpper, active, true);
            uint256 gross = amountIn + FullMath.mulDivRoundingUp(amountIn, 3_000, 1_000_000 - 3_000);
            deal(address(token), address(this), gross);
            BalanceDelta sell = _swap(launchKey, false, -int256(gross), abi.encode(BOB), 0);
            assertEq(sell.amount1(), -int256(gross), "the whole input was consumed, never a partial fill");
            ethOut += sell.amount0();
        }
        assertGt(ethOut, 0, "selling back returned the pool's ETH");
        (, int24 tick,,) = manager.getSlot0(launchId);
        assertEq(tick, LaunchParameters.TICK_UPPER, "price sits on the seed's upper tick");
        assertEq(manager.getLiquidity(launchId), 0, "nothing is in range above the seed");

        uint256 stranded = hook.pendingLP(launchId);
        assertGt(stranded, bucketAfterBuy, "the sell added its LP share to the bucket");
        uint256 claims = _claims();
        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        hook.donateAccrued(launchKey);
        assertEq(hook.pendingLP(launchId), stranded, "stranded, not lost");
        assertEq(_claims(), claims);

        _swap(launchKey, true, -0.01 ether, "", 1 ether);
        assertEq(manager.getLiquidity(launchId), active, "a buy brings the seed back in range");
        uint256 expectedBucket = stranded + (uint256(0.01 ether) / 100) * 3_000 / 10_000;
        (uint256 growthBefore,) = manager.getFeeGrowthGlobals(launchId);
        assertEq(hook.donateAccrued(launchKey), expectedBucket, "the whole stranded bucket is paid at once");
        (uint256 growthAfter,) = manager.getFeeGrowthGlobals(launchId);
        assertEq(growthAfter - growthBefore, FullMath.mulDiv(expectedBucket, Q128, active));
        _assertClaimsBacked();
    }

    // ---------------------------------------------------------------------------------------------
    // Burn and claim empty exactly their buckets across pools, and nothing else.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_burnAndClaimEmptyExactlyTheirBuckets(uint96 a, uint96 b, uint96 c, uint96 d) public {
        _bootstrapLaunchPool(2 ether);
        _swap(launchKey, true, -int256(bound(a, 1, 1 ether)), abi.encode(ALICE), 10 ether);
        _swap(otherKey, false, int256(bound(b, 1, 1 ether)), abi.encode(BOB), 0);
        _swap(otherKey, true, -int256(bound(c, 1, 1 ether)), "", 10 ether);
        _swap(
            launchKey, false, -int256(bound(d, 1, token.balanceOf(address(this)) / 10)), abi.encode(ALICE), 0
        );
        _swap(otherKey, true, int256(bound(a, 1, 1 ether)), abi.encode(ALICE), 10 ether);
        _assertClaimsBacked();

        uint256 alice = hook.pendingInterface(ALICE);
        uint256 bob = hook.pendingInterface(BOB);
        uint256 lp = hook.totalPendingLP();
        uint256 burn = hook.totalPendingBurn();
        uint256 claims = _claims();
        bytes32 lifetimeBefore = _lifetimeSnapshot();
        assertEq(
            alice,
            hook.pendingInterfaceForPool(launchId, ALICE) + hook.pendingInterfaceForPool(otherId, ALICE),
            "a recipient's balance is the sum of its per-pool credits"
        );
        assertEq(alice + bob, hook.totalPendingInterface(), "only named recipients hold interface credit");

        // Somebody with nothing pending gets nothing and moves nothing.
        vm.recordLogs();
        vm.prank(CAROL);
        assertEq(hook.claim(), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_claims(), claims);

        // Dust-sized fuzz inputs can leave a recipient with nothing; then there is no event either.
        if (alice != 0) {
            vm.expectEmit(true, false, false, true, address(hook));
            emit FeeSplitHook.Claimed(ALICE, alice);
        } else {
            vm.recordLogs();
        }
        vm.prank(ALICE);
        assertEq(hook.claim(), alice, "claim returns the whole balance");
        if (alice == 0) assertEq(vm.getRecordedLogs().length, 0, "an empty claim emits nothing");
        assertEq(ALICE.balance, alice, "and pays exactly it");
        assertEq(hook.pendingInterface(ALICE), 0);
        assertEq(hook.pendingInterfaceForPool(launchId, ALICE), 0);
        assertEq(hook.pendingInterfaceForPool(otherId, ALICE), 0);
        assertEq(hook.pendingInterface(BOB), bob, "another recipient is untouched");
        assertEq(hook.totalPendingInterface(), bob);
        assertEq(hook.totalPendingLP(), lp, "claim leaves the LP bucket alone");
        assertEq(hook.totalPendingBurn(), burn, "claim leaves the burn bucket alone");
        assertEq(claims - _claims(), alice, "claims burned equal the payout");
        vm.prank(ALICE);
        assertEq(hook.claim(), 0, "nothing left to claim");
        _assertClaimsBacked();

        uint256 perPool = hook.pendingBurn(launchId) + hook.pendingBurn(otherId);
        assertEq(perPool, burn, "burn total is the sum over pools");
        if (burn != 0) {
            vm.expectEmit(false, false, false, true, address(hook));
            emit FeeSplitHook.Burned(burn);
        } else {
            vm.recordLogs();
        }
        vm.prank(CAROL);
        assertEq(hook.burnAccrued(), burn, "burn returns every pool's bucket");
        if (burn == 0) assertEq(vm.getRecordedLogs().length, 0, "an empty burn emits nothing");
        assertEq(DEAD.balance, burn, "and pays exactly it to DEAD");
        assertEq(hook.pendingBurn(launchId), 0);
        assertEq(hook.pendingBurn(otherId), 0);
        assertEq(hook.totalPendingBurn(), 0);
        assertEq(hook.totalPendingLP(), lp, "burn leaves the LP bucket alone");
        assertEq(hook.pendingInterface(BOB), bob, "burn leaves interface credit alone");
        assertEq(_claims(), lp + bob, "only LP and Bob remain");
        assertEq(hook.burnAccrued(), 0, "nothing left to burn");
        _assertClaimsBacked();

        vm.prank(BOB);
        assertEq(hook.claim(), bob);
        assertEq(hook.donateAccrued(launchKey) + hook.donateAccrued(otherKey), lp);
        assertEq(hook.totalPending(), 0, "every bucket was emptied by exactly one payout each");
        assertEq(_claims(), 0);
        assertEq(_lifetimeSnapshot(), lifetimeBefore, "payouts never touch lifetime totals");
        (uint256 lifeI, uint256 lifeL, uint256 lifeB) = _lifetimeSums();
        assertEq(lifeI, alice + bob, "lifetime interface equals what was claimed");
        assertEq(lifeB, burn, "lifetime burn equals what was burned");
        assertEq(lifeL, lp, "lifetime LP equals what was donated");
    }

    function _lifetimeSnapshot() private view returns (bytes32) {
        (uint256 i0, uint256 l0, uint256 b0) = hook.lifetimeTotals(launchId);
        (uint256 i1, uint256 l1, uint256 b1) = hook.lifetimeTotals(otherId);
        return keccak256(abi.encode(i0, l0, b0, i1, l1, b1));
    }

    function _lifetimeSums() private view returns (uint256 i, uint256 l, uint256 b) {
        (uint256 i0, uint256 l0, uint256 b0) = hook.lifetimeTotals(launchId);
        (uint256 i1, uint256 l1, uint256 b1) = hook.lifetimeTotals(otherId);
        return (i0 + i1, l0 + l1, b0 + b1);
    }

    // ---------------------------------------------------------------------------------------------
    // Adversarial: trading against the manager while a claim is being paid.
    // ---------------------------------------------------------------------------------------------

    function test_swapInsideAClaimPayoutKeepsClaimsEqualToLiabilities() public {
        _bootstrapLaunchPool(1 ether);
        ClaimTimeSwapper swapper = new ClaimTimeSwapper(manager, hook, launchKey);
        _swap(launchKey, true, -1 ether, abi.encode(address(swapper)), 10 ether);
        uint256 owed = hook.pendingInterface(address(swapper));
        assertEq(owed, 0.002 ether);
        uint256 claims = _claims();

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeSplitHook.Claimed(address(swapper), owed);
        assertEq(swapper.claim(), owed);
        assertTrue(swapper.swapped(), "the recipient traded during its own payout");

        uint256 innerFee = swapper.innerFee();
        assertEq(innerFee, (owed / 2) / 100, "the nested swap paid its own fee");
        (uint256 i,,) = _split(innerFee, true);
        assertEq(hook.pendingInterface(address(swapper)), i, "the nested credit lands in the new epoch");
        assertEq(hook.pendingInterfaceForPool(launchId, address(swapper)), i);
        assertEq(_claims(), claims - owed + innerFee, "claims: payout burned, nested fee minted");
        assertEq(address(swapper).balance, owed - owed / 2, "the recipient kept what it did not spend");
        assertGt(token.balanceOf(address(swapper)), 0, "and received THRW for the nested buy");
        _assertClaimsBacked();
    }
}
