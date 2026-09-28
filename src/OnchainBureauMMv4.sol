// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IEMRLRiskOracle } from "./interfaces/IEMRLRiskOracle.sol";
import { BaseHook } from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IMsgSender } from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title OnchainBureauMMv4
/// @notice Single-pool policy and bounded dynamic-fee hook for the canonical EMRL.X/USDG market.
/// @dev This immutable hook never takes custody, changes swap settlement, or receives a return delta. Its address must
///      encode exactly BEFORE_INITIALIZE, AFTER_INITIALIZE, BEFORE_ADD_LIQUIDITY, BEFORE_SWAP and AFTER_SWAP (0x38c0).
///      No remove-liquidity callback is enabled, so the hook cannot intercept or block ordinary LP withdrawals.
contract OnchainBureauMMv4 is BaseHook, Ownable2Step {
    using BalanceDeltaLibrary for BalanceDelta;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    enum RiskMode {
        NORMAL,
        BLOCK_EMRL_BUYS,
        HALT_ALL
    }

    enum LiquidityAccessMode {
        OPEN,
        ALLOWLIST,
        MM_ONLY
    }

    struct RiskPolicy {
        uint48 maxOracleAge;
        uint32 minimumReserveCoverageBps;
        uint32 volatilityThresholdBps;
        uint24 maximumNavDeviationTicks;
        uint24 highVolatilityFee;
    }

    uint160 public constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    uint256 public constant RISK_ORACLE_GAS_LIMIT = 50_000;

    address public immutable EMRL;
    address public immutable USDG;
    Currency public immutable currency0;
    Currency public immutable currency1;
    bool public immutable emrlIsCurrency0;
    int24 public immutable approvedTickSpacing;
    uint160 public immutable approvedInitialSqrtPriceX96;
    uint24 public immutable MIN_ALLOWED_FEE;
    uint24 public immutable MAX_ALLOWED_FEE;
    PoolId public immutable canonicalPoolId;

    // These four uint24 values pack with the operator address into one slot.
    address public mmOperator;
    uint24 public normalFee;
    uint24 public usdToEmrlFee;
    uint24 public emrlToUsdFee;
    uint24 public fallbackFee;

    bool public fallbackMode;
    bool public directionalFeesEnabled;
    bool public liquidityAdditionsPaused;
    bool public minimumRangeWidthEnabled;
    bool public poolInitialized;
    uint24 public minimumRangeWidth;

    // All extended policies default to disabled/OPEN/NORMAL and do not alter V1 behavior until explicitly enabled.
    RiskMode public riskMode;
    LiquidityAccessMode public liquidityAccessMode;
    bool public oraclePolicyEnabled;
    bool public inventoryBiasEnabled;
    bool public protectedRangeEnabled;
    bool public rangeTelemetryEnabled;
    bool public monitoredRangeConfigured;
    int24 public inventoryFeeBias;
    int24 public protectedTickLower;
    int24 public protectedTickUpper;
    int24 public monitoredTickLower;
    int24 public monitoredTickUpper;
    int24 public lastObservedTick;
    address public riskOracle;
    address public mmLiquidityProvider;
    RiskPolicy public riskPolicy;

    mapping(address router => bool trusted) public trustedLiquidityRouters;
    mapping(address provider => bool allowed) public allowedLiquidityProviders;

    error ZeroAddress();
    error IdenticalCurrencies();
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidInitialSqrtPrice(uint160 sqrtPriceX96);
    error InvalidFeeBounds(uint24 minimumFee, uint24 maximumFee);
    error FeeOutOfBounds(uint24 fee);
    error NotMMOperator(address caller);
    error UnexpectedCurrencies(address actualCurrency0, address actualCurrency1);
    error DynamicFeeRequired(uint24 actualFee);
    error UnexpectedTickSpacing(int24 actual, int24 expected);
    error UnexpectedHook(address actual, address expected);
    error UnexpectedPool(PoolId actual, PoolId expected);
    error PoolAlreadyInitialized();
    error UnauthorizedInitializer(address caller);
    error CanonicalPoolNotInitialized();
    error InitialSqrtPriceMismatch(uint160 actual, uint160 expected);
    error LiquidityAdditionsPaused();
    error InvalidLiquidityRange(int24 tickLower, int24 tickUpper);
    error InvalidMinimumRangeWidth(uint24 width);
    error LiquidityRangeTooNarrow(uint256 actualWidth, uint24 minimumWidth);
    error OwnershipRenunciationDisabled();
    error TradingHalted();
    error EmrlBuysBlocked();
    error RiskOracleNotConfigured();
    error RiskOracleUnavailable();
    error RiskDataStale(uint48 updatedAt, uint256 currentTime, uint48 maximumAge);
    error ReserveCoverageTooLow(uint32 actualBps, uint32 minimumBps);
    error NavDeviationTooHigh(uint256 actualTicks, uint24 maximumTicks);
    error InvalidRiskPolicy();
    error InvalidRiskMode();
    error InventoryBiasOutOfBounds(int24 bias);
    error InvalidRangePolicy(int24 tickLower, int24 tickUpper);
    error MMLiquidityProviderNotConfigured();
    error UntrustedLiquidityRouter(address router);
    error LiquidityProviderNotAllowed(address provider);
    error ProtectedRangeReservedForMM(address provider, int24 tickLower, int24 tickUpper);
    error LiquidityRouterQueryFailed(address router);

    event CanonicalPoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);
    event MMOperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event DirectionalFeesUpdated(uint24 usdToEmrlFee, uint24 emrlToUsdFee);
    event NormalFeeUpdated(uint24 previousFee, uint24 newFee);
    event FallbackFeeUpdated(uint24 previousFee, uint24 newFee);
    event DirectionalFeesEnabled(bool enabled);
    event FallbackModeUpdated(bool enabled);
    event LiquidityAdditionsPauseUpdated(bool paused);
    event MinimumRangeWidthPolicyUpdated(bool enabled, uint24 minimumWidth);
    event RiskModeUpdated(RiskMode mode);
    event RiskPolicyConfigured(address indexed oracle, RiskPolicy policy);
    event OraclePolicyEnabled(bool enabled);
    event InventoryFeeBiasUpdated(int24 bias);
    event InventoryBiasEnabled(bool enabled);
    event LiquidityAccessModeUpdated(LiquidityAccessMode mode);
    event TrustedLiquidityRouterUpdated(address indexed router, bool trusted);
    event LiquidityProviderPermissionUpdated(address indexed provider, bool allowed);
    event MMLiquidityProviderUpdated(address indexed previousProvider, address indexed newProvider);
    event ProtectedRangePolicyUpdated(bool enabled, int24 tickLower, int24 tickUpper);
    event MonitoredRangeUpdated(int24 tickLower, int24 tickUpper);
    event RangeTelemetryEnabled(bool enabled);
    event ManagedRangeBoundaryCrossed(
        PoolId indexed poolId, int24 indexed boundary, int24 previousTick, int24 currentTick
    );
    event SwapTelemetry(
        PoolId indexed poolId, address indexed router, bool zeroForOne, int128 amount0, int128 amount1, int24 endingTick
    );

    modifier onlyMMOperator() {
        if (msg.sender != mmOperator) revert NotMMOperator(msg.sender);
        _;
    }

    constructor(
        IPoolManager poolManager_,
        address emrl_,
        address usdg_,
        int24 tickSpacing_,
        uint160 initialSqrtPriceX96_,
        address admin_,
        address mmOperator_,
        uint24 minAllowedFee_,
        uint24 maxAllowedFee_,
        uint24 defaultFee_,
        uint24 fallbackFee_
    ) BaseHook(poolManager_) Ownable(admin_) {
        if (
            address(poolManager_) == address(0) || emrl_ == address(0) || usdg_ == address(0)
                || mmOperator_ == address(0)
        ) revert ZeroAddress();
        if (emrl_ == usdg_) revert IdenticalCurrencies();
        if (tickSpacing_ < TickMath.MIN_TICK_SPACING || tickSpacing_ > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing(tickSpacing_);
        }
        if (initialSqrtPriceX96_ < TickMath.MIN_SQRT_PRICE || initialSqrtPriceX96_ >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidInitialSqrtPrice(initialSqrtPriceX96_);
        }
        if (minAllowedFee_ > maxAllowedFee_ || maxAllowedFee_ > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidFeeBounds(minAllowedFee_, maxAllowedFee_);
        }

        EMRL = emrl_;
        USDG = usdg_;
        emrlIsCurrency0 = emrl_ < usdg_;
        currency0 = Currency.wrap(emrl_ < usdg_ ? emrl_ : usdg_);
        currency1 = Currency.wrap(emrl_ < usdg_ ? usdg_ : emrl_);
        approvedTickSpacing = tickSpacing_;
        approvedInitialSqrtPriceX96 = initialSqrtPriceX96_;
        MIN_ALLOWED_FEE = minAllowedFee_;
        MAX_ALLOWED_FEE = maxAllowedFee_;

        _checkFee(defaultFee_);
        _checkFee(fallbackFee_);
        normalFee = defaultFee_;
        usdToEmrlFee = defaultFee_;
        emrlToUsdFee = defaultFee_;
        fallbackFee = fallbackFee_;
        mmOperator = mmOperator_;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing_,
            hooks: IHooks(address(this))
        });
        canonicalPoolId = key.toId();
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Returns the native v4 LP fee that would be selected for a swap direction, without the override flag.
    function feeForSwap(bool zeroForOne) public view returns (uint24) {
        if (fallbackMode) return fallbackFee;
        bool usdToEmrl = _isUsdToEmrl(zeroForOne);
        uint24 selectedFee = directionalFeesEnabled ? (usdToEmrl ? usdToEmrlFee : emrlToUsdFee) : normalFee;
        return inventoryBiasEnabled ? _applyInventoryBias(selectedFee, usdToEmrl) : selectedFee;
    }

    function setDirectionalFees(uint24 newUsdToEmrlFee, uint24 newEmrlToUsdFee) external onlyMMOperator {
        _checkFee(newUsdToEmrlFee);
        _checkFee(newEmrlToUsdFee);
        usdToEmrlFee = newUsdToEmrlFee;
        emrlToUsdFee = newEmrlToUsdFee;
        emit DirectionalFeesUpdated(newUsdToEmrlFee, newEmrlToUsdFee);
    }

    /// @notice Sets a signed fee-unit bias. Positive values discourage EMRL buys and encourage EMRL sells.
    function setInventoryFeeBias(int24 newBias) external onlyMMOperator {
        int256 signedBias = int256(newBias);
        if (signedBias < 0) signedBias = -signedBias;
        // The value is non-negative after normalization, so the signed-to-unsigned conversion is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absoluteBias = uint256(signedBias);
        if (absoluteBias > MAX_ALLOWED_FEE - MIN_ALLOWED_FEE) revert InventoryBiasOutOfBounds(newBias);
        inventoryFeeBias = newBias;
        emit InventoryFeeBiasUpdated(newBias);
    }

    /// @notice Updates the range monitored by optional post-swap crossing telemetry.
    function setMonitoredRange(int24 tickLower, int24 tickUpper) external onlyMMOperator {
        _validateAlignedRange(tickLower, tickUpper);
        monitoredTickLower = tickLower;
        monitoredTickUpper = tickUpper;
        monitoredRangeConfigured = true;
        emit MonitoredRangeUpdated(tickLower, tickUpper);
    }

    function setMMOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        address previousOperator = mmOperator;
        mmOperator = newOperator;
        emit MMOperatorUpdated(previousOperator, newOperator);
    }

    function setNormalFee(uint24 newFee) external onlyOwner {
        _checkFee(newFee);
        uint24 previousFee = normalFee;
        normalFee = newFee;
        emit NormalFeeUpdated(previousFee, newFee);
    }

    function setFallbackFee(uint24 newFee) external onlyOwner {
        _checkFee(newFee);
        uint24 previousFee = fallbackFee;
        fallbackFee = newFee;
        emit FallbackFeeUpdated(previousFee, newFee);
    }

    function setDirectionalFeesEnabled(bool enabled) external onlyOwner {
        directionalFeesEnabled = enabled;
        emit DirectionalFeesEnabled(enabled);
    }

    /// @notice Owner-controlled emergency mode. The MM operator has no path to disable it.
    function setFallbackMode(bool enabled) external onlyOwner {
        fallbackMode = enabled;
        emit FallbackModeUpdated(enabled);
    }

    function setRiskMode(RiskMode mode) external onlyOwner {
        if (uint8(mode) > uint8(RiskMode.HALT_ALL)) revert InvalidRiskMode();
        riskMode = mode;
        emit RiskModeUpdated(mode);
    }

    /// @notice Configures fixed-semantics risk inputs. Zero reserve/NAV/volatility values disable that individual rule.
    function configureRiskPolicy(address oracle, RiskPolicy calldata policy) external onlyOwner {
        if (oracle == address(0) || oracle.code.length == 0) revert RiskOracleNotConfigured();
        if (policy.maxOracleAge == 0 || policy.maxOracleAge > 30 days) revert InvalidRiskPolicy();
        if (policy.maximumNavDeviationTicks > uint24(uint256(int256(TickMath.MAX_TICK)))) {
            revert InvalidRiskPolicy();
        }
        if (policy.highVolatilityFee != 0) {
            if (policy.volatilityThresholdBps == 0) revert InvalidRiskPolicy();
            _checkFee(policy.highVolatilityFee);
        }
        riskOracle = oracle;
        riskPolicy = policy;
        emit RiskPolicyConfigured(oracle, policy);
    }

    function setOraclePolicyEnabled(bool enabled) external onlyOwner {
        if (enabled && (riskOracle == address(0) || riskPolicy.maxOracleAge == 0)) {
            revert RiskOracleNotConfigured();
        }
        oraclePolicyEnabled = enabled;
        emit OraclePolicyEnabled(enabled);
    }

    function setInventoryBiasEnabled(bool enabled) external onlyOwner {
        inventoryBiasEnabled = enabled;
        emit InventoryBiasEnabled(enabled);
    }

    function setLiquidityAdditionsPaused(bool paused) external onlyOwner {
        liquidityAdditionsPaused = paused;
        emit LiquidityAdditionsPauseUpdated(paused);
    }

    /// @notice Configures the dormant minimum-width policy. Width must be a positive multiple of tick spacing when enabled.
    function configureMinimumRangeWidth(bool enabled, uint24 width) external onlyOwner {
        if (enabled) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint24 spacing = uint24(approvedTickSpacing);
            if (width < spacing || width % spacing != 0) revert InvalidMinimumRangeWidth(width);
        }
        minimumRangeWidthEnabled = enabled;
        minimumRangeWidth = width;
        emit MinimumRangeWidthPolicyUpdated(enabled, width);
    }

    function setMMLiquidityProvider(address newProvider) external onlyOwner {
        if (newProvider == address(0)) revert ZeroAddress();
        address previousProvider = mmLiquidityProvider;
        mmLiquidityProvider = newProvider;
        emit MMLiquidityProviderUpdated(previousProvider, newProvider);
    }

    function setTrustedLiquidityRouter(address router, bool trusted) external onlyOwner {
        if (router == address(0) || (trusted && router.code.length == 0)) revert ZeroAddress();
        trustedLiquidityRouters[router] = trusted;
        emit TrustedLiquidityRouterUpdated(router, trusted);
    }

    function setLiquidityProviderAllowed(address provider, bool allowed) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        allowedLiquidityProviders[provider] = allowed;
        emit LiquidityProviderPermissionUpdated(provider, allowed);
    }

    function setLiquidityAccessMode(LiquidityAccessMode mode) external onlyOwner {
        if (uint8(mode) > uint8(LiquidityAccessMode.MM_ONLY)) revert InvalidRiskMode();
        if (mode == LiquidityAccessMode.MM_ONLY && mmLiquidityProvider == address(0)) {
            revert MMLiquidityProviderNotConfigured();
        }
        liquidityAccessMode = mode;
        emit LiquidityAccessModeUpdated(mode);
    }

    function configureProtectedRange(bool enabled, int24 tickLower, int24 tickUpper) external onlyOwner {
        if (enabled) {
            if (mmLiquidityProvider == address(0)) revert MMLiquidityProviderNotConfigured();
            _validateAlignedRange(tickLower, tickUpper);
        }
        protectedRangeEnabled = enabled;
        protectedTickLower = tickLower;
        protectedTickUpper = tickUpper;
        emit ProtectedRangePolicyUpdated(enabled, tickLower, tickUpper);
    }

    function setRangeTelemetryEnabled(bool enabled) external onlyOwner {
        if (enabled) {
            if (!poolInitialized) revert CanonicalPoolNotInitialized();
            if (!monitoredRangeConfigured) {
                revert InvalidRangePolicy(monitoredTickLower, monitoredTickUpper);
            }
            (, lastObservedTick,,) = poolManager.getSlot0(canonicalPoolId);
        }
        rangeTelemetryEnabled = enabled;
        emit RangeTelemetryEnabled(enabled);
    }

    /// @dev Ownership is deliberately non-renounceable so emergency fee control cannot be accidentally orphaned.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    /// @dev Only the owner-appointed operator may start this pool. In production this is the
    ///      immutable Safe-bound manager, calling PoolManager directly (not a public router).
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        _validateCanonicalPool(key);
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (sqrtPriceX96 != approvedInitialSqrtPriceX96) {
            revert InitialSqrtPriceMismatch(sqrtPriceX96, approvedInitialSqrtPriceX96);
        }
        if (sender != mmOperator) revert UnauthorizedInitializer(sender);
        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        _validateCanonicalPool(key);
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (sqrtPriceX96 != approvedInitialSqrtPriceX96) {
            revert InitialSqrtPriceMismatch(sqrtPriceX96, approvedInitialSqrtPriceX96);
        }
        poolInitialized = true;
        lastObservedTick = tick;
        emit CanonicalPoolInitialized(canonicalPoolId, sqrtPriceX96, tick);
        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _validateReadyCanonicalPool(key);
        if (liquidityAdditionsPaused) revert LiquidityAdditionsPaused();
        if (params.tickLower >= params.tickUpper) revert InvalidLiquidityRange(params.tickLower, params.tickUpper);

        uint256 width = uint256(int256(params.tickUpper) - int256(params.tickLower));
        if (minimumRangeWidthEnabled && width < minimumRangeWidth) {
            revert LiquidityRangeTooNarrow(width, minimumRangeWidth);
        }
        _enforceLiquidityEntryPolicy(sender, params.tickLower, params.tickUpper);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateReadyCanonicalPool(key);
        uint24 fee = _riskAdjustedFee(params.zeroForOne, feeForSwap(params.zeroForOne));
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev PoolManager's Swap event remains the source of the applied fee. Optional telemetry adds only range data;
    ///      returning zero always preserves normal v4 settlement.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _validateReadyCanonicalPool(key);
        if (rangeTelemetryEnabled) {
            (, int24 currentTick,,) = poolManager.getSlot0(canonicalPoolId);
            int24 previousTick = lastObservedTick;
            _emitBoundaryCrossing(monitoredTickLower, previousTick, currentTick);
            _emitBoundaryCrossing(monitoredTickUpper, previousTick, currentTick);
            lastObservedTick = currentTick;
            emit SwapTelemetry(
                canonicalPoolId, sender, params.zeroForOne, delta.amount0(), delta.amount1(), currentTick
            );
        }
        return (IHooks.afterSwap.selector, 0);
    }

    function _riskAdjustedFee(bool zeroForOne, uint24 selectedFee) internal view returns (uint24) {
        bool usdToEmrl = _isUsdToEmrl(zeroForOne);
        if (riskMode == RiskMode.HALT_ALL) revert TradingHalted();
        if (usdToEmrl && riskMode == RiskMode.BLOCK_EMRL_BUYS) revert EmrlBuysBlocked();

        if (!oraclePolicyEnabled) return selectedFee;

        (bool oracleSuccess, bytes memory encodedData) =
            riskOracle.staticcall{ gas: RISK_ORACLE_GAS_LIMIT }(abi.encodeCall(IEMRLRiskOracle.latestRiskData, ()));
        (bool dataValid, IEMRLRiskOracle.RiskData memory data) = _decodeRiskData(encodedData);
        if (!oracleSuccess || !dataValid) {
            if (usdToEmrl) revert RiskOracleUnavailable();
            return selectedFee;
        }

        RiskPolicy memory policy = riskPolicy;
        uint256 currentTime = block.timestamp;
        // Oracle freshness necessarily depends on timestamp. Validator drift is negligible versus configured age windows.
        // forge-lint: disable-next-line(block-timestamp)
        if (data.updatedAt > currentTime || currentTime - data.updatedAt > policy.maxOracleAge) {
            if (usdToEmrl) {
                revert RiskDataStale(data.updatedAt, currentTime, policy.maxOracleAge);
            }
            return selectedFee;
        }
        if (
            usdToEmrl && policy.minimumReserveCoverageBps != 0
                && data.reserveCoverageBps < policy.minimumReserveCoverageBps
        ) revert ReserveCoverageTooLow(data.reserveCoverageBps, policy.minimumReserveCoverageBps);

        if (usdToEmrl && policy.maximumNavDeviationTicks != 0) {
            (, int24 currentTick,,) = poolManager.getSlot0(canonicalPoolId);
            int256 signedDeviation = int256(currentTick) - int256(data.fairTick);
            if (signedDeviation < 0) signedDeviation = -signedDeviation;
            // The value is non-negative after normalization, so the signed-to-unsigned conversion is lossless.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 deviation = uint256(signedDeviation);
            if (deviation > policy.maximumNavDeviationTicks) {
                revert NavDeviationTooHigh(deviation, policy.maximumNavDeviationTicks);
            }
        }
        if (
            !fallbackMode && policy.highVolatilityFee != 0 && data.volatilityBps >= policy.volatilityThresholdBps
                && selectedFee < policy.highVolatilityFee
        ) selectedFee = policy.highVolatilityFee;
        return selectedFee;
    }

    function _decodeRiskData(bytes memory encodedData)
        internal
        pure
        returns (bool valid, IEMRLRiskOracle.RiskData memory data)
    {
        if (encodedData.length != 128) return (false, data);

        uint256 rawFairTick;
        uint256 rawReserveCoverage;
        uint256 rawVolatility;
        uint256 rawUpdatedAt;
        assembly ("memory-safe") {
            rawFairTick := mload(add(encodedData, 0x20))
            rawReserveCoverage := mload(add(encodedData, 0x40))
            rawVolatility := mload(add(encodedData, 0x60))
            rawUpdatedAt := mload(add(encodedData, 0x80))
        }

        // ABI encodes signed integers in two's-complement form; this same-width cast preserves every bit.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 signedFairTick = int256(rawFairTick);
        if (
            signedFairTick < type(int24).min || signedFairTick > type(int24).max
                || rawReserveCoverage > type(uint32).max || rawVolatility > type(uint32).max
                || rawUpdatedAt > type(uint48).max
        ) return (false, data);

        // Each conversion is lossless because the preceding checks prove the target-width bounds.
        // forge-lint: disable-next-line(unsafe-typecast)
        data.fairTick = int24(signedFairTick);
        // forge-lint: disable-next-line(unsafe-typecast)
        data.reserveCoverageBps = uint32(rawReserveCoverage);
        // forge-lint: disable-next-line(unsafe-typecast)
        data.volatilityBps = uint32(rawVolatility);
        // forge-lint: disable-next-line(unsafe-typecast)
        data.updatedAt = uint48(rawUpdatedAt);
        valid = true;
    }

    function _applyInventoryBias(uint24 fee, bool usdToEmrl) internal view returns (uint24) {
        int256 adjusted = int256(uint256(fee)) + (usdToEmrl ? int256(inventoryFeeBias) : -int256(inventoryFeeBias));
        if (adjusted < int256(uint256(MIN_ALLOWED_FEE))) return MIN_ALLOWED_FEE;
        if (adjusted > int256(uint256(MAX_ALLOWED_FEE))) return MAX_ALLOWED_FEE;
        // The preceding bounds prove adjusted is non-negative and fits in uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(uint256(adjusted));
    }

    function _enforceLiquidityEntryPolicy(address sender, int24 tickLower, int24 tickUpper) internal view {
        bool overlapsProtectedRange =
            protectedRangeEnabled && tickLower < protectedTickUpper && tickUpper > protectedTickLower;
        LiquidityAccessMode mode = liquidityAccessMode;
        if (mode == LiquidityAccessMode.OPEN && !overlapsProtectedRange) return;

        address provider = _liquidityProvider(sender);
        if (mode == LiquidityAccessMode.ALLOWLIST && !allowedLiquidityProviders[provider]) {
            revert LiquidityProviderNotAllowed(provider);
        }
        if (mode == LiquidityAccessMode.MM_ONLY && provider != mmLiquidityProvider) {
            revert LiquidityProviderNotAllowed(provider);
        }
        if (overlapsProtectedRange && provider != mmLiquidityProvider) {
            revert ProtectedRangeReservedForMM(provider, tickLower, tickUpper);
        }
    }

    function _liquidityProvider(address sender) internal view returns (address provider) {
        if (!trustedLiquidityRouters[sender]) revert UntrustedLiquidityRouter(sender);
        try IMsgSender(sender).msgSender() returns (address originalSender) {
            provider = originalSender;
        } catch {
            revert LiquidityRouterQueryFailed(sender);
        }
    }

    function _emitBoundaryCrossing(int24 boundary, int24 previousTick, int24 currentTick) internal {
        if (
            (previousTick < boundary && currentTick >= boundary) || (previousTick >= boundary && currentTick < boundary)
        ) {
            emit ManagedRangeBoundaryCrossed(canonicalPoolId, boundary, previousTick, currentTick);
        }
    }

    function _validateAlignedRange(int24 tickLower, int24 tickUpper) internal view {
        if (
            tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK || tickLower >= tickUpper
                || tickLower % approvedTickSpacing != 0 || tickUpper % approvedTickSpacing != 0
        ) revert InvalidRangePolicy(tickLower, tickUpper);
    }

    function _isUsdToEmrl(bool zeroForOne) internal view returns (bool) {
        return zeroForOne ? Currency.unwrap(currency0) == USDG : Currency.unwrap(currency1) == USDG;
    }

    function _checkFee(uint24 fee) internal view {
        if (fee < MIN_ALLOWED_FEE || fee > MAX_ALLOWED_FEE) revert FeeOutOfBounds(fee);
    }

    function _validateCanonicalPool(PoolKey calldata key) internal view {
        address actualCurrency0 = Currency.unwrap(key.currency0);
        address actualCurrency1 = Currency.unwrap(key.currency1);
        if (actualCurrency0 != Currency.unwrap(currency0) || actualCurrency1 != Currency.unwrap(currency1)) {
            revert UnexpectedCurrencies(actualCurrency0, actualCurrency1);
        }
        if (!key.fee.isDynamicFee()) revert DynamicFeeRequired(key.fee);
        if (key.tickSpacing != approvedTickSpacing) {
            revert UnexpectedTickSpacing(key.tickSpacing, approvedTickSpacing);
        }
        if (address(key.hooks) != address(this)) revert UnexpectedHook(address(key.hooks), address(this));

        PoolId actual = key.toId();
        if (PoolId.unwrap(actual) != PoolId.unwrap(canonicalPoolId)) revert UnexpectedPool(actual, canonicalPoolId);
    }

    function _validateReadyCanonicalPool(PoolKey calldata key) internal view {
        _validateCanonicalPool(key);
        if (!poolInitialized) revert CanonicalPoolNotInitialized();
    }
}
