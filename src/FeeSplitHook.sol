// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable 1% ETH-leg fee; 20% interface, 30% current LPs, remainder sent to DEAD.
/// @dev Fees are ERC-6909 claims, never native transfers during swaps. No owner or privileged entrypoint.
contract FeeSplitHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant INTERFACE_BPS = 2_000;
    uint256 public constant LP_BPS = 3_000;
    uint256 public constant BURN_BPS = 5_000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;

    struct Totals {
        uint256 interfaceTotal;
        uint256 lpTotal;
        uint256 burnTotal;
    }

    // Epochs allow an O(1) aggregate payout to invalidate its per-pool pending views without enumeration.
    struct Credit {
        uint256 epoch;
        uint256 amount;
    }

    mapping(PoolId => Totals) public lifetimeTotals;
    mapping(PoolId => uint256) public pendingLP;
    mapping(address => uint256) public pendingInterface;
    mapping(PoolId => mapping(address => Credit)) private _interfaceCredits;
    mapping(address => uint256) private _interfaceEpoch;
    mapping(PoolId => Credit) private _burnCredits;
    uint256 private _burnEpoch;

    uint256 public totalPendingInterface;
    uint256 public totalPendingLP;
    uint256 public totalPendingBurn;

    enum Action {
        Claim,
        Burn,
        Donate
    }

    bool private _unlocking;

    error NotPoolManager();
    error InvalidPoolManager();
    error InvalidPool();
    error PartialFill();
    error SwapAmountTooLarge();
    error ReentrantPayout();
    error UnexpectedUnlock();

    event FeeSplit(
        PoolId indexed poolId,
        address indexed interfaceAddress,
        uint256 fee,
        uint256 interfaceShare,
        uint256 lpShare,
        uint256 burnShare
    );
    event Donated(PoolId indexed poolId, uint256 amount);
    event Burned(uint256 amount);
    event Claimed(address indexed interfaceAddress, uint256 amount);

    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert InvalidPoolManager();
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier payoutLock() {
        if (_unlocking) revert ReentrantPayout();
        _unlocking = true;
        _;
        _unlocking = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.currency0.isAddressZero() || !_ethSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        uint256 fee = _specifiedFee(params.amountSpecified);
        _accrue(key.toId(), fee, hookData);
        // The fee reduces exact-in ETH going to the AMM, or increases gross exact-out ETH from it.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);

        bool ethSpecified = _ethSpecified(params);
        int256 expected = params.amountSpecified;
        if (ethSpecified) expected += int256(_specifiedFee(expected));
        int256 actual = ethSpecified ? int256(delta.amount0()) : int256(delta.amount1());
        // Compare AMM movement with the amount after beforeSwap's adjustment. Any price-limit shortfall
        // rolls back the complete swap, including already-minted claims and FeeSplit events.
        if (actual != expected) revert PartialFill();
        if (ethSpecified) return (IHooks.afterSwap.selector, 0);

        int256 ethMoved = int256(delta.amount0());
        uint256 fee = uint256(ethMoved < 0 ? -ethMoved : ethMoved) * FEE_BPS / BPS;
        _accrue(key.toId(), fee, hookData);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice Redeem all of the caller's interface fees, across all pools, to the caller.
    function claim() external payoutLock returns (uint256 amount) {
        amount = pendingInterface[msg.sender];
        if (amount == 0) return 0;
        pendingInterface[msg.sender] = 0;
        totalPendingInterface -= amount;
        ++_interfaceEpoch[msg.sender];
        poolManager.unlock(abi.encode(Action.Claim, msg.sender, amount));
        emit Claimed(msg.sender, amount);
    }

    /// @notice Redeem all burn buckets to the immutable DEAD address. Callable by anyone.
    function burnAccrued() external payoutLock returns (uint256 amount) {
        amount = totalPendingBurn;
        if (amount == 0) return 0;
        totalPendingBurn = 0;
        ++_burnEpoch;
        poolManager.unlock(abi.encode(Action.Burn, BURN_ADDRESS, amount));
        emit Burned(amount);
    }

    /// @notice Donate only this pool's LP bucket to liquidity in range at execution time.
    /// @dev With no active liquidity, PoolManager.donate reverts and restores the pending bucket.
    function donateAccrued(PoolKey calldata key) external payoutLock returns (uint256 amount) {
        if (!key.currency0.isAddressZero() || address(key.hooks) != address(this)) revert InvalidPool();
        PoolId id = key.toId();
        amount = pendingLP[id];
        if (amount == 0) return 0;
        pendingLP[id] = 0;
        totalPendingLP -= amount;
        poolManager.unlock(abi.encode(Action.Donate, key, amount));
        emit Donated(id, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_unlocking) revert UnexpectedUnlock();
        Action action = abi.decode(data, (Action));
        if (action == Action.Donate) {
            (, PoolKey memory key, uint256 amount) = abi.decode(data, (Action, PoolKey, uint256));
            // Burning is a positive credit; donating consumes it. ETH stays in the manager.
            poolManager.burn(address(this), 0, amount);
            poolManager.donate(key, amount, 0, "");
        } else {
            (, address recipient, uint256 amount) = abi.decode(data, (Action, address, uint256));
            poolManager.burn(address(this), 0, amount);
            poolManager.take(Currency.wrap(address(0)), recipient, amount);
        }
        return "";
    }

    function pendingInterfaceForPool(PoolId id, address recipient) external view returns (uint256) {
        Credit storage credit = _interfaceCredits[id][recipient];
        return credit.epoch == _interfaceEpoch[recipient] ? credit.amount : 0;
    }

    function pendingBurn(PoolId id) external view returns (uint256) {
        Credit storage credit = _burnCredits[id];
        return credit.epoch == _burnEpoch ? credit.amount : 0;
    }

    function totalPending() external view returns (uint256) {
        return totalPendingInterface + totalPendingLP + totalPendingBurn;
    }

    function _ethSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _specifiedFee(int256 amount) private pure returns (uint256) {
        // Bound before negation and casting; all v4 balance deltas must fit int128.
        if (amount < -int256(type(int128).max) || amount > int256(type(int128).max)) {
            revert SwapAmountTooLarge();
        }
        return uint256(amount < 0 ? -amount : amount) * FEE_BPS / BPS;
    }

    function _accrue(PoolId id, uint256 fee, bytes calldata hookData) private {
        address recipient = address(0);
        if (hookData.length == 32) {
            uint256 word = uint256(bytes32(hookData));
            // abi.decode(address) rejects dirty high bits. Treat those malformed bytes as no identity.
            if (word <= type(uint160).max) recipient = address(uint160(word));
        }
        uint256 interfaceShare = recipient == address(0) ? 0 : fee * INTERFACE_BPS / BPS;
        uint256 lpShare = fee * LP_BPS / BPS;
        uint256 burnShare = fee - interfaceShare - lpShare;

        if (fee != 0) {
            Totals storage totals = lifetimeTotals[id];
            totals.interfaceTotal += interfaceShare;
            totals.lpTotal += lpShare;
            totals.burnTotal += burnShare;

            if (interfaceShare != 0) {
                Credit storage credit = _interfaceCredits[id][recipient];
                if (credit.epoch != _interfaceEpoch[recipient]) {
                    credit.epoch = _interfaceEpoch[recipient];
                    credit.amount = 0;
                }
                credit.amount += interfaceShare;
                pendingInterface[recipient] += interfaceShare;
                totalPendingInterface += interfaceShare;
            }
            pendingLP[id] += lpShare;
            totalPendingLP += lpShare;
            Credit storage burnCredit = _burnCredits[id];
            if (burnCredit.epoch != _burnEpoch) {
                burnCredit.epoch = _burnEpoch;
                burnCredit.amount = 0;
            }
            burnCredit.amount += burnShare;
            totalPendingBurn += burnShare;
            poolManager.mint(address(this), 0, fee);
        }
        emit FeeSplit(id, recipient, fee, interfaceShare, lpShare, burnShare);
    }
}
