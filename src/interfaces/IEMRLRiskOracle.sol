// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Read-only risk data consumed by EMRLMMHook when its oracle policy is enabled.
/// @dev `fairTick` is the canonical Uniswap tick for currency1/currency0, not a human token price.
interface IEMRLRiskOracle {
    struct RiskData {
        int24 fairTick;
        uint32 reserveCoverageBps;
        uint32 volatilityBps;
        uint48 updatedAt;
    }

    function latestRiskData() external view returns (RiskData memory data);
}
