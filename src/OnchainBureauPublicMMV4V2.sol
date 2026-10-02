// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { BaseHook } from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Public-pool routing candidate. Approval by any router is NOT guaranteed.
/// @dev New contract, not an upgrade of OnchainBureauMMv4. No LP callbacks, swap
///      pause, permission lists, external risk oracle, upgrade path or return deltas.
///      Admin/operator powers affect bounded LP fees and optional telemetry only
///      after permissionless one-time canonical initialization at the fixed price. No custom hookData is needed.
contract OnchainBureauPublicMMV4V2 is BaseHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 public constant REQUIRED_HOOK_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    uint24 public constant MIN_ALLOWED_FEE = 500; // 0.05%, native v4 fee units
    uint24 public constant MAX_ALLOWED_FEE = 25_000; // 2.50%; cannot be raised
    address public immutable EMRL;
    address public immutable USDG;
    Currency public immutable currency0;
    Currency public immutable currency1;
    bool public immutable emrlIsCurrency0;
    int24 public immutable approvedTickSpacing;
    uint160 public immutable approvedInitialSqrtPriceX96;
    PoolId public immutable canonicalPoolId;

    address public mmOperator;
    bool public poolInitialized;
    uint24 public normalFee;
    uint24 public usdToEmrlFee;
    uint24 public emrlToUsdFee;
    uint24 public fallbackFee;
    bool public directionalFeesEnabled;
    bool public fallbackMode;
    bool public inventoryBiasEnabled;
    int24 public inventoryFeeBias;
    bool public rangeTelemetryEnabled;
    bool public monitoredRangeConfigured;
    int24 public monitoredTickLower;
    int24 public monitoredTickUpper;

    error InvalidConfiguration();
    error FeeOutOfBounds();
    error UnauthorizedOperator();
    error UnexpectedPool();
    error InvalidInitialization();

    event FeesUpdated(uint24 normal, uint24 buy, uint24 sell, uint24 fallbackValue);
    event OperatorUpdated(address indexed operator);
    event FeePolicyUpdated(bool directional, bool fallbackValue, bool inventoryBias, int24 bias);
    event TelemetryPolicyUpdated(bool enabled, int24 lower, int24 upper);
    event CanonicalPoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);
    event SwapTelemetry(
        PoolId indexed poolId, address indexed router, bool zeroForOne, int128 amount0, int128 amount1, int24 endingTick
    );

    modifier onlyMMOperator() {
        if (msg.sender != mmOperator) revert UnauthorizedOperator();
        _;
    }

    constructor(
        IPoolManager manager,
        address emrl,
        address usdg,
        int24 spacing,
        uint160 initialPrice,
        address admin,
        address operator,
        uint24 initialFee,
        uint24 emergencyFee
    ) BaseHook(manager) Ownable(admin) {
        if (
            address(manager).code.length == 0 || emrl == address(0) || usdg == address(0) || emrl == usdg
                || operator == address(0) || spacing < TickMath.MIN_TICK_SPACING || spacing > TickMath.MAX_TICK_SPACING
                || initialPrice < TickMath.MIN_SQRT_PRICE || initialPrice >= TickMath.MAX_SQRT_PRICE
        ) revert InvalidConfiguration();
        _checkFee(initialFee);
        _checkFee(emergencyFee);
        EMRL = emrl;
        USDG = usdg;
        emrlIsCurrency0 = emrl < usdg;
        currency0 = Currency.wrap(emrl < usdg ? emrl : usdg);
        currency1 = Currency.wrap(emrl < usdg ? usdg : emrl);
        approvedTickSpacing = spacing;
        approvedInitialSqrtPriceX96 = initialPrice;
        mmOperator = operator;
        normalFee = initialFee;
        usdToEmrlFee = initialFee;
        emrlToUsdFee = initialFee;
        fallbackFee = emergencyFee;
        canonicalPoolId =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(address(this))).toId();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    // Legacy MM preflight compatibility only. There are no corresponding setters,
    // LP callbacks or access restrictions; these values cannot change.
    function liquidityAdditionsPaused() external pure returns (bool) {
        return false;
    }

    function liquidityAccessMode() external pure returns (uint8) {
        return 0;
    }

    function mmLiquidityProvider() external pure returns (address) {
        return address(0);
    }

    function trustedLiquidityRouters(address) external pure returns (bool) {
        return false;
    }

    function allowedLiquidityProviders(address) external pure returns (bool) {
        return false;
    }

    function feeForSwap(bool zeroForOne) public view returns (uint24) {
        if (fallbackMode) return fallbackFee;
        bool buy = emrlIsCurrency0 ? !zeroForOne : zeroForOne;
        uint24 base = directionalFeesEnabled ? (buy ? usdToEmrlFee : emrlToUsdFee) : normalFee;
        int256 value = int256(uint256(base));
        if (inventoryBiasEnabled) value += buy ? int256(inventoryFeeBias) : -int256(inventoryFeeBias);
        if (value < int256(uint256(MIN_ALLOWED_FEE))) return MIN_ALLOWED_FEE;
        if (value > int256(uint256(MAX_ALLOWED_FEE))) return MAX_ALLOWED_FEE;
        return uint24(uint256(value));
    }

    function _checkFee(uint24 fee) private pure {
        if (fee < MIN_ALLOWED_FEE || fee > MAX_ALLOWED_FEE) revert FeeOutOfBounds();
    }

    function _feesEvent() private {
        emit FeesUpdated(normalFee, usdToEmrlFee, emrlToUsdFee, fallbackFee);
    }

    function _policyEvent() private {
        emit FeePolicyUpdated(directionalFeesEnabled, fallbackMode, inventoryBiasEnabled, inventoryFeeBias);
    }

    function setMMOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert InvalidConfiguration();
        mmOperator = operator;
        emit OperatorUpdated(operator);
    }

    function setNormalFee(uint24 fee) external onlyOwner {
        _checkFee(fee);
        normalFee = fee;
        _feesEvent();
    }

    function setFallbackFee(uint24 fee) external onlyOwner {
        _checkFee(fee);
        fallbackFee = fee;
        _feesEvent();
    }

    function setDirectionalFees(uint24 buy, uint24 sell) external onlyMMOperator {
        _checkFee(buy);
        _checkFee(sell);
        usdToEmrlFee = buy;
        emrlToUsdFee = sell;
        _feesEvent();
    }

    function setDirectionalFeesEnabled(bool enabled) external onlyOwner {
        directionalFeesEnabled = enabled;
        _policyEvent();
    }

    function setFallbackMode(bool enabled) external onlyOwner {
        fallbackMode = enabled;
        _policyEvent();
    }

    function setInventoryBiasEnabled(bool enabled) external onlyOwner {
        inventoryBiasEnabled = enabled;
        _policyEvent();
    }

    function setInventoryFeeBias(int24 bias) external onlyMMOperator {
        if (
            int256(bias) > int256(uint256(MAX_ALLOWED_FEE - MIN_ALLOWED_FEE))
                || int256(bias) < -int256(uint256(MAX_ALLOWED_FEE - MIN_ALLOWED_FEE))
        ) revert FeeOutOfBounds();
        inventoryFeeBias = bias;
        _policyEvent();
    }

    function setMonitoredRange(int24 lower, int24 upper) external onlyMMOperator {
        if (
            lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % approvedTickSpacing != 0
                || upper % approvedTickSpacing != 0
        ) revert InvalidConfiguration();
        monitoredTickLower = lower;
        monitoredTickUpper = upper;
        monitoredRangeConfigured = true;
        emit TelemetryPolicyUpdated(rangeTelemetryEnabled, lower, upper);
    }

    function setRangeTelemetryEnabled(bool enabled) external onlyOwner {
        rangeTelemetryEnabled = enabled;
        emit TelemetryPolicyUpdated(enabled, monitoredTickLower, monitoredTickUpper);
    }

    function _validate(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(canonicalPoolId)) revert UnexpectedPool();
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160 price) internal view override returns (bytes4) {
        _validate(key);
        if (poolInitialized || price != approvedInitialSqrtPriceX96) {
            revert InvalidInitialization();
        }
        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160 price, int24 tick)
        internal
        override
        returns (bytes4)
    {
        _validate(key);
        if (poolInitialized || price != approvedInitialSqrtPriceX96) revert InvalidInitialization();
        poolInitialized = true;
        emit CanonicalPoolInitialized(canonicalPoolId, price, tick);
        return IHooks.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validate(key);
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeForSwap(params.zeroForOne) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _validate(key);
        if (rangeTelemetryEnabled) {
            (, int24 tick,,) = poolManager.getSlot0(canonicalPoolId);
            emit SwapTelemetry(canonicalPoolId, sender, params.zeroForOne, delta.amount0(), delta.amount1(), tick);
        }
        return (IHooks.afterSwap.selector, 0);
    }
}
