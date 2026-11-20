// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BurnRiseLaunchpad} from "../src/BurnRiseLaunchpad.sol";
import {BurnRiseHook} from "../src/BurnRiseHook.sol";
import {BurnRiseConfig as C} from "../src/BurnRiseConfig.sol";
import {Base, MockERC20} from "./Base.sol";

/* -------------------------------------------------------------------------- */
/*  Pre-audit review: stateful fuzzing of the money flows, and the reentrancy  */
/*  paths Slither points at. Test-only: nothing here changes the contracts.    */
/* -------------------------------------------------------------------------- */

/// A creator that is a contract and trades a BurnRise pool straight on the PoolManager while its creator fees
/// are being paid (the PoolManager is unlocked at that moment, and the creator gets all the gas it wants).
contract TradingCreator {
    IPoolManager public immutable pm;
    BurnRiseLaunchpad public immutable pad;
    address public target; // an ETH-pair BurnRise token it buys with half of every ETH claim (0 = off)

    constructor(IPoolManager pm_, BurnRiseLaunchpad pad_) {
        pm = pm_;
        pad = pad_;
    }

    function setTarget(address t) external {
        target = t;
    }

    receive() external payable {
        if (msg.sender != address(pad) || target == address(0)) return;
        uint256 amt = msg.value / 2;
        if (amt == 0) return;
        PoolKey memory key = pad.poolKeyFor(target); // ETH is currency0
        BalanceDelta d = pm.swap(key, IPoolManager.SwapParams(true, -int256(amt), TickMath.MIN_SQRT_PRICE + 1), "");
        pm.sync(key.currency0);
        pm.settle{value: uint128(-d.amount0())}();
        pm.take(key.currency1, address(this), uint128(d.amount1()));
    }
}

/// A platform or contest wallet that tries the same while it is being paid, with the 50,000 gas it gets.
contract TradingWallet {
    IPoolManager public immutable pm;
    BurnRiseLaunchpad public immutable pad;
    address public target;

    constructor(IPoolManager pm_, BurnRiseLaunchpad pad_) {
        pm = pm_;
        pad = pad_;
    }

    function setTarget(address t) external {
        target = t;
    }

    /// The cheapest trade it can make: no sync (the launchpad left ETH synced) and the tokens go to 0x...dEaD,
    /// whose balance is already warm, instead of a new balance of its own.
    receive() external payable {
        if (msg.sender == address(pm) || target == address(0)) return;
        PoolKey memory key = pad.poolKeyFor(target);
        BalanceDelta d = pm.swap(key, IPoolManager.SwapParams(true, -int256(msg.value), TickMath.MIN_SQRT_PRICE + 1), "");
        pm.settle{value: msg.value}();
        pm.take(key.currency1, C.BURN_ADDRESS, uint128(d.amount1()));
    }
}

/// Pays a wallet from inside a PoolManager unlock with unlimited gas, and measures what its receive used.
contract GasProbe is IUnlockCallback {
    IPoolManager public immutable pm;
    uint256 public used;
    bool public ok;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function probe(address wallet) external payable {
        pm.unlock(abi.encode(wallet, msg.value));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address wallet, uint256 v) = abi.decode(data, (address, uint256));
        uint256 g = gasleft();
        (bool success,) = wallet.call{value: v}("");
        used = g - gasleft();
        ok = success;
        return "";
    }
}

/// A plain wallet that can be switched between taking and refusing ETH.
contract ToggleWallet {
    bool public accept;

    function setAccept(bool a) external {
        accept = a;
    }

    receive() external payable {
        require(accept, "no ETH please");
    }
}

/// A wallet with no receive at all.
contract MuteWallet {}

/// A zap or aggregator: trades through the launchpad from inside its own PoolManager unlock.
contract UnlockedTrader is IUnlockCallback {
    IPoolManager public immutable pm;
    BurnRiseLaunchpad public immutable pad;

    constructor(IPoolManager pm_, BurnRiseLaunchpad pad_) {
        pm = pm_;
        pad = pad_;
    }

    function buy(address token, uint256 amt) external payable {
        pm.unlock(abi.encode(true, token, amt));
    }

    function sell(address token, uint256 amt) external {
        pm.unlock(abi.encode(false, token, amt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool isBuy, address token, uint256 amt) = abi.decode(data, (bool, address, uint256));
        if (isBuy) pad.buy{value: amt}(token, amt, 0, block.timestamp);
        else pad.sell(token, amt, 0, block.timestamp);
        return "";
    }

    receive() external payable {}
}

/// Everything people can do, in random order: trades through the launchpad, through a plain Uniswap router
/// (every exact-in / exact-out mode) and from inside another unlock; claims, hand-overs, payouts, withdrawals,
/// wallet changes, wallets that refuse ETH, donations to the pools, time passing.
/// A call that fails for a reason other than the expected ones is counted, and an invariant requires none.
contract AuditHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    BurnRiseLaunchpad public immutable pad;
    IPoolManager public immutable pm;
    PoolSwapTest public immutable router;
    PoolDonateTest public immutable donor;
    address public immutable owner;
    TradingCreator public immutable tc;
    UnlockedTrader public immutable ut;
    ToggleWallet public immutable tw1;
    ToggleWallet public immutable tw2;
    address public immutable creatorEoa;
    address public immutable collector;

    address[4] public tokens;
    address[3] public quotes;
    address[3] public actors;
    address[6] public wallets; // [0..2] platform choices, [3..5] contest choices
    mapping(address => address) public creatorOf;

    uint256 public unexpected;
    string public lastWhere;
    bytes public lastErr;
    mapping(string => uint256) public count;

    constructor(
        BurnRiseLaunchpad pad_,
        IPoolManager pm_,
        PoolSwapTest router_,
        address owner_,
        address[4] memory tokens_,
        address[3] memory quotes_,
        address[3] memory actors_,
        address creator_,
        TradingCreator tc_,
        UnlockedTrader ut_,
        address[6] memory wallets_
    ) {
        pad = pad_;
        pm = pm_;
        router = router_;
        donor = new PoolDonateTest(pm_);
        owner = owner_;
        tokens = tokens_;
        quotes = quotes_;
        actors = actors_;
        creatorEoa = creator_;
        tc = tc_;
        ut = ut_;
        wallets = wallets_;
        tw1 = ToggleWallet(payable(wallets_[1]));
        tw2 = ToggleWallet(payable(wallets_[4]));
        collector = makeAddr("collector");
        for (uint256 i; i < 4; ++i) creatorOf[tokens_[i]] = creator_;
    }

    receive() external payable {}

    /* ------------------------------- trading ------------------------------ */

    function buyPad(uint256 a, uint256 t, uint256 amt) external {
        address who = actors[a % 3];
        address token = tokens[t % 4];
        address q = _quote(token);
        amt = bound(amt, 1, _unit(q) * 8);
        if (q != address(0)) MockERC20(q).mint(who, amt);
        vm.prank(who);
        try pad.buy{value: q == address(0) ? amt : 0}(token, amt, 0, block.timestamp) returns (uint256) {
            count["buyPad"]++;
        } catch (bytes memory err) {
            if (_is(err, BurnRiseLaunchpad.ZeroAmount.selector)) count["dust"]++;
            else _flag("buyPad", err);
        }
    }

    function sellPad(uint256 a, uint256 t, uint256 amt) external {
        address who = actors[a % 3];
        address token = tokens[t % 4];
        uint256 bal = IERC20(token).balanceOf(who);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        bool tooBig = _tooBig(token, amt);
        vm.prank(who);
        try pad.sell(token, amt, 0, block.timestamp) returns (uint256) {
            count["sellPad"]++;
            if (tooBig) _flag("sellPad: went through past the known big-sell limit", "");
        } catch (bytes memory err) {
            if (tooBig) count["bigSell"]++;
            else if (_is(err, BurnRiseLaunchpad.ZeroAmount.selector)) count["dust"]++;
            else _flag("sellPad", err);
        }
    }

    /// mode: 0 exact-in buy, 1 exact-in sell, 2 exact-out buy, 3 exact-out sell.
    function routerTrade(uint256 a, uint256 t, uint256 mode, uint256 amt) external {
        address who = actors[a % 3];
        address token = tokens[t % 4];
        address q = _quote(token);
        bool isBuy = mode % 2 == 0;
        bool exactIn = (mode >> 1) % 2 == 0;
        bool zeroForOne = isBuy != (token < q);
        uint256 bal = IERC20(token).balanceOf(who);
        uint256 poolTokens = IERC20(token).balanceOf(address(pm));
        int256 spec;
        uint256 value;
        if (isBuy && exactIn) {
            amt = bound(amt, 1, _unit(q) * 8);
            spec = -int256(amt);
            if (q == address(0)) value = amt;
            else MockERC20(q).mint(who, amt);
        } else if (isBuy) {
            if (poolTokens < 1e12) return;
            amt = bound(amt, 1, poolTokens / 20);
            spec = int256(amt);
            if (q == address(0)) value = _unit(q) * 1000; // plenty; the router hands back the rest
            else MockERC20(q).mint(who, _unit(q) * 1000);
        } else if (exactIn) {
            if (bal == 0) return;
            amt = bound(amt, 1, bal);
            spec = -int256(amt);
        } else {
            if (bal < 1e12) return;
            (bool ok, uint256 reachable) = _previewSell(token, bal / 2);
            if (!ok || reachable == 0) return;
            amt = bound(amt, 1, reachable);
            spec = int256(amt);
        }
        bool tooBig = !isBuy && _tooBig(token, exactIn ? amt : bal / 2);
        PoolKey memory key = pad.poolKeyFor(token);
        vm.prank(who);
        try router.swap{value: value}(
            key,
            IPoolManager.SwapParams(zeroForOne, spec, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            count[exactIn ? "routerExactIn" : "routerExactOut"]++;
        } catch (bytes memory err) {
            if (tooBig) count["bigSell"]++;
            else _flag(exactIn ? "routerExactIn" : "routerExactOut", err);
        }
    }

    /// Trades through the launchpad from inside another contract's unlock (ETH pairs).
    function unlockedTrade(uint256 t, uint256 amt, bool isBuy) external {
        address token = tokens[t % 2];
        if (isBuy) {
            amt = bound(amt, 1, 4 ether);
            try ut.buy{value: amt}(token, amt) {
                count["unlockedBuy"]++;
            } catch (bytes memory err) {
                if (_is(err, BurnRiseLaunchpad.ZeroAmount.selector)) count["dust"]++;
                else _flag("unlockedBuy", err);
            }
        } else {
            uint256 bal = IERC20(token).balanceOf(address(ut));
            if (bal == 0) return;
            amt = bound(amt, 1, bal);
            bool tooBig = _tooBig(token, amt);
            try ut.sell(token, amt) {
                count["unlockedSell"]++;
            } catch (bytes memory err) {
                if (tooBig) count["bigSell"]++;
                else if (_is(err, BurnRiseLaunchpad.ZeroAmount.selector)) count["dust"]++;
                else _flag("unlockedSell", err);
            }
        }
    }

    /// Someone gives the pool money with Uniswap's donate (the hook doesn't stop it): it becomes fees of the
    /// locked position, which nobody can ever collect.
    function donate(uint256 t, uint256 amt) external {
        address token = tokens[t % 4];
        address q = _quote(token);
        amt = bound(amt, 1, _unit(q));
        if (q != address(0)) {
            MockERC20(q).mint(address(this), amt);
            IERC20(q).approve(address(donor), amt);
        }
        (uint256 a0, uint256 a1) = q < token ? (amt, uint256(0)) : (uint256(0), amt);
        try donor.donate{value: q == address(0) ? amt : 0}(pad.poolKeyFor(token), a0, a1, "") {
            count["donate"]++;
        } catch {
            count["donateRefused"]++; // no liquidity at the current price: Uniswap refuses, fine
        }
    }

    /* -------------------------- fees and settings -------------------------- */

    function claim(uint256 t) external {
        address token = tokens[t % 4];
        address cr = creatorOf[token];
        uint256 due = pad.creatorFees(token);
        vm.prank(cr);
        try pad.claimCreatorFees(token) returns (uint256 got) {
            count["claim"]++;
            if (got != due) _flag("claim paid a different amount than owed", "");
        } catch (bytes memory err) {
            if (!(due == 0 && _is(err, BurnRiseLaunchpad.NothingToWithdraw.selector))) _flag("claim", err);
        }
    }

    function claimMany(uint256 s) external {
        address cr = s % 2 == 0 ? creatorEoa : address(tc);
        address[] memory list = new address[](5);
        uint256 n;
        for (uint256 i; i < 5; ++i) {
            address token = tokens[(s >> (8 * (i + 1))) % 4]; // random order, repeats allowed
            if (creatorOf[token] == cr) list[n++] = token;
        }
        assembly {
            mstore(list, n)
        }
        vm.prank(cr);
        try pad.claimCreatorFeesMany(list) {
            count["claimMany"]++;
        } catch (bytes memory err) {
            _flag("claimMany", err);
        }
    }

    function handOver(uint256 t) external {
        address token = tokens[t % 4];
        address cur = creatorOf[token];
        address next = cur == creatorEoa ? address(tc) : creatorEoa;
        vm.prank(cur);
        try pad.setCreator(token, next) {
            creatorOf[token] = next;
            count["handOver"]++;
        } catch (bytes memory err) {
            _flag("handOver", err);
        }
    }

    function payOut(uint256 qi) external {
        try pad.payOutFees(quotes[qi % 3]) {
            count["payOut"]++;
        } catch (bytes memory err) {
            _flag("payOut", err);
        }
    }

    function withdraw(uint256 wi, uint256 qi) external {
        address w = wallets[wi % 6];
        address q = quotes[qi % 3];
        uint256 due = pad.pendingPayouts(w, q);
        uint256 before = _bal(q, collector);
        vm.prank(w);
        try pad.withdrawPayout(q, collector) returns (uint256 got) {
            count["withdraw"]++;
            if (got != due || _bal(q, collector) - before != due) _flag("withdraw paid a wrong amount", "");
        } catch (bytes memory err) {
            if (!(due == 0 && _is(err, BurnRiseLaunchpad.NothingToWithdraw.selector))) _flag("withdraw", err);
        }
    }

    function switchWallets(uint256 s) external {
        vm.startPrank(owner);
        pad.setPlatformWallet(wallets[s % 3]);
        pad.setContestWallet(wallets[3 + (s >> 8) % 3]);
        vm.stopPrank();
        count["switchWallets"]++;
    }

    function toggleWallets(uint256 s) external {
        tw1.setAccept(s % 2 == 0);
        tw2.setAccept((s >> 1) % 2 == 0);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }

    /* -------------------------------- helpers ------------------------------ */

    function _quote(address token) internal view returns (address q) {
        (,,, q,,,,) = pad.tokenInfo(token);
    }

    function _unit(address q) internal view returns (uint256) {
        return q == address(0) ? 1 ether : q == quotes[1] ? 1_000e6 : 10e18;
    }

    function _bal(address asset, address who) internal view returns (uint256) {
        return asset == address(0) ? who.balance : IERC20(asset).balanceOf(who);
    }

    /// The known limit: a sell whose 0.5% burn is more than the pool's whole token reserve.
    function _tooBig(address token, uint256 tokensIn) internal view returns (bool) {
        return C.feeOn(tokensIn, C.BURN_BPS) > IERC20(token).balanceOf(address(pm));
    }

    function _previewSell(address token, uint256 tokensIn) internal view returns (bool, uint256) {
        try pad.previewSell(token, tokensIn) returns (uint256 out, uint256, uint256) {
            return (true, out);
        } catch {
            return (false, 0);
        }
    }

    function _is(bytes memory err, bytes4 sel) internal pure returns (bool) {
        return err.length >= 4 && bytes4(err) == sel;
    }

    function _flag(string memory where, bytes memory err) internal {
        unexpected++;
        lastWhere = where;
        lastErr = err;
    }
}

/// Stateful fuzzing: random sequences of everything above, on four tokens (two ETH pairs, a 6-decimal pair
/// where the token is currency1 and an 18-decimal pair where the token is currency0).
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract AuditInvariantTest is Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    AuditHandler handler;
    TradingCreator tc;
    UnlockedTrader ut;
    address[4] toks;
    address[3] qs;
    address[6] ws;

    function setUp() public override {
        super.setUp();
        MockERC20 usd = _mockQuoteAt(LOW_ADDR, 6);
        MockERC20 stock = _mockQuoteAt(HIGH_ADDR, 18);
        pad.setPair(address(usd), true, 9_000e6);
        pad.setPair(address(stock), true, 48e18);
        toks[0] = _launchEth(0);
        toks[1] = _launchEth(0.3 ether);
        toks[2] = _launchErc20(usd, 400e6);
        toks[3] = _launchErc20(stock, 0);
        qs = [address(0), address(usd), address(stock)];

        tc = new TradingCreator(manager, pad);
        tc.setTarget(toks[1]);
        ut = new UnlockedTrader(manager, pad);
        ws = [platform, address(new ToggleWallet()), address(new MuteWallet()), contest, address(new ToggleWallet()), address(new MuteWallet())];

        address[6] memory holders = [alice, bob, carol, creator, address(tc), address(ut)];
        for (uint256 i; i < 6; ++i) {
            vm.deal(holders[i], 1e9 ether);
            vm.startPrank(holders[i]);
            for (uint256 k; k < 4; ++k) {
                IERC20(toks[k]).approve(address(pad), type(uint256).max);
                IERC20(toks[k]).approve(address(router), type(uint256).max);
            }
            usd.approve(address(pad), type(uint256).max);
            usd.approve(address(router), type(uint256).max);
            stock.approve(address(pad), type(uint256).max);
            stock.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }

        handler = new AuditHandler(pad, manager, router, address(this), toks, qs, [alice, bob, carol], creator, tc, ut, ws);
        vm.deal(address(handler), 1e9 ether);

        bytes4[] memory sels = new bytes4[](14);
        sels[0] = AuditHandler.buyPad.selector;
        sels[1] = AuditHandler.sellPad.selector;
        sels[2] = AuditHandler.routerTrade.selector;
        sels[3] = AuditHandler.unlockedTrade.selector;
        sels[4] = AuditHandler.donate.selector;
        sels[5] = AuditHandler.claim.selector;
        sels[6] = AuditHandler.claimMany.selector;
        sels[7] = AuditHandler.handOver.selector;
        sels[8] = AuditHandler.payOut.selector;
        sels[9] = AuditHandler.withdraw.selector;
        sels[10] = AuditHandler.switchWallets.selector;
        sels[11] = AuditHandler.toggleWallets.selector;
        sels[12] = AuditHandler.warp.selector;
        sels[13] = AuditHandler.buyPad.selector; // buys twice as often, so pools get somewhere
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
        targetContract(address(handler));
    }

    /* ------------------------------ invariants ----------------------------- */

    /// Nothing failed for an unexpected reason (dust trades and the known big-sell limit are the only
    /// expected failures; every claim, payout, withdrawal and hand-over must work).
    function invariant_nothingFailsUnexpectedly() public view {
        assertEq(handler.unexpected(), 0, string.concat(handler.lastWhere(), " ", vm.toString(handler.lastErr())));
    }

    /// The launchpad holds exactly what it owes, in each pair asset (the asset itself plus Uniswap claims).
    function invariant_holdsExactlyWhatItOwes() public view {
        for (uint256 i; i < 3; ++i) assertEq(_held(qs[i]), pad.owed(qs[i]), "held == owed");
    }

    /// And what it owes is exactly the creators' unclaimed fees plus every wallet's unsent payouts:
    /// no fee is ever counted twice or left belonging to nobody.
    function invariant_owedIsCreatorFeesPlusPayouts() public view {
        for (uint256 i; i < 3; ++i) {
            uint256 sum;
            for (uint256 k; k < 4; ++k) if (_quote(toks[k]) == qs[i]) sum += pad.creatorFees(toks[k]);
            for (uint256 w; w < 6; ++w) sum += pad.pendingPayouts(ws[w], qs[i]);
            assertEq(sum, pad.owed(qs[i]), "owed == creator fees + payouts");
        }
    }

    /// Every token of every supply is somewhere known: in the pool, burned at 0x...dEaD, or with a holder.
    function invariant_supplyAccountedFor() public view {
        for (uint256 k; k < 4; ++k) {
            IERC20 t = IERC20(toks[k]);
            assertEq(t.totalSupply(), C.SUPPLY, "supply never changes");
            uint256 sum = t.balanceOf(address(manager)) + t.balanceOf(DEAD) + t.balanceOf(alice) + t.balanceOf(bob)
                + t.balanceOf(carol) + t.balanceOf(creator) + t.balanceOf(address(tc)) + t.balanceOf(address(ut));
            assertEq(sum, C.SUPPLY, "every token accounted for");
            assertEq(t.balanceOf(address(pad)), 0, "the launchpad keeps no tokens");
        }
    }

    /// The PoolManager really holds what each pool's position says it has, on both sides, plus the
    /// launchpad's fee claims.
    function invariant_poolsAreBacked() public view {
        uint256[3] memory needQuote;
        for (uint256 k; k < 4; ++k) {
            BurnRiseLaunchpad.TokenInfo memory t = _info(toks[k]);
            uint160 p = _sqrtPrice(toks[k]);
            uint160 a = TickMath.getSqrtPriceAtTick(t.tickLower);
            uint160 b = TickMath.getSqrtPriceAtTick(t.tickUpper);
            if (p < a) p = a;
            if (p > b) p = b;
            uint256 inPool = toks[k] < t.quote
                ? SqrtPriceMath.getAmount0Delta(p, b, t.liquidity, false)
                : SqrtPriceMath.getAmount1Delta(a, p, t.liquidity, false);
            assertGe(IERC20(toks[k]).balanceOf(address(manager)), inPool, "pool tokens backed");
            for (uint256 i; i < 3; ++i) if (qs[i] == t.quote) needQuote[i] += pad.quotePaired(toks[k]);
        }
        for (uint256 i; i < 3; ++i) {
            uint256 claims = manager.balanceOf(address(pad), Currency.wrap(qs[i]).toId());
            assertGe(_bal(qs[i], address(manager)), needQuote[i] + claims, "pair asset backed");
        }
    }

    /// Hook and launchpad agree on graduation, and a token not graduated has never reached its target.
    function invariant_graduation() public view {
        for (uint256 k; k < 4; ++k) {
            (, bool tokenIs0, bool g, uint160 gp) = hook.pools(pad.poolKeyFor(toks[k]).toId());
            assertEq(g, _graduated(toks[k]), "hook and launchpad agree");
            if (!g) {
                uint160 p = _sqrtPrice(toks[k]);
                assertTrue(tokenIs0 ? p < gp : p > gp, "not graduated: below the target");
            }
        }
    }

    /// After each run: everyone sells everything back, every creator claims and every wallet collects.
    /// All of it works, and the launchpad is left owing and holding nothing.
    function afterInvariant() public {
        tc.setTarget(address(0));
        address[6] memory holders = [alice, bob, carol, creator, address(tc), address(ut)];
        for (uint256 k; k < 4; ++k) {
            for (uint256 i; i < 6; ++i) _sellEverything(holders[i], toks[k]);
        }
        for (uint256 k; k < 4; ++k) {
            if (pad.creatorFees(toks[k]) == 0) continue;
            vm.prank(handler.creatorOf(toks[k]));
            pad.claimCreatorFees(toks[k]);
        }
        address collector = makeAddr("collector");
        for (uint256 w; w < 6; ++w) {
            for (uint256 i; i < 3; ++i) {
                if (pad.pendingPayouts(ws[w], qs[i]) == 0) continue;
                vm.prank(ws[w]);
                pad.withdrawPayout(qs[i], collector);
            }
        }
        for (uint256 i; i < 3; ++i) {
            assertEq(pad.owed(qs[i]), 0, "owes nothing");
            assertEq(_held(qs[i]), 0, "holds nothing");
        }
    }

    function _sellEverything(address who, address token) internal {
        for (uint256 n; n < 40; ++n) {
            uint256 bal = IERC20(token).balanceOf(who);
            if (bal == 0) return;
            uint256 part = bal;
            uint256 maxPart = IERC20(token).balanceOf(address(manager)) * 200; // the burn has to fit in the pool
            if (part > maxPart) part = maxPart;
            vm.prank(who);
            try pad.sell(token, part, 0, block.timestamp) {}
            catch (bytes memory err) {
                // only dust can be left: too few tokens to get any of the pair asset back
                assertEq(bytes4(err), BurnRiseLaunchpad.ZeroAmount.selector, "sell back failed");
                (uint256 out,,) = pad.previewSell(token, part);
                assertEq(out, 0, "only dust is left");
                return;
            }
        }
        revert("still holding after 40 sells");
    }

    function _held(address q) internal view returns (uint256) {
        return _bal(q, address(pad)) + manager.balanceOf(address(pad), Currency.wrap(q).toId());
    }
}

/// Focused checks on the paths a reviewer (or Slither) points at.
contract AuditPocTest is Base {
    /// A creator contract that trades on the PoolManager while its ETH fees are being paid: the books stay
    /// exact, the fees of that trade are counted normally, and the claim pays exactly what was owed.
    function test_creatorTradingWhileBeingPaid_keepsTheBooksExact() public {
        TradingCreator tc = new TradingCreator(manager, pad);
        address a = _launchEth(0.5 ether);
        address b = _launchEth(0);
        tc.setTarget(b);
        vm.startPrank(creator);
        pad.setCreator(a, address(tc));
        pad.setCreator(b, address(tc));
        vm.stopPrank();
        _buyEth(alice, a, 3 ether);
        _buyEth(alice, b, 1 ether);

        uint256 dueA = pad.creatorFees(a);
        // paid for a, it buys b with half: that buy earns b's creator (itself) the usual 0.9%, which is
        // already in b's balance when the claim reaches b
        uint256 dueB = pad.creatorFees(b) + _creatorShare(dueA / 2);
        address[] memory list = new address[](2);
        (list[0], list[1]) = (a, b);
        vm.prank(address(tc));
        pad.claimCreatorFeesMany(list);

        assertGt(IERC20(b).balanceOf(address(tc)), 0, "it really traded while being paid");
        assertEq(address(tc).balance, (dueA - dueA / 2) + (dueB - dueB / 2), "paid exactly what was owed");
        assertEq(pad.creatorFees(a), 0);
        assertEq(pad.creatorFees(b), _creatorShare(dueB / 2), "the second trade's fees wait for the next claim");
        _assertBooks(address(0), a, b);
    }

    /// A platform wallet that tries to trade while being paid gets 50,000 gas for it. Measured here: that is not
    /// enough for a Uniswap swap through the BurnRise hook, so its payment is deferred (kept for it) and the
    /// books stay exact.
    function test_walletTradingWhilePaid_runsOutOfGas_andKeepsItsBalance() public {
        TradingWallet w = new TradingWallet(manager, pad);
        address token = _launchEth(0.5 ether);
        w.setTarget(token);
        pad.setPlatformWallet(address(w));
        _buyEth(alice, token, 1 ether);
        uint256 owedW = pad.pendingPayouts(address(w), address(0));
        assertGt(owedW, 0, "payment deferred, kept for the wallet");
        assertEq(address(w).balance, 0);
        _assertBooks(address(0), token, token);

        // with unlimited gas, inside an unlock, the same trade works: it is the gas cap that stops it
        GasProbe probe = new GasProbe(manager);
        vm.deal(address(this), 1 ether);
        probe.probe{value: 0.001 ether}(address(w));
        assertTrue(probe.ok(), "with enough gas the trade works");
        emit log_named_uint("gas the wallet's trade needs", probe.used());
        assertGt(probe.used(), 52_300, "more than the 50,000 gas (+2,300 stipend) a wallet is given");
    }

    /// When the owner changes a wallet, the old wallet keeps what it was owed and can still collect it.
    function test_changingWallets_oldWalletKeepsWhatItIsOwed() public {
        ToggleWallet old = new ToggleWallet();
        pad.setPlatformWallet(address(old));
        address token = _launchEth(1 ether);
        _buyEth(alice, token, 1 ether);
        uint256 owedOld = pad.pendingPayouts(address(old), address(0));
        assertGt(owedOld, 0);

        address fresh = makeAddr("fresh");
        pad.setPlatformWallet(fresh);
        _buyEth(bob, token, 1 ether);
        assertEq(pad.pendingPayouts(address(old), address(0)), owedOld, "the old wallet's balance stays its own");
        assertEq(fresh.balance, C.feeOn(1 ether, 130) * 30 / 130, "the new wallet gets the new fees");

        address to = makeAddr("collector");
        vm.prank(address(old));
        pad.withdrawPayout(address(0), to);
        assertEq(to.balance, owedOld);
        _assertSolvent(address(0));
    }

    /// renounceOwnership comes with OpenZeppelin's Ownable. Called while launches are paused, nobody could
    /// ever launch again (the owner-only test launches need an owner). Documented, not a bug: just never call it.
    function test_renounceWhilePaused_wouldStopLaunchesForGood() public {
        pad.setLaunchesPaused(true);
        pad.renounceOwnership();
        vm.prank(creator);
        vm.expectRevert(BurnRiseLaunchpad.LaunchesArePaused.selector);
        pad.launch("Late", "LATE", "", address(0), 0, 0);
    }

    function _creatorShare(uint256 ethIn) internal pure returns (uint256) {
        return C.feeOn(ethIn, C.QUOTE_FEE_BPS) * C.CREATOR_BPS / C.QUOTE_FEE_BPS;
    }

    /// Owed == unclaimed creator fees + unsent payouts, and the launchpad holds exactly that.
    function _assertBooks(address q, address a, address b) internal view {
        uint256 sum = pad.creatorFees(a) + (a == b ? 0 : pad.creatorFees(b)) + pad.pendingPayouts(pad.platformWallet(), q)
            + pad.pendingPayouts(pad.contestWallet(), q);
        assertEq(sum, pad.owed(q), "owed == creator fees + payouts");
        _assertSolvent(q);
    }
}
