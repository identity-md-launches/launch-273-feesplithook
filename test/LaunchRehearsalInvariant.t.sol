// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RehearsalTestBase} from "./helpers/RehearsalTestBase.sol";
import {FeeSplitHook} from "../src/FeeSplitHook.sol";
import {THRW} from "../src/THRW.sol";
import {LaunchParameters} from "../script/LaunchParameters.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Drives the factory-launched pool and a second native pool with an independent ledger.
/// @dev Beyond swaps and payouts, the handler can withdraw every unit of liquidity from the second pool, open
/// and close a JIT position in the launch pool, and ask for fills the pool cannot give. Reverts are caught,
/// classified and asserted: a swap may only fail as a complete PartialFill rollback, a donation only for lack
/// of liquidity with its bucket intact. Anything else fails the campaign.
contract RehearsalHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 private constant Q96 = 1 << 96;
    uint256 private constant Q128 = 1 << 128;
    int24 private constant OTHER_LOWER = -600;
    int24 private constant OTHER_UPPER = 600;
    int256 private constant OTHER_LIQUIDITY = 1_000_000 ether;
    int24 private constant JIT_LOWER = LaunchParameters.TICK_UPPER - 6_000;
    int24 private constant JIT_UPPER = LaunchParameters.TICK_UPPER;
    int256 private constant JIT_LIQUIDITY = 1e20;

    FeeSplitHook private immutable hook;
    IPoolManager private immutable manager;
    PoolSwapTest private immutable router;
    PoolModifyLiquidityTest private immutable liquidityRouter;
    THRW private immutable token;
    MockERC20 private immutable other;
    PoolKey[2] private keys;
    address[3] private recipients = [address(0xA11CE), address(0xB0B), address(0xCA201)];
    bytes private partialFillReason;

    uint256[3][2] private ghostInterface;
    uint256[2] private ghostLP;
    uint256[2] private ghostBurn;
    uint256[3][2] private ghostLifetime;
    uint256 public feesAccrued;
    uint256 public feesPaid;
    uint256 public swaps;
    uint256 public partialFills;
    uint256 public blockedDonations;
    bool public otherLiquidityOpen;
    bool public jitOpen;

    constructor(
        FeeSplitHook hook_,
        IPoolManager manager_,
        THRW token_,
        MockERC20 other_,
        PoolKey memory launchKey,
        PoolKey memory otherKey
    ) {
        hook = hook_;
        manager = manager_;
        token = token_;
        other = other_;
        keys[0] = launchKey;
        keys[1] = otherKey;
        router = new PoolSwapTest(manager_);
        liquidityRouter = new PoolModifyLiquidityTest(manager_);
        token_.approve(address(router), type(uint256).max);
        token_.approve(address(liquidityRouter), type(uint256).max);
        other_.approve(address(router), type(uint256).max);
        other_.approve(address(liquidityRouter), type(uint256).max);
        partialFillReason = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook_),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(FeeSplitHook.PartialFill.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev The first buy into the ETH-less launch pool, and the second pool's only liquidity.
    function bootstrap() external {
        _trade(0, true, -int256(3 ether), 3);
        toggleOtherLiquidity();
    }

    // ------------------------------------------------------------------------------------------ actions

    function swap(uint256 poolSeed, uint256 modeSeed, uint256 size, uint256 identitySeed) external {
        uint256 p = poolSeed % 2;
        uint256 mode = modeSeed % 4;
        int256 specified = _size(p, mode, size);
        if (specified == 0) return;
        _trade(p, mode < 2, specified, identitySeed % 5);
    }

    function claim(uint256 seed) external {
        uint256 index = seed % 3;
        uint256 expected = ghostInterface[0][index] + ghostInterface[1][index];
        uint256 beforeBalance = recipients[index].balance;
        vm.prank(recipients[index]);
        assertEq(hook.claim(), expected, "claim pays exactly the ledger's balance");
        assertEq(recipients[index].balance - beforeBalance, expected);
        feesPaid += expected;
        ghostInterface[0][index] = 0;
        ghostInterface[1][index] = 0;
    }

    function burn() external {
        uint256 expected = ghostBurn[0] + ghostBurn[1];
        uint256 beforeBalance = address(0xdead).balance;
        assertEq(hook.burnAccrued(), expected, "burn pays exactly both pools' buckets");
        assertEq(address(0xdead).balance - beforeBalance, expected);
        feesPaid += expected;
        ghostBurn[0] = 0;
        ghostBurn[1] = 0;
    }

    function donate(uint256 seed) external {
        uint256 index = seed % 2;
        PoolId id = keys[index].toId();
        uint256 expected = ghostLP[index];
        if (expected == 0) {
            assertEq(hook.donateAccrued(keys[index]), 0, "nothing to donate, nothing happens");
            return;
        }
        uint128 liquidity = manager.getLiquidity(id);
        if (liquidity == 0) {
            uint256 claims = manager.balanceOf(address(hook), 0);
            (bool ok, bytes memory reason) =
                address(hook).call(abi.encodeCall(hook.donateAccrued, (keys[index])));
            assertFalse(ok, "a donation to nobody must revert");
            assertEq(reason, abi.encodeWithSelector(Pool.NoLiquidityToReceiveFees.selector));
            assertEq(hook.pendingLP(id), expected, "the bucket survives the failed donation");
            assertEq(manager.balanceOf(address(hook), 0), claims, "no claims were burned");
            ++blockedDonations;
            return;
        }
        (uint256 growthBefore,) = manager.getFeeGrowthGlobals(id);
        uint256 managerETH = address(manager).balance;
        assertEq(hook.donateAccrued(keys[index]), expected, "donation pays exactly the ledger's bucket");
        (uint256 growthAfter,) = manager.getFeeGrowthGlobals(id);
        assertEq(growthAfter - growthBefore, FullMath.mulDiv(expected, Q128, liquidity), "growth per unit");
        assertEq(address(manager).balance, managerETH, "donation keeps the ETH in the manager");
        feesPaid += expected;
        ghostLP[index] = 0;
    }

    /// @dev The second pool's only liquidity comes and goes, so zero-liquidity states are reachable.
    function toggleOtherLiquidity() public {
        int256 delta = otherLiquidityOpen ? -OTHER_LIQUIDITY : OTHER_LIQUIDITY;
        liquidityRouter.modifyLiquidity{value: otherLiquidityOpen ? 0 : 40_000 ether}(
            keys[1], ModifyLiquidityParams(OTHER_LOWER, OTHER_UPPER, delta, 0), ""
        );
        otherLiquidityOpen = !otherLiquidityOpen;
        assertEq(manager.getLiquidity(keys[1].toId()), otherLiquidityOpen ? uint256(OTHER_LIQUIDITY) : 0);
    }

    /// @dev A late LP in the launch pool, sharing the seed's upper tick, opened and closed at will.
    function toggleLaunchJit() external {
        if (!jitOpen && token.balanceOf(address(this)) < 1_000_000 ether) return;
        int256 delta = jitOpen ? -JIT_LIQUIDITY : JIT_LIQUIDITY;
        liquidityRouter.modifyLiquidity{value: jitOpen ? 0 : 10 ether}(
            keys[0], ModifyLiquidityParams(JIT_LOWER, JIT_UPPER, delta, 0), ""
        );
        jitOpen = !jitOpen;
    }

    // ------------------------------------------------------------------------------------------ checks

    function assertAccounting() external view {
        uint256 interfaceSum;
        uint256 lpSum;
        uint256 burnSum;
        for (uint256 p; p < 2; ++p) {
            PoolId id = keys[p].toId();
            assertEq(hook.pendingLP(id), ghostLP[p], "pool LP bucket");
            assertEq(hook.pendingBurn(id), ghostBurn[p], "pool burn bucket");
            lpSum += ghostLP[p];
            burnSum += ghostBurn[p];
            for (uint256 r; r < 3; ++r) {
                assertEq(hook.pendingInterfaceForPool(id, recipients[r]), ghostInterface[p][r], "pool credit");
                interfaceSum += ghostInterface[p][r];
            }
            (uint256 i, uint256 l, uint256 b) = hook.lifetimeTotals(id);
            assertEq(i, ghostLifetime[p][0], "lifetime interface");
            assertEq(l, ghostLifetime[p][1], "lifetime LP");
            assertEq(b, ghostLifetime[p][2], "lifetime burn");
        }
        for (uint256 r; r < 3; ++r) {
            assertEq(hook.pendingInterface(recipients[r]), ghostInterface[0][r] + ghostInterface[1][r]);
        }
        assertEq(hook.pendingInterface(address(0)), 0, "the zero address never accrues");
        assertEq(hook.pendingInterface(address(router)), 0, "the router never accrues");
        assertEq(hook.pendingInterface(address(this)), 0, "the swapper never accrues without naming itself");
        assertEq(hook.totalPendingInterface(), interfaceSum);
        assertEq(hook.totalPendingLP(), lpSum);
        assertEq(hook.totalPendingBurn(), burnSum);
        uint256 claims = manager.balanceOf(address(hook), 0);
        assertEq(claims, interfaceSum + lpSum + burnSum, "ETH claims equal every outstanding bucket");
        assertEq(claims, hook.totalPending());
        assertEq(claims + feesPaid, feesAccrued, "every fee ever charged is either paid or pending");
        assertGe(address(manager).balance, claims, "the manager holds the ETH behind every claim");
    }

    /// @dev Pays everything out; restores liquidity first where a pool has none.
    function drain() external {
        for (uint256 r; r < 3; ++r) {
            this.claim(r);
        }
        this.burn();
        if (ghostLP[1] != 0 && !otherLiquidityOpen) toggleOtherLiquidity();
        if (ghostLP[0] != 0 && manager.getLiquidity(keys[0].toId()) == 0) {
            _trade(0, true, -int256(0.01 ether), 3);
        }
        this.donate(0);
        this.donate(1);
        for (uint256 r; r < 3; ++r) {
            this.claim(r);
        }
        this.burn();
    }

    // ------------------------------------------------------------------------------------------ internals

    function _size(uint256 p, uint256 mode, uint256 size) private view returns (int256) {
        bool buy = mode < 2;
        bool exactIn = mode % 2 == 0;
        if (p == 1) {
            int256 magnitude = int256(bound(size, 1, 2 ether));
            return exactIn ? -magnitude : magnitude;
        }
        if (buy && exactIn) return -int256(bound(size, 1, 0.5 ether));
        if (buy) return int256(bound(size, 1, 1_000_000 ether));
        uint256 held = token.balanceOf(address(this));
        if (held == 0) return 0;
        if (exactIn) return -int256(bound(size, 1, held / 8 == 0 ? 1 : held / 8));
        // Exact ETH out: stay well inside the pool's ETH so the price impact is small, then check the
        // THRW that would be needed at the current price with a generous margin. A pool with no ETH
        // (price parked on the seed's upper tick) offers nothing to sell into.
        PoolId id = keys[0].toId();
        (uint160 sqrtP,,,) = manager.getSlot0(id);
        uint128 liquidity = manager.getLiquidity(id);
        uint256 reserve = SqrtPriceMath.getAmount0Delta(
            sqrtP, TickMath.getSqrtPriceAtTick(LaunchParameters.TICK_UPPER), liquidity, false
        );
        if (reserve < 2_000) return 0;
        uint256 ethOut = bound(size, 1, reserve / 20 > 0.05 ether ? 0.05 ether : reserve / 20);
        uint256 priceX96 = FullMath.mulDiv(sqrtP, sqrtP, Q96);
        uint256 needed = FullMath.mulDiv(ethOut + ethOut / 100, priceX96, Q96) * 3 / 2 + 1;
        if (held < needed) return 0;
        return int256(ethOut);
    }

    function _trade(uint256 p, bool buy, int256 specified, uint256 identity) private {
        bytes memory data;
        if (identity < 3) data = abi.encode(recipients[identity]);
        else if (identity == 4) data = abi.encode((uint256(1) << 160) | uint160(recipients[0]));
        PoolId id = keys[p].toId();
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        uint256 pendingBefore = hook.totalPending();
        (uint160 priceBefore,,,) = manager.getSlot0(id);

        try router.swap{value: buy ? 50 ether : 0}(
            keys[p],
            SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        ) returns (
            BalanceDelta delta
        ) {
            uint256 fee = manager.balanceOf(address(hook), 0) - claimsBefore;
            bool ethSpecified = buy == (specified < 0);
            assertEq(
                int256(ethSpecified ? delta.amount0() : delta.amount1()), specified, "specified honoured"
            );
            uint256 ethLeg;
            if (ethSpecified) ethLeg = uint256(specified < 0 ? -specified : specified);
            else if (buy) ethLeg = uint256(-int256(delta.amount0())) - fee;
            else ethLeg = uint256(int256(delta.amount0())) + fee;
            assertEq(fee, ethLeg / 100, "fee is 1% of the ETH leg");
            _record(p, fee, identity < 3 ? identity : 3);
            ++swaps;
        } catch (bytes memory reason) {
            assertEq(reason, partialFillReason, "a swap may only fail as a partial fill");
            assertEq(manager.balanceOf(address(hook), 0), claimsBefore, "partial fill minted nothing");
            assertEq(hook.totalPending(), pendingBefore, "partial fill credited nothing");
            (uint160 priceAfter,,,) = manager.getSlot0(id);
            assertEq(priceAfter, priceBefore, "partial fill moved nothing");
            ++partialFills;
        }
    }

    function _record(uint256 p, uint256 fee, uint256 identity) private {
        uint256 interfaceShare = identity == 3 ? 0 : fee * 2_000 / 10_000;
        uint256 lpShare = fee * 3_000 / 10_000;
        uint256 burnShare = fee - interfaceShare - lpShare;
        if (identity != 3) ghostInterface[p][identity] += interfaceShare;
        ghostLP[p] += lpShare;
        ghostBurn[p] += burnShare;
        ghostLifetime[p][0] += interfaceShare;
        ghostLifetime[p][1] += lpShare;
        ghostLifetime[p][2] += burnShare;
        feesAccrued += fee;
    }

    receive() external payable {}
}

contract LaunchRehearsalInvariantTest is RehearsalTestBase {
    using StateLibrary for IPoolManager;

    RehearsalHandler internal handler;

    function setUp() public override {
        super.setUp();
        // The handler must own every unit of the second pool's liquidity so it can take it all away.
        liquidityRouter.modifyLiquidity(
            otherKey, ModifyLiquidityParams(OTHER_LOWER, OTHER_UPPER, -int256(OTHER_LIQUIDITY), 0), ""
        );
        assertEq(manager.getLiquidity(otherId), 0);

        handler = new RehearsalHandler(hook, manager, token, other, launchKey, otherKey);
        vm.deal(address(handler), 1_000_000 ether);
        other.transfer(address(handler), 100_000_000 ether);
        handler.bootstrap();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.burn.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.toggleOtherLiquidity.selector;
        selectors[5] = handler.toggleLaunchJit.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @notice The hook's ETH claims at the manager equal everything it still owes, across both pools.
    function invariant_claimsEqualEveryOutstandingBucketAcrossPools() public view {
        handler.assertAccounting();
    }

    /// @notice The hook holds nothing but ETH claims: no ETH, no tokens, no claims in other currencies.
    function invariant_hookCustodiesNothingButEthClaims() public view {
        _assertClaimsBacked();
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no THRW claims");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(other)))), 0, "no other claims");
    }

    function afterInvariant() public virtual {
        handler.drain();
        handler.assertAccounting();
        assertEq(hook.totalPending(), 0, "everything owed was paid");
        assertEq(_claims(), 0, "and nothing is left at the manager in the hook's name");
        assertEq(handler.feesAccrued(), handler.feesPaid(), "lifetime fees equal lifetime payouts");
    }
}
