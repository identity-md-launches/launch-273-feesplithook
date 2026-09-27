// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {THRW} from "../../src/THRW.sol";
import {FeeSplitHook} from "../../src/FeeSplitHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {LaunchParameters} from "../../script/LaunchParameters.sol";
import {LaunchFactory} from "./LaunchFactory.sol";
import {HookMiner} from "./HookMiner.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
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

/// @notice Factory-style launch rehearsal shared by the fuzz and invariant extensions.
/// @dev The launch pool is opened exactly as the local factory harness does it: the whole THRW supply
/// minted to the factory, the hook CREATE2-deployed at a mined 0x00CC address, the pool initialized at
/// the proposed manifest price and seeded one-sided with THRW only. A second native-ETH pool with an
/// unrelated ERC-20 shares the same hook so cross-pool accounting can be observed. Nothing here is a
/// Sepolia fork.
abstract contract RehearsalTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant Q96 = 1 << 96;
    uint256 internal constant Q128 = 1 << 128;
    int24 internal constant OTHER_LOWER = -600;
    int24 internal constant OTHER_UPPER = 600;
    uint256 internal constant OTHER_LIQUIDITY = 1_000_000 ether;
    bytes32 internal constant FEE_SPLIT_TOPIC =
        keccak256("FeeSplit(bytes32,address,uint256,uint256,uint256,uint256)");
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager internal manager;
    LaunchFactory internal factory;
    FeeSplitHook internal hook;
    THRW internal token;
    MockERC20 internal other;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal launchKey;
    PoolKey internal otherKey;
    PoolId internal launchId;
    PoolId internal otherId;

    function setUp() public virtual {
        vm.chainId(LaunchParameters.CHAIN_ID);
        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new LaunchFactory(manager);
        (bytes32 salt, address expected) = HookMiner.find(address(factory), manager);
        launchKey = factory.launch(salt);
        hook = factory.hook();
        token = factory.token();
        assertEq(address(hook), expected, "hook landed on the mined address");
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.FEE_SPLIT);
        launchId = launchKey.toId();

        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);

        other = new MockERC20("Other", "OTHER", 1_000_000_000 ether);
        other.approve(address(router), type(uint256).max);
        other.approve(address(liquidityRouter), type(uint256).max);
        otherKey = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(other)), 3000, 60, IHooks(address(hook))
        );
        otherId = otherKey.toId();
        vm.deal(address(this), 1_000_000 ether);
        manager.initialize(otherKey, Q96);
        liquidityRouter.modifyLiquidity{value: 40_000 ether}(
            otherKey, ModifyLiquidityParams(OTHER_LOWER, OTHER_UPPER, int256(OTHER_LIQUIDITY), 0), ""
        );
    }

    /// @dev Buys into the ETH-less launch pool so later tests hold THRW and the pool holds ETH.
    function _bootstrapLaunchPool(uint256 ethIn) internal {
        assertEq(manager.getLiquidity(launchId), 0, "seed sits entirely below the launch price");
        _swap(launchKey, true, -int256(ethIn), "", ethIn);
        assertGt(manager.getLiquidity(launchId), 0, "first buy enters the seeded range");
    }

    function _swap(PoolKey memory poolKey, bool buy, int256 amount, bytes memory data, uint256 value)
        internal
        returns (BalanceDelta)
    {
        return router.swap{value: buy ? value : 0}(
            poolKey,
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
    }

    /// @dev The split rule as the workflow states it, computed independently of the hook.
    function _split(uint256 fee, bool identity)
        internal
        pure
        returns (uint256 interfaceShare, uint256 lpShare, uint256 burnShare)
    {
        interfaceShare = identity ? fee * 2_000 / 10_000 : 0;
        lpShare = fee * 3_000 / 10_000;
        burnShare = fee - interfaceShare - lpShare;
    }

    /// @dev The identity rule as the workflow states it: exactly 32 bytes decoding to a nonzero address.
    function _identity(bytes memory data) internal pure returns (address) {
        if (data.length != 32) return address(0);
        uint256 word = abi.decode(data, (uint256));
        if (word == 0 || word > type(uint160).max) return address(0);
        return address(uint160(word));
    }

    struct Split {
        PoolId id;
        address recipient;
        uint256 fee;
        uint256 interfaceShare;
        uint256 lpShare;
        uint256 burnShare;
    }

    /// @dev Exactly one FeeSplit from the hook in the recorded logs, decoded.
    function _onlyFeeSplit(Vm.Log[] memory logs) internal view returns (Split memory split) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != FEE_SPLIT_TOPIC) continue;
            ++count;
            split.id = PoolId.wrap(logs[i].topics[1]);
            split.recipient = address(uint160(uint256(logs[i].topics[2])));
            (split.fee, split.interfaceShare, split.lpShare, split.burnShare) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
        }
        assertEq(count, 1, "exactly one FeeSplit per ETH-pool swap");
    }

    function _claims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), 0);
    }

    /// @dev Claims equal liabilities, liabilities decompose over both pools, and the manager holds the ETH.
    function _assertClaimsBacked() internal view {
        uint256 claims = _claims();
        assertEq(claims, hook.totalPending(), "claims == everything still owed");
        assertEq(
            hook.totalPending(),
            hook.totalPendingInterface() + hook.totalPendingLP() + hook.totalPendingBurn(),
            "totalPending is the sum of the three buckets"
        );
        assertEq(hook.pendingLP(launchId) + hook.pendingLP(otherId), hook.totalPendingLP(), "LP per pool");
        assertEq(
            hook.pendingBurn(launchId) + hook.pendingBurn(otherId), hook.totalPendingBurn(), "burn per pool"
        );
        assertGe(address(manager).balance, claims, "every claim is backed by ETH held at the manager");
        assertEq(address(hook).balance, 0, "the hook never custodies ETH");
        assertEq(token.balanceOf(address(hook)), 0, "the hook never custodies THRW");
        assertEq(other.balanceOf(address(hook)), 0, "the hook never custodies the other token");
    }

    receive() external payable {}
}
