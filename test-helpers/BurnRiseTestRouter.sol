// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IBurnRisePoolKeys {
    function poolKeyFor(address token) external view returns (PoolKey memory);
}

/// @title BurnRise test router (TESTNET ONLY)
/// @notice Trades BurnRise pools from outside the launchpad, the way other apps (DexScreener links, aggregators,
///         wallets) do, so you can test that from Remix. It is not part of BurnRise: on mainnet, other apps use
///         Uniswap's own router.
///         buy:  send the pair asset (as value for ETH pairs, or approve this router for the pair token)
///         sell: approve this router for the token first
contract BurnRiseTestRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    IBurnRisePoolKeys public immutable launchpad;

    event Swapped(address indexed token, address indexed trader, bool isBuy, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager poolManager_, IBurnRisePoolKeys launchpad_) {
        poolManager = poolManager_;
        launchpad = launchpad_;
    }

    /// @notice Spend exactly `amountIn` of the pair asset on `token`.
    function buy(address token, uint256 amountIn, uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        tokensOut = _swap(token, true, amountIn, minTokensOut);
    }

    /// @notice Sell exactly `tokensIn` of `token` for its pair asset.
    function sell(address token, uint256 tokensIn, uint256 minOut) external returns (uint256 amountOut) {
        amountOut = _swap(token, false, tokensIn, minOut);
    }

    function _swap(address token, bool isBuy, uint256 amountIn, uint256 minOut) private returns (uint256 out) {
        require(amountIn > 0 && amountIn < 2 ** 255, "amount");
        PoolKey memory key = launchpad.poolKeyFor(token);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        bool zeroForOne = isBuy ? !tokenIs0 : tokenIs0;
        bool ethIn = (zeroForOne ? key.currency0 : key.currency1).isAddressZero();
        require(msg.value == (ethIn ? amountIn : 0), "send exactly amountIn as value for ETH, nothing otherwise");
        out = abi.decode(poolManager.unlock(abi.encode(msg.sender, key, zeroForOne, amountIn)), (uint256));
        require(out >= minOut, "slippage");
        emit Swapped(token, msg.sender, isBuy, amountIn, out);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only the pool manager");
        (address trader, PoolKey memory key, bool zeroForOne, uint256 amountIn) =
            abi.decode(data, (address, PoolKey, bool, uint256));
        BalanceDelta d = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency cIn, int128 dIn) = zeroForOne ? (key.currency0, d.amount0()) : (key.currency1, d.amount1());
        (Currency cOut, int128 dOut) = zeroForOne ? (key.currency1, d.amount1()) : (key.currency0, d.amount0());

        uint256 pay = uint256(-int256(dIn));
        poolManager.sync(cIn);
        if (cIn.isAddressZero()) {
            poolManager.settle{value: pay}();
        } else {
            IERC20(Currency.unwrap(cIn)).safeTransferFrom(trader, address(poolManager), pay);
            poolManager.settle();
        }
        uint256 out = uint256(int256(dOut));
        poolManager.take(cOut, trader, out);
        return abi.encode(out);
    }
}
