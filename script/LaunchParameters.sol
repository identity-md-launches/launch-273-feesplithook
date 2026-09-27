// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Reviewable proposed manifest inputs. The supplied workflow fixes no numeric launch price.
/// @dev Both the manifest contributor and the deployment service must use/reconcile these exact inputs.
library LaunchParameters {
    uint256 internal constant CHAIN_ID = 11155111;
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    // floor(sqrt(1_000_000_000) * 2**96): raw THRW units / raw ETH units (both 18 decimals).
    uint160 internal constant SQRT_PRICE_X96 = 2505414483750479311864138015696063;
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 207240;
    uint256 internal constant SEED_THRW = 1_000_000_000 ether;
}
