// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BurnRiseLaunchpad} from "../src/BurnRiseLaunchpad.sol";
import {BurnRiseHook} from "../src/BurnRiseHook.sol";
import {BurnRiseConfig as C} from "../src/BurnRiseConfig.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(uint8 d) ERC20("Mock", "MOCK") {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Shared setup and helpers. `router` is a plain Uniswap v4 router: it stands for every other app
/// (DexScreener, aggregators, wallets) that trades BurnRise pools without going through the launchpad.
abstract contract Base is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager manager;
    PoolSwapTest router;
    BurnRiseLaunchpad pad;
    BurnRiseHook hook;

    address platform = makeAddr("platform");
    address contest = 0xd86600CC30c59d3052bd33F3C54e9325D4a46D91;
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant LOW_ADDR = address(0x1000); // a pair token here sorts below every BurnRise token
    address constant HIGH_ADDR = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF; // ... and here above them
    uint160 constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    struct TradeEvent {
        bool found;
        bool isBuy;
        uint256 quoteAmount;
        uint256 tokenAmount;
        uint256 fee;
        uint256 burned;
    }

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        pad = new BurnRiseLaunchpad(manager, address(this), platform, contest);
        (bytes32 salt, address predicted, bool found) = pad.findHookSalt(0, 300_000);
        assertTrue(found, "no hook salt");
        pad.deployHook(salt);
        hook = pad.hook();
        assertEq(address(hook), predicted, "hook address");
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), pad.HOOK_FLAGS(), "hook flags");
        vm.deal(creator, 10_000 ether);
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(carol, 10_000 ether);
    }

    /* ------------------------- launchpad trades ------------------------- */

    function _launchEth(uint256 firstBuy) internal returns (address token) {
        vm.prank(creator);
        (token,) = pad.launch{value: firstBuy}("Ember Cat", "EMBER", "ipfs://meta", address(0), firstBuy, 0);
    }

    function _buyEth(address who, address token, uint256 amount) internal returns (uint256 got) {
        vm.prank(who);
        got = pad.buy{value: amount}(token, amount, 0, block.timestamp);
    }

    function _sell(address who, address token, uint256 amount) internal returns (uint256 got) {
        vm.startPrank(who);
        IERC20(token).approve(address(pad), amount);
        got = pad.sell(token, amount, 0, block.timestamp);
        vm.stopPrank();
    }

    function _mockQuoteAt(address where, uint8 dec) internal returns (MockERC20 q) {
        MockERC20 impl = new MockERC20(dec);
        vm.etch(where, address(impl).code);
        q = MockERC20(where);
    }

    function _launchErc20(MockERC20 q, uint256 firstBuy) internal returns (address token) {
        q.mint(creator, firstBuy);
        vm.startPrank(creator);
        q.approve(address(pad), firstBuy);
        (token,) = pad.launch("Frog", "FROG", "", address(q), firstBuy, 0);
        vm.stopPrank();
    }

    function _buyErc20(address who, MockERC20 q, address token, uint256 amount) internal returns (uint256 got) {
        q.mint(who, amount);
        vm.startPrank(who);
        q.approve(address(pad), amount);
        got = pad.buy(token, amount, 0, block.timestamp);
        vm.stopPrank();
    }

    /// Buys through the launchpad in the token's pair asset (ETH or a mock ERC-20).
    function _buy(address who, address token, uint256 amount) internal returns (uint256) {
        address q = _quote(token);
        return q == address(0) ? _buyEth(who, token, amount) : _buyErc20(who, MockERC20(q), token, amount);
    }

    /* ------------------------ trades from other apps --------------------- */

    function _swap(address who, PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta delta)
    {
        vm.prank(who);
        delta = router.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_LIMIT : MAX_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// Gives `who` plenty of the pair asset and lets the router spend it and the token.
    function _fundRouterTrader(address who, address token) internal {
        address q = _quote(token);
        vm.startPrank(who);
        IERC20(token).approve(address(router), type(uint256).max);
        if (q != address(0)) IERC20(q).approve(address(router), type(uint256).max);
        vm.stopPrank();
        if (q != address(0)) MockERC20(q).mint(who, 1e40);
    }

    /// Foundry runs a whole test as one transaction; this clears the pool manager's per-transaction
    /// "synced currency" the way a new transaction would.
    function _newTx() internal {
        manager.sync(Currency.wrap(address(0)));
    }

    /// zeroForOne for a buy (paying the pair asset) or a sell (paying the token).
    function _dir(address token, bool isBuy) internal view returns (bool) {
        return isBuy != _tokenIs0(token);
    }

    /* -------------------------------- views ------------------------------ */

    function _info(address token) internal view returns (BurnRiseLaunchpad.TokenInfo memory t) {
        (t.creator, t.launchedAt, t.graduated, t.quote, t.target, t.liquidity, t.tickLower, t.tickUpper) =
            pad.tokenInfo(token);
    }

    function _graduated(address token) internal view returns (bool) {
        return _info(token).graduated;
    }

    function _quote(address token) internal view returns (address) {
        return _info(token).quote;
    }

    function _tokenIs0(address token) internal view returns (bool) {
        return token < _quote(token);
    }

    function _sqrtPrice(address token) internal view returns (uint160 p) {
        (p,,,) = IPoolManager(address(manager)).getSlot0(pad.poolKeyFor(token).toId());
    }

    /// Market cap in the pair asset's smallest unit, straight from the pool price (full precision).
    function _marketCap(address token) internal view returns (uint256) {
        uint160 p = _sqrtPrice(token);
        if (_tokenIs0(token)) return FullMath.mulDiv(FullMath.mulDiv(p, p, 1 << 64), C.SUPPLY, 1 << 128);
        return FullMath.mulDiv(FullMath.mulDiv(C.SUPPLY, 1 << 96, p), 1 << 96, p);
    }

    function _bal(address asset, address who) internal view returns (uint256) {
        return asset == address(0) ? who.balance : IERC20(asset).balanceOf(who);
    }

    /// All pair-asset fees a token has paid so far: owed to its creator plus everything the platform and
    /// contest wallets got or are owed (tests that use this give those wallets no other income).
    function _feesPaid(address token) internal view returns (uint256) {
        address q = _quote(token);
        return pad.creatorFees(token) + _bal(q, platform) + pad.pendingPayouts(platform, q) + _bal(q, contest)
            + pad.pendingPayouts(contest, q);
    }

    /// The launchpad holds exactly what it owes in a pair asset: the asset itself plus its Uniswap claims.
    function _assertSolvent(address q) internal view {
        uint256 held = _bal(q, address(pad)) + manager.balanceOf(address(pad), Currency.wrap(q).toId());
        assertEq(held, pad.owed(q), "launchpad holds exactly what it owes");
    }

    /// The hook's Trade event from the recorded logs (call vm.recordLogs() before the trade).
    function _tradeEvent() internal view returns (TradeEvent memory e) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Trade(address,bool,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                e.found = true;
                (e.isBuy, e.quoteAmount, e.tokenAmount, e.fee, e.burned) =
                    abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256));
            }
        }
    }

    /* ---------------- every trade mode through a plain router ------------ */

    struct Snap {
        uint256 q;    // trader's pair asset
        uint256 t;    // trader's tokens
        uint256 dead; // burned so far
        uint256 fees; // fees paid so far
    }

    function _snap(address token, address who) internal view returns (Snap memory s) {
        s = Snap(_bal(_quote(token), who), IERC20(token).balanceOf(who), IERC20(token).balanceOf(DEAD), _feesPaid(token));
    }

    /// Exact input and exact output, buys and sells, through a plain router: each pays exactly 1.3% of the
    /// pair side and burns exactly 0.5% of the token side, and the Trade event says what the trader did.
    function _allModes(address token, uint256 quoteUnit) internal {
        _fundRouterTrader(alice, token);
        _modeExactInBuy(token, quoteUnit);
        _modeExactOutBuy(token, quoteUnit);
        _modeExactInSell(token);
        _modeExactOutSell(token, quoteUnit / 10);
        _assertSolvent(_quote(token));
    }

    function _value(address token, uint256 amount) internal view returns (uint256) {
        return _quote(token) == address(0) ? amount : 0;
    }

    function _modeExactInBuy(address token, uint256 amount) internal {
        Snap memory b = _snap(token, alice);
        vm.recordLogs();
        _swap(alice, pad.poolKeyFor(token), _dir(token, true), -int256(amount), _value(token, amount));
        TradeEvent memory e = _tradeEvent();
        Snap memory a = _snap(token, alice);
        uint256 got = a.t - b.t;
        uint256 burned = a.dead - b.dead;
        assertEq(b.q - a.q, amount, "exact-in buy: paid");
        assertEq(a.fees - b.fees, C.feeOn(amount, 130), "exact-in buy: 1.3% fee");
        assertEq(burned, C.feeOn(got + burned, 50), "exact-in buy: 0.5% burned");
        assertTrue(e.found && e.isBuy, "exact-in buy: event");
        assertEq(e.quoteAmount, amount);
        assertEq(e.tokenAmount, got);
        assertEq(e.fee, a.fees - b.fees);
        assertEq(e.burned, burned);
    }

    function _modeExactOutBuy(address token, uint256 quoteUnit) internal {
        uint256 want = C.SUPPLY / 1000;
        Snap memory b = _snap(token, alice);
        vm.recordLogs();
        _swap(alice, pad.poolKeyFor(token), _dir(token, true), int256(want), _value(token, quoteUnit * 50));
        TradeEvent memory e = _tradeEvent();
        Snap memory a = _snap(token, alice);
        uint256 paid = b.q - a.q;
        uint256 fee = a.fees - b.fees;
        assertEq(a.t - b.t, want, "exact-out buy: got exactly what was asked");
        assertEq(a.dead - b.dead, C.feeOnTop(want, 50), "exact-out buy: 0.5% burned on top");
        assertEq(fee, C.feeOnTop(paid - fee, 130), "exact-out buy: 1.3% fee on top");
        assertTrue(e.found && e.isBuy, "exact-out buy: event");
        assertEq(e.quoteAmount, paid);
        assertEq(e.tokenAmount, want);
        assertEq(e.fee, fee);
        assertEq(e.burned, a.dead - b.dead);
    }

    function _modeExactInSell(address token) internal {
        uint256 amount = IERC20(token).balanceOf(alice) / 3;
        Snap memory b = _snap(token, alice);
        vm.recordLogs();
        _swap(alice, pad.poolKeyFor(token), _dir(token, false), -int256(amount), 0);
        TradeEvent memory e = _tradeEvent();
        Snap memory a = _snap(token, alice);
        uint256 out = a.q - b.q;
        uint256 fee = a.fees - b.fees;
        assertEq(b.t - a.t, amount, "exact-in sell: paid");
        assertEq(a.dead - b.dead, C.feeOn(amount, 50), "exact-in sell: 0.5% burned");
        assertEq(fee, C.feeOn(out + fee, 130), "exact-in sell: 1.3% fee");
        assertTrue(e.found && !e.isBuy, "exact-in sell: event");
        assertEq(e.quoteAmount, out);
        assertEq(e.tokenAmount, amount);
        assertEq(e.fee, fee);
        assertEq(e.burned, a.dead - b.dead);
    }

    function _modeExactOutSell(address token, uint256 want) internal {
        Snap memory b = _snap(token, alice);
        vm.recordLogs();
        _swap(alice, pad.poolKeyFor(token), _dir(token, false), int256(want), 0);
        TradeEvent memory e = _tradeEvent();
        Snap memory a = _snap(token, alice);
        uint256 tokensPaid = b.t - a.t;
        uint256 burned = a.dead - b.dead;
        assertEq(a.q - b.q, want, "exact-out sell: got exactly what was asked");
        assertEq(a.fees - b.fees, C.feeOnTop(want, 130), "exact-out sell: 1.3% fee on top");
        assertEq(burned, C.feeOnTop(tokensPaid - burned, 50), "exact-out sell: 0.5% burned on top");
        assertTrue(e.found && !e.isBuy, "exact-out sell: event");
        assertEq(e.quoteAmount, want);
        assertEq(e.tokenAmount, tokensPaid);
        assertEq(e.fee, a.fees - b.fees);
        assertEq(e.burned, burned);
    }
}
