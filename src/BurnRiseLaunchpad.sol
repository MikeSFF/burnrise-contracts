// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BurnRiseConfig as C} from "./BurnRiseConfig.sol";
import {BurnRiseFactory} from "./BurnRiseFactory.sol";
import {BurnRiseHook} from "./BurnRiseHook.sol";

/// @title BurnRise launchpad
/// @notice Launches meme tokens on Robinhood Chain straight into their own Uniswap v4 pool, so every token
///         is on Uniswap, DexScreener and any v4 app from its first trade. The whole supply goes into the
///         pool as one position from the launch price on, which works as the bonding curve; the position
///         belongs to this contract, which has no function to remove it, so the liquidity is locked forever.
///         A token graduates when its graduation target of the pair asset (4.2 ETH on ETH pairs) is in its
///         pool. Nothing moves at graduation: the token keeps trading in the same pool.
///
///         Fees on every trade, from any app (fixed, nobody can change them; the BurnRise hook takes them):
///           0.9% of the pair side to the token's creator (claimable here)
///           0.3% of the pair side to the platform wallet
///           0.1% of the pair side to the weekly contest wallet
///           0.5% of the token side burned: sent to 0x...dEaD, where everyone can see it
///         The platform and contest shares are sent after every trade made through this contract; trades made
///         in other apps are paid out with the next one (or anyone can call payOutFees).
///
///         The owner can only: choose which pair assets new launches can use and their graduation
///         targets, change the platform and contest wallets, pause new launches (the owner can still
///         launch while paused, to test), and deploy the hook once. The owner cannot touch anyone's tokens,
///         the pools' liquidity or fees owed to creators.
contract BurnRiseLaunchpad is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    struct Pair {
        bool enabled;   // new launches can use it
        uint128 target; // pair asset a pool must hold to graduate, in the asset's smallest unit
    }

    struct TokenInfo {
        address creator;    // gets the creator fees (the creator can hand this to another address)
        uint64 launchedAt;
        bool graduated;     // set once, by the buy that brings `target` of the pair asset into the pool
        address quote;      // pair asset, address(0) = ETH
        uint128 target;     // graduation target, fixed at launch
        uint128 liquidity;  // the pool's locked position: all the liquidity the pool has
        int24 tickLower;    // the position's price range
        int24 tickUpper;
    }

    enum Action {
        LAUNCH,
        BUY,
        SELL,
        CLAIM,
        WITHDRAW,
        PAY_OUT
    }

    /// Hook address bits the pool manager reads to know which hook functions to call.
    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    /// ETH sent to the platform or contest wallet gets this much gas, so a broken wallet can't block trading.
    uint256 private constant WALLET_GAS = 50_000;

    /// The pool manager's transient "unlocked" flag (the same slot as Uniswap v4-core's Lock library).
    bytes32 private constant MANAGER_UNLOCKED_SLOT = bytes32(uint256(keccak256("Unlocked")) - 1);

    IPoolManager public immutable poolManager;
    BurnRiseFactory public immutable factory; // deploys the tokens and the hook
    BurnRiseHook public hook;

    address public platformWallet;
    address public contestWallet;
    bool public launchesPaused;

    mapping(address quote => Pair) public pairs;
    mapping(address token => TokenInfo) public tokenInfo;
    /// Creator fees not claimed yet, in the token's pair asset.
    mapping(address token => uint256) public creatorFees;
    /// Platform and contest fees not sent yet. They go out after every trade made through this contract; a
    /// wallet that can't receive keeps its balance here and can withdraw it to another address.
    mapping(address wallet => mapping(address quote => uint256)) public pendingPayouts;
    /// Everything this contract owes in each pair asset (unclaimed creator fees plus pending payouts). It holds
    /// exactly that much: as the asset itself, or as Uniswap claims not turned into the asset yet.
    mapping(address quote => uint256) public owed;
    address[] public allTokens;

    // the token whose pool is being created right now, and its graduation price (read by the hook)
    address private _launchingToken;
    uint160 private _launchingGraduationPrice;

    event Launched(
        address indexed token,
        address indexed creator,
        address indexed quote,
        string name,
        string symbol,
        string metadataURI,
        uint256 target,
        PoolId poolId
    );
    event FeesSplit(address indexed token, uint256 toCreator, uint256 toPlatform, uint256 toContest);
    event Graduated(address indexed token, PoolId indexed poolId);
    event CreatorFeesClaimed(address indexed token, address indexed creator, address quote, uint256 amount);
    event CreatorChanged(address indexed token, address indexed from, address indexed to);
    event PayoutSent(address indexed wallet, address indexed quote, uint256 amount);
    event PayoutDeferred(address indexed wallet, address indexed quote, uint256 amount);
    event PayoutWithdrawn(address indexed wallet, address indexed quote, uint256 amount);
    event PairSet(address indexed quote, bool enabled, uint256 target);
    event PlatformWalletSet(address wallet);
    event ContestWalletSet(address wallet);
    event LaunchesPausedSet(bool paused);
    event HookDeployed(address hook);

    error ZeroAddress();
    error NotAContract();
    error BadTarget();
    error HookAlreadySet();
    error HookNotSet();
    error LaunchesArePaused();
    error PairNotEnabled();
    error BadName();
    error UnknownToken();
    error ZeroAmount();
    error WrongValue();
    error Slippage();
    error Expired();
    error NotCreator();
    error NothingToWithdraw();
    error NotHook();
    error NotPoolManager();
    error BadPrice();
    error TooLarge();
    error TransferFailed();
    error UnsupportedPairToken();

    constructor(IPoolManager poolManager_, address owner_, address platformWallet_, address contestWallet_)
        Ownable(owner_)
    {
        if (address(poolManager_).code.length == 0) revert NotAContract();
        poolManager = poolManager_;
        factory = new BurnRiseFactory();
        _setPlatformWallet(platformWallet_);
        _setContestWallet(contestWallet_);
        _setPair(address(0), true, 4.2 ether); // ETH pairs graduate at 4.2 ETH
    }

    /// The pool manager sends ETH here when this contract turns its fee claims into ETH.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /* ------------------------------------------------------------------ */
    /*                               Launch                               */
    /* ------------------------------------------------------------------ */

    /// @notice Create a token and its Uniswap v4 pool, with the whole supply locked in the pool. With
    ///         `firstBuy` > 0 the creator buys in the same transaction, before anyone else can (send it as ETH
    ///         for ETH pairs, or approve the pair token first). The first buy pays the normal fees.
    function launch(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        address quote,
        uint256 firstBuy,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, uint256 tokensBought) {
        if (msg.value != (quote == address(0) ? firstBuy : 0)) revert WrongValue();
        token = _create(name, symbol, metadataURI, quote);
        tokensBought = abi.decode(_unlock(Action.LAUNCH, abi.encode(token, firstBuy, minTokensOut, msg.sender)), (uint256));
    }

    function _create(string calldata name, string calldata symbol, string calldata metadataURI, address quote)
        private
        returns (address token)
    {
        if (launchesPaused && msg.sender != owner()) revert LaunchesArePaused(); // the owner can still test
        if (address(hook) == address(0)) revert HookNotSet();
        Pair memory p = pairs[quote];
        if (!p.enabled) revert PairNotEnabled();
        if (
            bytes(name).length == 0 || bytes(name).length > 32 || bytes(symbol).length == 0 || bytes(symbol).length > 10
                || bytes(metadataURI).length > 512
        ) revert BadName();

        token = factory.createToken(name, symbol, C.SUPPLY);
        PoolId id = _openPool(token, quote, p.target);
        allTokens.push(token);
        emit Launched(token, msg.sender, quote, name, symbol, metadataURI, p.target, id);
    }

    /// Records the token and creates its pool at the launch price (the liquidity is added right after).
    function _openPool(address token, address quote, uint128 target) private returns (PoolId id) {
        bool tokenIs0 = token < quote;
        (int24 tickLower, int24 tickUpper, uint160 sqrtStart) = _launchRange(tokenIs0, target);
        uint128 liquidity = _liquidityForSupply(tokenIs0, tickLower, tickUpper);
        tokenInfo[token] = TokenInfo({
            creator: msg.sender,
            launchedAt: uint64(block.timestamp),
            graduated: false,
            quote: quote,
            target: target,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper
        });

        PoolKey memory key = poolKeyFor(token);
        _launchingToken = token;
        _launchingGraduationPrice = _graduationSqrtPrice(tokenIs0, tickLower, tickUpper, liquidity, target);
        poolManager.initialize(key, sqrtStart);
        _launchingToken = address(0);
        _launchingGraduationPrice = 0;
        id = key.toId();
    }

    /// The position's range: from the launch price (market cap = 2/5 of the target) to the end of the price
    /// scale, on the side where the position holds only tokens.
    function _launchRange(bool tokenIs0, uint256 target)
        private
        pure
        returns (int24 tickLower, int24 tickUpper, uint160 sqrtStart)
    {
        uint256 cap = C.launchMarketCap(target);
        if (tokenIs0) {
            // price = pair asset per token; the position holds only tokens from the launch price up
            tickLower = _floorTick(TickMath.getTickAtSqrtPrice(_sqrtPriceX96(C.SUPPLY, cap)));
            tickUpper = C.MAX_TICK;
            sqrtStart = TickMath.getSqrtPriceAtTick(tickLower);
        } else {
            // price = tokens per pair asset; the position holds only tokens from the launch price down
            tickLower = C.MIN_TICK;
            tickUpper = _floorTick(TickMath.getTickAtSqrtPrice(_sqrtPriceX96(cap, C.SUPPLY)));
            sqrtStart = TickMath.getSqrtPriceAtTick(tickUpper);
        }
        if (tickLower < C.MIN_TICK || tickUpper > C.MAX_TICK || tickLower >= tickUpper) revert BadPrice();
    }

    /// The liquidity that holds the whole supply in the range (rounded so it never needs more than the supply).
    function _liquidityForSupply(bool tokenIs0, int24 tickLower, int24 tickUpper) private pure returns (uint128 liquidity) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 l = tokenIs0
            ? FullMath.mulDiv(C.SUPPLY, FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96), sqrtB - sqrtA)
            : FullMath.mulDiv(C.SUPPLY, FixedPoint96.Q96, sqrtB - sqrtA);
        liquidity = l.toUint128();
        while (_tokensFor(tokenIs0, sqrtA, sqrtB, liquidity) > C.SUPPLY) --liquidity;
    }

    function _tokensFor(bool tokenIs0, uint160 sqrtA, uint160 sqrtB, uint128 liquidity) private pure returns (uint256) {
        return tokenIs0
            ? SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, true);
    }

    /// The pool price at which the pair asset in the position reaches `target` (rounded so it takes at least
    /// the full target).
    function _graduationSqrtPrice(bool tokenIs0, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 target)
        private
        pure
        returns (uint160)
    {
        uint256 step = FullMath.mulDivRoundingUp(target, FixedPoint96.Q96, liquidity);
        if (tokenIs0) {
            // pair asset in the pool = L * (sqrtP - sqrtLower) / Q96
            uint256 s = TickMath.getSqrtPriceAtTick(tickLower) + step;
            return s < TickMath.MAX_SQRT_PRICE ? uint160(s) : TickMath.MAX_SQRT_PRICE;
        }
        // pair asset in the pool = L * (Q96 / sqrtP - Q96 / sqrtUpper), so 2^192 / sqrtP grows by `step`
        uint256 inv = (uint256(1) << 192) / TickMath.getSqrtPriceAtTick(tickUpper) + step;
        return uint160((uint256(1) << 192) / inv);
    }

    /// sqrt(amount1 / amount0) as a Q64.96 number, without overflowing for any price Uniswap accepts.
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) private pure returns (uint160 sqrtPriceX96) {
        uint256 s = amount1 / amount0 < (1 << 64)
            ? Math.sqrt(FullMath.mulDiv(amount1, 1 << 192, amount0))
            : Math.sqrt(FullMath.mulDiv(amount1, 1 << 128, amount0)) << 32;
        if (s < TickMath.MIN_SQRT_PRICE || s >= TickMath.MAX_SQRT_PRICE) revert BadPrice();
        sqrtPriceX96 = uint160(s);
    }

    function _floorTick(int24 tick) private pure returns (int24) {
        int24 compressed = tick / C.TICK_SPACING;
        if (tick < 0 && tick % C.TICK_SPACING != 0) --compressed;
        return compressed * C.TICK_SPACING;
    }

    /// Read by the hook while a pool is being created.
    function launching() external view returns (address token, uint160 graduationSqrtPriceX96) {
        return (_launchingToken, _launchingGraduationPrice);
    }

    /* ------------------------------------------------------------------ */
    /*                  Trading (swaps in the token's pool)               */
    /* ------------------------------------------------------------------ */

    /// @notice Buy with `amountIn` of the pair asset (fees included), in the token's Uniswap pool. For ETH pairs
    ///         send exactly `amountIn` as value; for other pairs approve this contract first.
    function buy(address token, uint256 amountIn, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensBought)
    {
        if (block.timestamp > deadline) revert Expired();
        TokenInfo storage t = _known(token);
        if (amountIn == 0) revert ZeroAmount();
        if (msg.value != (t.quote == address(0) ? amountIn : 0)) revert WrongValue();
        tokensBought = abi.decode(_unlock(Action.BUY, abi.encode(token, amountIn, minTokensOut, msg.sender)), (uint256));
    }

    /// @notice Sell `tokensIn` in the token's Uniswap pool (approve this contract for the tokens first).
    ///         0.5% of them is burned (sent to 0x...dEaD) and 1.3% of the pair asset paid out goes to the fees.
    function sell(address token, uint256 tokensIn, uint256 minQuoteOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (block.timestamp > deadline) revert Expired();
        _known(token);
        if (tokensIn == 0) revert ZeroAmount();
        quoteOut = abi.decode(_unlock(Action.SELL, abi.encode(token, tokensIn, minQuoteOut, msg.sender)), (uint256));
    }

    /// Runs in our own unlock, or directly if this call is already inside one (a zap or router).
    function _unlock(Action action, bytes memory payload) private returns (bytes memory) {
        bytes memory data = abi.encode(action, payload);
        return poolManager.exttload(MANAGER_UNLOCKED_SLOT) != bytes32(0) ? _handle(data) : poolManager.unlock(data);
    }

    /// The pool manager only calls this on the contract that called unlock, so `data` always comes from us.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return _handle(data);
    }

    function _handle(bytes memory data) private returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.CLAIM) {
            (address[] memory tokens, address creator) = abi.decode(payload, (address[], address));
            return abi.encode(_claim(tokens, creator));
        }
        if (action == Action.WITHDRAW) {
            (address quote, address wallet, address to) = abi.decode(payload, (address, address, address));
            return abi.encode(_withdraw(quote, wallet, to));
        }
        if (action == Action.PAY_OUT) {
            _payOut(abi.decode(payload, (address)));
            return "";
        }
        (address token, uint256 amount, uint256 minOut, address user) =
            abi.decode(payload, (address, uint256, uint256, address));
        uint256 out = action == Action.LAUNCH
            ? _addSupply(token, amount, minOut, user)
            : _swap(token, action == Action.BUY, amount, minOut, user);
        _payOut(tokenInfo[token].quote); // the trader has paid in: send the platform and contest fees
        return abi.encode(out);
    }

    /// Puts the whole supply into the pool as the locked position, then makes the creator's first buy.
    function _addSupply(address token, uint256 firstBuy, uint256 minOut, address creator)
        private
        returns (uint256 tokensBought)
    {
        TokenInfo storage t = tokenInfo[token];
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKeyFor(token),
            IPoolManager.ModifyLiquidityParams({
                tickLower: t.tickLower,
                tickUpper: t.tickUpper,
                liquidityDelta: int256(uint256(t.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        uint256 used = uint256(-int256(token < t.quote ? delta.amount0() : delta.amount1()));
        _settle(Currency.wrap(token), address(this), used);
        if (C.SUPPLY > used) IERC20(token).safeTransfer(C.BURN_ADDRESS, C.SUPPLY - used); // rounding dust
        if (firstBuy > 0) tokensBought = _swap(token, true, firstBuy, minOut, creator);
    }

    /// An exact-input swap in the token's pool for `user`: they pay `amountIn` and get the output.
    function _swap(address token, bool isBuy, uint256 amountIn, uint256 minOut, address user)
        private
        returns (uint256 amountOut)
    {
        PoolKey memory key = poolKeyFor(token);
        bool zeroForOne = isBuy != (token < tokenInfo[token].quote); // a buy pays the pair asset
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 paid, int128 got) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (uint256(-int256(paid)) != amountIn) revert Slippage(); // the hook makes swaps all or nothing
        amountOut = uint256(int256(got));
        if (amountOut == 0) revert ZeroAmount();
        if (amountOut < minOut) revert Slippage();
        (Currency payIn, Currency payOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        _settle(payIn, user, amountIn);
        poolManager.take(payOut, user, amountOut);
    }

    /// Pays `amount` into the pool manager: from this contract (its tokens, or ETH sent with the call) or
    /// from `payer` (an approved ERC-20). Always sync first, ETH included: anyone can call sync() earlier
    /// in the same transaction (for example a wallet receiving a fee), and settling after someone else's
    /// sync would fail.
    function _settle(Currency currency, address payer, uint256 amount) private {
        if (amount == 0) return;
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            IERC20 erc20 = IERC20(Currency.unwrap(currency));
            if (payer == address(this)) erc20.safeTransfer(address(poolManager), amount);
            else erc20.safeTransferFrom(payer, address(poolManager), amount);
            poolManager.settle();
        }
    }

    /* ------------------------------------------------------------------ */
    /*                                Fees                                */
    /* ------------------------------------------------------------------ */

    /// Called by the hook after it credited this contract `amount` of the pair asset as Uniswap claims:
    /// 9/13 to the creator (claimable), 3/13 to the platform, 1/13 to the contest wallet.
    function collectPoolFee(address token, uint256 amount) external {
        if (msg.sender != address(hook)) revert NotHook();
        address quote = tokenInfo[token].quote;
        uint256 toCreator = amount * C.CREATOR_BPS / C.QUOTE_FEE_BPS;
        uint256 toPlatform = amount * C.PLATFORM_BPS / C.QUOTE_FEE_BPS;
        uint256 toContest = amount - toCreator - toPlatform;
        creatorFees[token] += toCreator;
        pendingPayouts[platformWallet][quote] += toPlatform;
        pendingPayouts[contestWallet][quote] += toContest;
        owed[quote] += amount;
        emit FeesSplit(token, toCreator, toPlatform, toContest);
    }

    /// Called by the hook on the buy that brings the pool's pair asset to the graduation target.
    function onGraduated(address token) external {
        if (msg.sender != address(hook)) revert NotHook();
        tokenInfo[token].graduated = true;
        emit Graduated(token, poolKeyFor(token).toId());
    }

    /// @notice Sends the platform and contest wallets their fees in `quote` now. This happens by itself after
    ///         every trade made through this contract; this is for fees from trades made in other apps.
    function payOutFees(address quote) external nonReentrant {
        _unlock(Action.PAY_OUT, abi.encode(quote));
    }

    /// @notice The creator collects the fees their token earned.
    function claimCreatorFees(address token) external nonReentrant returns (uint256 amount) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        amount = abi.decode(_unlock(Action.CLAIM, abi.encode(tokens, msg.sender)), (uint256));
        if (amount == 0) revert NothingToWithdraw();
    }

    /// @notice Collect the creator fees of several tokens at once (tokens with nothing owed are skipped).
    function claimCreatorFeesMany(address[] calldata tokens) external nonReentrant {
        _unlock(Action.CLAIM, abi.encode(tokens, msg.sender));
    }

    /// @notice A platform or contest wallet withdraws fees that couldn't be sent to it, to any address it
    ///         chooses (so a wallet that can't receive ETH can still collect).
    function withdrawPayout(address quote, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = abi.decode(_unlock(Action.WITHDRAW, abi.encode(quote, msg.sender, to)), (uint256));
    }

    /// @notice The creator can move their fee rights to another address (for example a multisig).
    function setCreator(address token, address newCreator) external {
        TokenInfo storage t = tokenInfo[token];
        if (msg.sender != t.creator) revert NotCreator();
        if (newCreator == address(0)) revert ZeroAddress();
        t.creator = newCreator;
        emit CreatorChanged(token, msg.sender, newCreator);
    }

    function _claim(address[] memory tokens, address creator) private returns (uint256 total) {
        for (uint256 i; i < tokens.length; ++i) {
            TokenInfo storage t = tokenInfo[tokens[i]];
            if (creator != t.creator) revert NotCreator();
            uint256 amount = creatorFees[tokens[i]];
            if (amount == 0) continue;
            creatorFees[tokens[i]] = 0;
            owed[t.quote] -= amount;
            _redeem(t.quote);
            _send(t.quote, creator, amount);
            total += amount;
            emit CreatorFeesClaimed(tokens[i], creator, t.quote, amount);
        }
    }

    function _withdraw(address quote, address wallet, address to) private returns (uint256 amount) {
        amount = pendingPayouts[wallet][quote];
        if (amount == 0) revert NothingToWithdraw();
        pendingPayouts[wallet][quote] = 0;
        owed[quote] -= amount;
        _redeem(quote);
        _send(quote, to, amount);
        emit PayoutWithdrawn(wallet, quote, amount);
    }

    /// Inside an unlock: turns our fee claims into the pair asset, then sends the platform and contest wallets
    /// what they're owed. ETH gets limited gas, so a wallet that can't receive never blocks trading: its
    /// balance just stays here.
    function _payOut(address quote) private {
        _redeem(quote);
        _push(quote, platformWallet);
        _push(quote, contestWallet);
    }

    function _push(address quote, address wallet) private {
        uint256 amount = pendingPayouts[wallet][quote];
        if (amount == 0) return;
        bool ok;
        if (quote == address(0)) (ok,) = wallet.call{value: amount, gas: WALLET_GAS}("");
        else ok = IERC20(quote).trySafeTransfer(wallet, amount);
        if (!ok) {
            emit PayoutDeferred(wallet, quote, amount);
            return;
        }
        pendingPayouts[wallet][quote] = 0;
        owed[quote] -= amount;
        emit PayoutSent(wallet, quote, amount);
    }

    /// Inside an unlock: turns all our Uniswap claims on `quote` into the asset itself.
    function _redeem(address quote) private {
        Currency c = Currency.wrap(quote);
        uint256 claims = poolManager.balanceOf(address(this), c.toId());
        if (claims == 0) return;
        poolManager.burn(address(this), c.toId(), claims);
        uint256 before = _balance(quote);
        poolManager.take(c, address(this), claims);
        // a pair asset that takes a fee on transfer would leave us short
        if (_balance(quote) - before != claims) revert UnsupportedPairToken();
    }

    function _send(address quote, address to, uint256 amount) private {
        if (amount == 0) return;
        if (quote == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }

    function _balance(address quote) private view returns (uint256) {
        return quote == address(0) ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

    /* ------------------------------------------------------------------ */
    /*                                Views                               */
    /* ------------------------------------------------------------------ */

    /// The Uniswap v4 pool key of a token.
    function poolKeyFor(address token) public view returns (PoolKey memory key) {
        address quote = tokenInfo[token].quote;
        (address c0, address c1) = quote < token ? (quote, token) : (token, quote);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: C.POOL_FEE,
            tickSpacing: C.TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// The Uniswap v4 pool id of a token (what DexScreener and explorers show for the pool).
    function poolIdFor(address token) external view returns (PoolId) {
        _known(token);
        return poolKeyFor(token).toId();
    }

    /// The pair asset in the token's pool right now: graduation happens when it reaches the target.
    function quotePaired(address token) public view returns (uint256) {
        TokenInfo storage t = _known(token);
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolKeyFor(token).toId());
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(t.tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(t.tickUpper);
        if (sqrtP < sqrtA) sqrtP = sqrtA;
        if (sqrtP > sqrtB) sqrtP = sqrtB;
        return token < t.quote
            ? SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, t.liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, t.liquidity, false);
    }

    /// What a buy of `amountIn` (fees included) would give right now. Matches the trade to within rounding
    /// (well under a millionth of a percent): use minTokensOut for slippage. `amountUsed` is always `amountIn`.
    function previewBuy(address token, uint256 amountIn)
        external
        view
        returns (uint256 tokensOut, uint256 burned, uint256 fee, uint256 amountUsed)
    {
        fee = C.feeOn(amountIn, C.QUOTE_FEE_BPS);
        uint256 out = _simulate(token, true, amountIn - fee);
        burned = C.feeOn(out, C.BURN_BPS);
        tokensOut = out - burned;
        amountUsed = amountIn;
    }

    /// What selling `tokensIn` would pay right now (after fees), to within rounding.
    function previewSell(address token, uint256 tokensIn) external view returns (uint256 quoteOut, uint256 burned, uint256 fee) {
        burned = C.feeOn(tokensIn, C.BURN_BPS);
        uint256 gross = _simulate(token, false, tokensIn - burned);
        fee = C.feeOn(gross, C.QUOTE_FEE_BPS);
        quoteOut = gross - fee;
    }

    /// Output of an exact-input swap of `amountIn` against the token's locked position (the only liquidity).
    function _simulate(address token, bool isBuy, uint256 amountIn) private view returns (uint256 amountOut) {
        TokenInfo storage t = _known(token);
        bool zeroForOne = isBuy != (token < t.quote);
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolKeyFor(token).toId());
        uint160 end = TickMath.getSqrtPriceAtTick(zeroForOne ? t.tickLower : t.tickUpper);
        if (zeroForOne ? sqrtP <= end : sqrtP >= end) revert TooLarge();
        uint256 used;
        (, used, amountOut,) = SwapMath.computeSwapStep(sqrtP, end, t.liquidity, -amountIn.toInt256(), 0);
        if (used < amountIn) revert TooLarge();
    }

    /// Pool price: pair-asset units for 1e18 token units (1 whole token).
    function spotPrice(address token) external view returns (uint256) {
        TokenInfo storage t = _known(token);
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolKeyFor(token).toId());
        if (token < t.quote) return FullMath.mulDiv(FullMath.mulDiv(sqrtP, sqrtP, 1 << 64), 1e18, 1 << 128);
        return FullMath.mulDiv(FullMath.mulDiv(1e18, 1 << 96, sqrtP), 1 << 96, sqrtP);
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function _known(address token) private view returns (TokenInfo storage t) {
        t = tokenInfo[token];
        if (t.creator == address(0)) revert UnknownToken();
    }

    /* ------------------------------------------------------------------ */
    /*                     Hook deployment (owner, once)                  */
    /* ------------------------------------------------------------------ */

    function hookInitCodeHash() public view returns (bytes32) {
        return factory.hookInitCodeHash(poolManager);
    }

    /// @notice Free to call (no transaction): finds a salt in [start, start + count) that gives the hook an
    ///         address with the right permission bits. On average one in 16,384 salts works: call it
    ///         with start = 0 and count = 50,000, and if nothing is found, again with start = 50,000.
    function findHookSalt(uint256 start, uint256 count) external view returns (bytes32 salt, address hookAddress, bool found) {
        bytes32 initHash = hookInitCodeHash();
        address deployer = address(factory);
        uint256 end = start + count;
        for (uint256 i = start; i < end; ++i) {
            address a = Create2.computeAddress(bytes32(i), initHash, deployer);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && a.code.length == 0) return (bytes32(i), a, true);
        }
    }

    /// @notice Deploys the hook at the address given by `salt` (from findHookSalt). Can only happen once.
    function deployHook(bytes32 salt) external onlyOwner {
        if (address(hook) != address(0)) revert HookAlreadySet();
        hook = factory.deployHook(salt, poolManager);
        emit HookDeployed(address(hook));
    }

    /* ------------------------------------------------------------------ */
    /*                                Owner                               */
    /* ------------------------------------------------------------------ */

    /// @notice Turn a pair asset on or off for new launches and set its graduation target (in the
    ///         asset's smallest unit, e.g. 9000e6 for 9,000 USDG). Tokens already launched keep theirs.
    function setPair(address quote, bool enabled, uint128 target) external onlyOwner {
        _setPair(quote, enabled, target);
    }

    function setPlatformWallet(address wallet) external onlyOwner {
        _setPlatformWallet(wallet);
    }

    function setContestWallet(address wallet) external onlyOwner {
        _setContestWallet(wallet);
    }

    function setLaunchesPaused(bool paused) external onlyOwner {
        launchesPaused = paused;
        emit LaunchesPausedSet(paused);
    }

    function _setPair(address quote, bool enabled, uint128 target) private {
        if (quote != address(0) && quote.code.length == 0) revert NotAContract();
        if (enabled && target < 1e6) revert BadTarget();
        pairs[quote] = Pair({enabled: enabled, target: target});
        emit PairSet(quote, enabled, target);
    }

    function _setPlatformWallet(address wallet) private {
        if (wallet == address(0)) revert ZeroAddress();
        platformWallet = wallet;
        emit PlatformWalletSet(wallet);
    }

    function _setContestWallet(address wallet) private {
        if (wallet == address(0)) revert ZeroAddress();
        contestWallet = wallet;
        emit ContestWalletSet(wallet);
    }
}
