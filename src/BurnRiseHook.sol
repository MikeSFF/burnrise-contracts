// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {BurnRiseConfig as C} from "./BurnRiseConfig.sol";

interface IBurnRiseLaunchpadForHook {
    function launching() external view returns (address token, uint160 graduationSqrtPriceX96);
    function collectPoolFee(address token, uint256 amount) external;
    function onGraduated(address token) external;
}

/// @title BurnRise Uniswap v4 hook
/// @notice Runs on every swap in every BurnRise pool, whichever app or router sends it, and charges:
///         1.3% of the pair side (credited to the launchpad as Uniswap claims, which it splits 0.9% creator /
///         0.3% platform / 0.1% contest) and 0.5% of the token side, which is burned (sent to 0x...dEaD). Works for buys and
///         sells, exact input and exact output. It also marks a token as graduated on the buy that brings
///         its pool's pair asset to the graduation target. Only the launchpad can create pools with this hook
///         or add liquidity to them, and the launchpad has no way to remove liquidity, so it is locked.
/// @dev The hook's address must carry exactly the permission bits in `getHookPermissions`;
///      the launchpad deploys it with a mined CREATE2 salt (see BurnRiseLaunchpad.deployHook).
contract BurnRiseHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    address public immutable launchpad;

    struct PoolInfo {
        address token;                  // the BurnRise token; the other currency is its pair asset
        bool tokenIs0;                  // whether the token is currency0
        bool graduated;                 // set once, on the buy that reaches the graduation target
        uint160 graduationSqrtPriceX96; // the pool price at which the pair asset in the pool reaches the target
    }

    /// One swap, seen from the side the trader fixed (`specified`) and the other side.
    struct Amounts {
        bool exactInput;
        bool specifiedIs0;
        bool specifiedIsToken;
        uint256 specified;    // |amountSpecified|
        uint256 specifiedFee; // fee on the specified side, taken in beforeSwap
        uint256 other;        // what the pool swapped on the other side
        uint256 otherFee;     // fee on the other side, taken in afterSwap
    }

    mapping(PoolId => PoolInfo) public pools;

    event PoolRegistered(address indexed token, PoolId indexed poolId);
    /// One event per trade in a BurnRise pool, from any app, with the trader's side of it:
    /// quoteAmount: pair asset the buyer paid (fee included) or the seller received (fee already taken);
    /// tokenAmount: tokens the buyer received (burn already taken) or the seller paid (burn included);
    /// fee: the 1.3% pair-asset fee; burned: the 0.5% of tokens sent to 0x...dEaD.
    event Trade(address indexed token, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 fee, uint256 burned);

    error NotPoolManager();
    error NotLaunchpad();
    error InvalidPool();
    error UnknownPool();
    error HookNotImplemented();
    error PartialFill();

    constructor(IPoolManager poolManager_, address launchpad_) {
        poolManager = poolManager_;
        launchpad = launchpad_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// Only the launchpad, while launching a token, can create a pool with this hook.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != launchpad) revert NotLaunchpad();
        (address token, uint160 graduationSqrtPriceX96) = IBurnRiseLaunchpadForHook(launchpad).launching();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (token == address(0) || (token != c0 && token != c1)) revert InvalidPool();
        if (key.fee != C.POOL_FEE || key.tickSpacing != C.TICK_SPACING) revert InvalidPool();
        PoolId id = key.toId();
        pools[id] = PoolInfo({
            token: token,
            tokenIs0: token == c0,
            graduated: false,
            graduationSqrtPriceX96: graduationSqrtPriceX96
        });
        emit PoolRegistered(token, id);
        return IHooks.beforeInitialize.selector;
    }

    /// Only the launchpad can add liquidity, so the pool holds just its locked position.
    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != launchpad) revert NotLaunchpad();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// Fee on the side the trader fixed: taken from it (exact input) or added to it (exact output).
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolInfo memory p = _pool(key.toId());
        bool exactInput = params.amountSpecified < 0;
        bool specifiedIs0 = exactInput == params.zeroForOne;
        bool onToken = specifiedIs0 == p.tokenIs0;
        uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _fee(amount, onToken ? C.BURN_BPS : C.QUOTE_FEE_BPS, exactInput);
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        _collect(p, specifiedIs0 ? key.currency0 : key.currency1, onToken, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// Fee on the other side (taken from the output for exact input, added to the input for exact output),
    /// the Trade event, and graduation.
    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        PoolInfo memory p = _pool(id);
        Amounts memory a = _amounts(p, params, delta);
        if (a.otherFee > 0) _collect(p, a.specifiedIs0 ? key.currency1 : key.currency0, !a.specifiedIsToken, a.otherFee);
        bool isBuy = params.zeroForOne != p.tokenIs0; // a buy pays the pair asset
        _emitTrade(p.token, isBuy, a);
        if (isBuy && !p.graduated) _checkGraduation(id, p);
        return (IHooks.afterSwap.selector, a.otherFee.toInt128());
    }

    /// Works out both sides of the swap. All or nothing: beforeSwap charged its fee on the whole amount the
    /// trader fixed, so that whole amount must have traded. A swap stopped early by a price limit reverts
    /// instead of paying fees on what didn't trade.
    function _amounts(PoolInfo memory p, IPoolManager.SwapParams calldata params, BalanceDelta delta)
        private
        pure
        returns (Amounts memory a)
    {
        a.exactInput = params.amountSpecified < 0;
        a.specifiedIs0 = a.exactInput == params.zeroForOne;
        a.specifiedIsToken = a.specifiedIs0 == p.tokenIs0;
        a.specified = a.exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        a.specifiedFee = _fee(a.specified, a.specifiedIsToken ? C.BURN_BPS : C.QUOTE_FEE_BPS, a.exactInput);
        int256 swapped = a.specifiedIs0 ? delta.amount0() : delta.amount1();
        if (swapped != params.amountSpecified + int256(a.specifiedFee)) revert PartialFill();
        int128 d = a.specifiedIs0 ? delta.amount1() : delta.amount0();
        a.other = d < 0 ? uint256(-int256(d)) : uint256(int256(d));
        a.otherFee = _fee(a.other, a.specifiedIsToken ? C.QUOTE_FEE_BPS : C.BURN_BPS, a.exactInput);
    }

    /// The trader's side: exact input pays `specified` and receives `other - otherFee`; exact output
    /// receives `specified` and pays `other + otherFee`.
    function _emitTrade(address token, bool isBuy, Amounts memory a) private {
        uint256 otherSide = a.exactInput ? a.other - a.otherFee : a.other + a.otherFee;
        (uint256 quoteAmount, uint256 tokenAmount) = a.specifiedIsToken ? (otherSide, a.specified) : (a.specified, otherSide);
        (uint256 fee, uint256 burned) = a.specifiedIsToken ? (a.otherFee, a.specifiedFee) : (a.specifiedFee, a.otherFee);
        emit Trade(token, isBuy, quoteAmount, tokenAmount, fee, burned);
    }

    /// Graduated once the pool's pair asset reaches the target: buys move the price past the graduation price
    /// (up when the token is currency0, down when it is currency1). It stays graduated.
    function _checkGraduation(PoolId id, PoolInfo memory p) private {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (p.tokenIs0 ? sqrtPriceX96 < p.graduationSqrtPriceX96 : sqrtPriceX96 > p.graduationSqrtPriceX96) return;
        pools[id].graduated = true;
        IBurnRiseLaunchpadForHook(launchpad).onGraduated(p.token);
    }

    /// `fromAmount`: the fee comes out of `amount`; otherwise it is added on top of `amount`.
    function _fee(uint256 amount, uint256 bps, bool fromAmount) private pure returns (uint256) {
        if (amount == 0) return 0;
        return fromAmount ? C.feeOn(amount, bps) : C.feeOnTop(amount, bps);
    }

    /// Token-side fees go straight from the pool to 0x...dEaD. Pair-asset fees are credited to the launchpad as
    /// ERC-6909 claims on the pool manager: unlike a transfer, that works before the trader has paid in (a
    /// fresh pool holds none of the pair asset), and the launchpad turns the claims into the asset later.
    function _collect(PoolInfo memory p, Currency currency, bool onToken, uint256 fee) private {
        if (onToken) {
            poolManager.take(currency, C.BURN_ADDRESS, fee);
        } else {
            poolManager.mint(launchpad, currency.toId(), fee);
            IBurnRiseLaunchpadForHook(launchpad).collectPoolFee(p.token, fee);
        }
    }

    function _pool(PoolId id) private view returns (PoolInfo memory p) {
        p = pools[id];
        if (p.token == address(0)) revert UnknownPool();
    }

    /* The pool manager only calls the hooks enabled above; the rest are never used. */

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
