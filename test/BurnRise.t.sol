// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BurnRiseLaunchpad} from "../src/BurnRiseLaunchpad.sol";
import {BurnRiseHook} from "../src/BurnRiseHook.sol";
import {BurnRiseConfig as C} from "../src/BurnRiseConfig.sol";
import {Base, MockERC20} from "./Base.sol";

contract SwitchableWallet {
    bool public accept;

    function setAccept(bool a) external {
        accept = a;
    }

    receive() external payable {
        require(accept, "no ETH please");
    }
}

contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}

/// A wallet contract without receive/fallback (for example one that only handles tokens).
contract NoEthWallet {
    function withdraw(BurnRiseLaunchpad pad, address quote, address to) external {
        pad.withdrawPayout(quote, to);
    }
}

/// ETH pairs: launch, trading through the launchpad and through any other app, fees, burns, graduation.
contract BurnRiseTest is Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /* ------------------------------ launch ----------------------------- */

    function test_launch_putsTheWholeSupplyInALockedPool() public {
        address token = _launchEth(0);
        BurnRiseLaunchpad.TokenInfo memory t = _info(token);
        assertEq(t.creator, creator);
        assertEq(t.quote, address(0));
        assertEq(t.target, 4.2 ether);
        assertFalse(t.graduated);
        assertEq(pad.allTokens(0), token);
        assertEq(pad.tokenCount(), 1);

        assertEq(IERC20(token).totalSupply(), C.SUPPLY);
        assertEq(IERC20(token).balanceOf(address(pad)), 0, "launchpad keeps no tokens");
        uint256 dust = IERC20(token).balanceOf(DEAD);
        assertEq(IERC20(token).balanceOf(address(manager)) + dust, C.SUPPLY, "the rest is in the pool");
        assertLt(dust, 1e6, "only rounding dust");
        assertEq(address(manager).balance, 0, "opening the pool needs no ETH");

        // ETH sorts first, so the token is currency1 and its position sits below the launch price
        assertFalse(_tokenIs0(token));
        assertEq(t.tickLower, C.MIN_TICK);
        assertEq(_sqrtPrice(token), TickMath.getSqrtPriceAtTick(t.tickUpper));
        PoolId id = pad.poolKeyFor(token).toId();
        (uint128 liq,,) = IPoolManager(address(manager)).getPositionInfo(id, address(pad), t.tickLower, t.tickUpper, 0);
        assertEq(liq, t.liquidity, "the launchpad owns the position");
        assertEq(PoolId.unwrap(pad.poolIdFor(token)), PoolId.unwrap(id));

        // market cap at launch: about 1.68 ETH, 2/5 of the target (prices move in 2% tick steps)
        assertApproxEqRel(pad.spotPrice(token) * 1e9, 1.68 ether, 0.021e18);
        assertEq(pad.quotePaired(token), 0);
    }

    function test_launch_creatorFirstBuyGoesThroughThePool() public {
        assertEq(address(manager).balance, 0, "a fresh pool manager holds no ETH");
        vm.recordLogs();
        address token = _launchEth(1 ether);
        TradeEvent memory e = _tradeEvent();
        uint256 got = IERC20(token).balanceOf(creator);
        uint256 fee = C.feeOn(1 ether, 130);
        assertGt(got, C.SUPPLY / 10, "creator got a good share before anyone else");
        assertTrue(e.found && e.isBuy);
        assertEq(e.quoteAmount, 1 ether);
        assertEq(e.tokenAmount, got);
        assertEq(e.fee, fee);
        assertEq(pad.creatorFees(token), fee * 90 / 130);
        assertEq(platform.balance, fee * 30 / 130, "dev wallet paid right away");
        assertEq(contest.balance, fee - fee * 90 / 130 - fee * 30 / 130, "contest wallet paid right away");
        _assertSolvent(address(0));
    }

    function test_launch_rejectsBadInput() public {
        vm.startPrank(creator);
        vm.expectRevert(BurnRiseLaunchpad.BadName.selector);
        pad.launch("", "X", "", address(0), 0, 0);
        vm.expectRevert(BurnRiseLaunchpad.BadName.selector);
        pad.launch("A name that is far too long for a token", "X", "", address(0), 0, 0);
        vm.expectRevert(BurnRiseLaunchpad.BadName.selector);
        pad.launch("Cat", "TOOLONGTICKER", "", address(0), 0, 0);
        vm.expectRevert(BurnRiseLaunchpad.WrongValue.selector);
        pad.launch{value: 1}("Cat", "CAT", "", address(0), 0, 0);
        vm.expectRevert(BurnRiseLaunchpad.WrongValue.selector);
        pad.launch{value: 1 ether}("Cat", "CAT", "", address(0), 2 ether, 0);
        vm.expectRevert(BurnRiseLaunchpad.PairNotEnabled.selector);
        pad.launch("Cat", "CAT", "", address(0xBEEF), 0, 0);
        vm.expectRevert(BurnRiseLaunchpad.Slippage.selector);
        pad.launch{value: 1 ether}("Cat", "CAT", "", address(0), 1 ether, C.SUPPLY);
        vm.stopPrank();
    }

    function test_launch_pausedAndHookChecks() public {
        pad.setLaunchesPaused(true);
        vm.prank(creator);
        vm.expectRevert(BurnRiseLaunchpad.LaunchesArePaused.selector);
        pad.launch("Cat", "CAT", "", address(0), 0, 0);
        (address token,) = pad.launch("Owner Test", "OWN", "", address(0), 0, 0); // the owner can still test
        assertEq(_info(token).creator, address(this));

        BurnRiseLaunchpad fresh = new BurnRiseLaunchpad(manager, address(this), platform, contest);
        vm.expectRevert(BurnRiseLaunchpad.HookNotSet.selector);
        fresh.launch("Cat", "CAT", "", address(0), 0, 0);
    }

    /* ------------------------ trading via the launchpad ----------------- */

    function test_buy_feesBurnPreviewAndEvent() public {
        address token = _launchEth(0);
        uint256 dead0 = IERC20(token).balanceOf(DEAD);
        (uint256 pOut, uint256 pBurn, uint256 pFee, uint256 pUsed) = pad.previewBuy(token, 1 ether);
        vm.recordLogs();
        uint256 got = _buyEth(alice, token, 1 ether);
        TradeEvent memory e = _tradeEvent();

        uint256 fee = C.feeOn(1 ether, 130);
        uint256 burned = IERC20(token).balanceOf(DEAD) - dead0;
        assertEq(got, IERC20(token).balanceOf(alice));
        assertEq(burned, C.feeOn(got + burned, 50), "0.5% of the tokens burned");
        assertEq(pFee, fee);
        assertEq(pUsed, 1 ether);
        assertApproxEqAbs(got, pOut, 10, "preview");
        assertApproxEqAbs(burned, pBurn, 10, "preview burn");
        assertEq(pad.creatorFees(token), fee * 90 / 130, "0.9% to the creator");
        assertEq(platform.balance, fee * 30 / 130, "0.3% to the dev wallet");
        assertEq(contest.balance, fee - fee * 90 / 130 - fee * 30 / 130, "0.1% to the contest wallet");
        assertTrue(e.found && e.isBuy);
        assertEq(e.quoteAmount, 1 ether);
        assertEq(e.tokenAmount, got);
        assertEq(e.fee, fee);
        assertEq(e.burned, burned);
        assertApproxEqAbs(pad.quotePaired(token), 1 ether - fee, 10, "the ETH that bought the tokens is in the pool");
        _assertSolvent(address(0));
    }

    function test_sell_feesBurnAndPreview() public {
        address token = _launchEth(0);
        _buyEth(alice, token, 1 ether);
        uint256 amount = IERC20(token).balanceOf(alice) / 2;
        (uint256 pOut, uint256 pBurn, uint256 pFee) = pad.previewSell(token, amount);
        uint256 dead0 = IERC20(token).balanceOf(DEAD);
        uint256 eth0 = alice.balance;
        uint256 fees0 = _feesPaid(token);

        uint256 out = _sell(alice, token, amount);

        uint256 fee = _feesPaid(token) - fees0;
        assertEq(alice.balance - eth0, out);
        assertEq(IERC20(token).balanceOf(DEAD) - dead0, C.feeOn(amount, 50), "0.5% of the tokens burned");
        assertEq(pBurn, C.feeOn(amount, 50));
        assertEq(fee, C.feeOn(out + fee, 130), "1.3% of the ETH out");
        assertApproxEqAbs(out, pOut, 10, "preview");
        assertApproxEqAbs(fee, pFee, 10, "preview fee");
        _assertSolvent(address(0));
    }

    function test_trading_inputChecks() public {
        address token = _launchEth(0);
        vm.startPrank(alice);
        vm.expectRevert(BurnRiseLaunchpad.Expired.selector);
        pad.buy{value: 1 ether}(token, 1 ether, 0, block.timestamp - 1);
        vm.expectRevert(BurnRiseLaunchpad.WrongValue.selector);
        pad.buy{value: 1 ether}(token, 2 ether, 0, block.timestamp);
        vm.expectRevert(BurnRiseLaunchpad.ZeroAmount.selector);
        pad.buy(token, 0, 0, block.timestamp);
        vm.expectRevert(BurnRiseLaunchpad.UnknownToken.selector);
        pad.buy{value: 1 ether}(address(0xBEEF), 1 ether, 0, block.timestamp);
        (uint256 out,,,) = pad.previewBuy(token, 1 ether);
        vm.expectRevert(BurnRiseLaunchpad.Slippage.selector);
        pad.buy{value: 1 ether}(token, 1 ether, out + 1000, block.timestamp);
        uint256 got = pad.buy{value: 1 ether}(token, 1 ether, out - 1000, block.timestamp);

        IERC20(token).approve(address(pad), type(uint256).max);
        vm.expectRevert(BurnRiseLaunchpad.Expired.selector);
        pad.sell(token, got, 0, block.timestamp - 1);
        vm.expectRevert(BurnRiseLaunchpad.ZeroAmount.selector);
        pad.sell(token, 0, 0, block.timestamp);
        (uint256 q,,) = pad.previewSell(token, got);
        vm.expectRevert(BurnRiseLaunchpad.Slippage.selector);
        pad.sell(token, got, q + 1000, block.timestamp);
        pad.sell(token, got, q - 1000, block.timestamp);
        vm.stopPrank();
    }

    /* ------------------------- trading from other apps ------------------ */

    function test_anyApp_everyTradeModePaysTheSameFees() public {
        address token = _launchEth(0);
        _buyEth(bob, token, 2 ether);
        _allModes(token, 0.5 ether);
    }

    function test_anyApp_aBigFirstBuyOnAFreshPool() public {
        address token = _launchEth(0);
        _fundRouterTrader(alice, token);
        assertEq(address(manager).balance, 0, "nothing in the pool manager yet");
        _swap(alice, pad.poolKeyFor(token), _dir(token, true), -50 ether, 50 ether);
        assertGt(IERC20(token).balanceOf(alice), C.SUPPLY / 2);
        assertTrue(_graduated(token));
        _assertSolvent(address(0));
    }

    /* ------------------------------ fees -------------------------------- */

    function test_fees_reachTheWalletsAfterEveryLaunchpadTrade() public {
        address token = _launchEth(0);
        uint256 fee = C.feeOn(1 ether, 130);
        uint256 toPlatform = fee * 30 / 130;
        uint256 toContest = fee - fee * 90 / 130 - toPlatform;

        _buyEth(alice, token, 1 ether);
        assertEq(platform.balance, toPlatform);
        assertEq(contest.balance, toContest);
        assertEq(pad.pendingPayouts(platform, address(0)), 0);

        // a trade made in another app: its fees wait, then go out with the next launchpad trade
        _swap(bob, pad.poolKeyFor(token), _dir(token, true), -1 ether, 1 ether);
        assertEq(platform.balance, toPlatform);
        assertEq(pad.pendingPayouts(platform, address(0)), toPlatform);
        assertEq(pad.pendingPayouts(contest, address(0)), toContest);
        _assertSolvent(address(0));
        _buyEth(carol, token, 1 ether);
        assertEq(platform.balance, 3 * toPlatform);
        assertEq(contest.balance, 3 * toContest);

        // ... or anyone can send them out
        _swap(bob, pad.poolKeyFor(token), _dir(token, true), -1 ether, 1 ether);
        vm.prank(alice);
        pad.payOutFees(address(0));
        assertEq(platform.balance, 4 * toPlatform);
        assertEq(contest.balance, 4 * toContest);
        assertEq(pad.pendingPayouts(platform, address(0)), 0);
        _assertSolvent(address(0));
    }

    function test_creatorClaims_feesFromEveryApp() public {
        address token = _launchEth(1 ether);
        _buyEth(alice, token, 2 ether);
        _sell(alice, token, IERC20(token).balanceOf(alice) / 2);
        _swap(bob, pad.poolKeyFor(token), _dir(token, true), -1 ether, 1 ether);
        uint256 owed = pad.creatorFees(token);
        assertGt(owed, C.feeOn(4 ether, 90), "0.9% of all buys, plus the sell");

        vm.prank(alice);
        vm.expectRevert(BurnRiseLaunchpad.NotCreator.selector);
        pad.claimCreatorFees(token);

        uint256 b0 = creator.balance;
        vm.prank(creator);
        assertEq(pad.claimCreatorFees(token), owed);
        assertEq(creator.balance - b0, owed);
        assertEq(pad.creatorFees(token), 0);
        vm.prank(creator);
        vm.expectRevert(BurnRiseLaunchpad.NothingToWithdraw.selector);
        pad.claimCreatorFees(token);
        _assertSolvent(address(0));
    }

    function test_creatorClaimsMany_andHandsOverTheRights() public {
        address a = _launchEth(1 ether);
        address b = _launchEth(0.5 ether);
        address c = _launchEth(0);
        uint256 owed = pad.creatorFees(a) + pad.creatorFees(b);
        address[] memory list = new address[](3);
        (list[0], list[1], list[2]) = (a, b, c);
        uint256 b0 = creator.balance;
        vm.prank(creator);
        pad.claimCreatorFeesMany(list); // c owes nothing and is skipped
        assertEq(creator.balance - b0, owed);

        address safe = makeAddr("safe");
        vm.prank(alice);
        vm.expectRevert(BurnRiseLaunchpad.NotCreator.selector);
        pad.setCreator(a, alice);
        vm.prank(creator);
        pad.setCreator(a, safe);
        _buyEth(alice, a, 1 ether);
        vm.prank(creator);
        vm.expectRevert(BurnRiseLaunchpad.NotCreator.selector);
        pad.claimCreatorFees(a);
        vm.prank(safe);
        assertEq(pad.claimCreatorFees(a), C.feeOn(1 ether, 130) * 90 / 130);
        _assertSolvent(address(0));
    }

    function test_walletThatRejectsEth_neverBlocksTrading() public {
        SwitchableWallet w = new SwitchableWallet();
        pad.setPlatformWallet(address(w));
        address token = _launchEth(1 ether);
        _buyEth(alice, token, 1 ether);
        _sell(alice, token, IERC20(token).balanceOf(alice) / 2);
        uint256 owedW = pad.pendingPayouts(address(w), address(0));
        assertGt(owedW, 0);
        assertEq(address(w).balance, 0);
        _assertSolvent(address(0));

        // once it accepts ETH, the next trade pays it everything
        w.setAccept(true);
        _buyEth(bob, token, 0.1 ether);
        assertEq(pad.pendingPayouts(address(w), address(0)), 0);
        assertEq(address(w).balance, owedW + C.feeOn(0.1 ether, 130) * 30 / 130);
        _assertSolvent(address(0));
    }

    function test_walletThatBurnsGas_neverBlocksTrading() public {
        GasBurner g = new GasBurner();
        pad.setContestWallet(address(g));
        address token = _launchEth(1 ether);
        _buyEth(alice, token, 1 ether);
        _sell(alice, token, IERC20(token).balanceOf(alice));
        assertGt(pad.pendingPayouts(address(g), address(0)), 0);
        _assertSolvent(address(0));
    }

    function test_walletWithoutReceive_withdrawsToAnotherAddress() public {
        NoEthWallet w = new NoEthWallet();
        pad.setContestWallet(address(w));
        _launchEth(1 ether);
        uint256 owedW = pad.pendingPayouts(address(w), address(0));
        assertGt(owedW, 0);
        address to = makeAddr("collector");
        w.withdraw(pad, address(0), to);
        assertEq(to.balance, owedW);
        assertEq(pad.pendingPayouts(address(w), address(0)), 0);
        vm.expectRevert(BurnRiseLaunchpad.NothingToWithdraw.selector);
        w.withdraw(pad, address(0), to);
        _assertSolvent(address(0));
    }

    /* ----------------------------- burns -------------------------------- */

    function test_burnsGoToTheDeadAddress_andTheSupplyNeverChanges() public {
        address token = _launchEth(0);
        IERC20 t = IERC20(token);
        uint256 dead = t.balanceOf(DEAD); // launch dust

        (, uint256 buyBurn,,) = pad.previewBuy(token, 1 ether);
        _buyEth(alice, token, 1 ether);
        assertApproxEqAbs(t.balanceOf(DEAD) - dead, buyBurn, 10, "launchpad buy");
        dead = t.balanceOf(DEAD);

        uint256 sellAmt = t.balanceOf(alice) / 2;
        _sell(alice, token, sellAmt);
        assertEq(t.balanceOf(DEAD) - dead, C.feeOn(sellAmt, 50), "launchpad sell");
        dead = t.balanceOf(DEAD);

        PoolKey memory key = pad.poolKeyFor(token);
        _fundRouterTrader(alice, token);
        _swap(alice, key, _dir(token, true), -1 ether, 1 ether);
        assertGt(t.balanceOf(DEAD), dead, "other app buy");
        dead = t.balanceOf(DEAD);
        uint256 poolSell = t.balanceOf(alice) / 2;
        _swap(alice, key, _dir(token, false), -int256(poolSell), 0);
        assertEq(t.balanceOf(DEAD) - dead, C.feeOn(poolSell, 50), "other app sell");

        assertEq(t.totalSupply(), C.SUPPLY, "the supply never changes");
        assertEq(t.balanceOf(address(hook)), 0, "the hook keeps nothing");
        assertEq(t.balanceOf(address(pad)), 0, "the launchpad keeps nothing");
    }

    /* --------------------------- graduation ----------------------------- */

    function test_graduation_atTheTarget_andTradingGoesOnInTheSamePool() public {
        address token = _launchEth(0);
        PoolId id = pad.poolKeyFor(token).toId();
        uint256 launchPrice = pad.spotPrice(token);
        while (!_graduated(token)) {
            assertLt(pad.quotePaired(token), 4.2 ether + 1e6, "not graduated below the target");
            _buyEth(bob, token, 0.25 ether);
        }
        uint256 paired = pad.quotePaired(token);
        assertGe(paired, 4.2 ether, "graduated once the target is in the pool");
        assertLt(paired, 4.2 ether + 0.25 ether, "on the buy that crossed it");
        // about 5/7 of the supply has been bought and the price is about 12.25x the launch price
        uint256 bought = C.SUPPLY - IERC20(token).balanceOf(address(manager));
        assertApproxEqRel(bought, C.SUPPLY * 5 / 7, 0.03e18);
        assertApproxEqRel(pad.spotPrice(token) * 1e18 / launchPrice, 12.25e18, 0.1e18);

        // same pool, trading goes on; selling back below the target keeps the token graduated
        _sell(bob, token, IERC20(token).balanceOf(bob));
        assertLt(pad.quotePaired(token), 4.2 ether);
        assertTrue(_graduated(token));
        _buyEth(alice, token, 0.5 ether);
        assertEq(PoolId.unwrap(pad.poolKeyFor(token).toId()), PoolId.unwrap(id));
        _assertSolvent(address(0));
    }

    function test_graduation_thresholdIsExact() public {
        address token = _launchEth(0);
        // a buy that leaves the pool just short of 4.2 ETH doesn't graduate...
        uint256 net = 4.2 ether - 1e12;
        uint256 justShort = net * 10_000 / 9_870;
        _buyEth(alice, token, justShort);
        assertLt(pad.quotePaired(token), 4.2 ether);
        assertFalse(_graduated(token));
        // ... the next one that reaches it does
        _buyEth(alice, token, 1e13);
        assertGe(pad.quotePaired(token), 4.2 ether);
        assertTrue(_graduated(token));
    }

    function test_graduation_fromAnyApp_andOnlyOnce() public {
        address token = _launchEth(0);
        PoolKey memory key = pad.poolKeyFor(token);
        _fundRouterTrader(alice, token);
        vm.recordLogs();
        _swap(alice, key, _dir(token, true), -6 ether, 6 ether);
        assertTrue(_graduated(token));
        _swap(alice, key, _dir(token, true), -1 ether, 1 ether);
        _buyEth(bob, token, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == BurnRiseLaunchpad.Graduated.selector) ++count;
        }
        assertEq(count, 1, "one Graduated event");
    }

    /* ------------------------- locked liquidity ------------------------- */

    function test_liquidityIsLocked_andOnlyTheLaunchpadMakesPools() public {
        address token = _launchEth(0);
        PoolKey memory key = pad.poolKeyFor(token);
        BurnRiseLaunchpad.TokenInfo memory t = _info(token);

        // someone with tokens, ETH and approvals still can't add liquidity: only the hook's check stops them
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        _buyEth(alice, token, 1 ether);
        vm.startPrank(alice);
        IERC20(token).approve(address(lp), type(uint256).max);
        vm.expectRevert(_hookError(IHooks.beforeAddLiquidity.selector, BurnRiseHook.NotLaunchpad.selector));
        lp.modifyLiquidity{value: 0.1 ether}(
            key, IPoolManager.ModifyLiquidityParams({tickLower: -887200, tickUpper: 887200, liquidityDelta: 1e15, salt: 0}), ""
        );
        vm.stopPrank();

        // and nobody else can create a pool with the hook
        MockERC20 other = new MockERC20(18);
        PoolKey memory fake = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(other)), 0, 200, IHooks(address(hook)));
        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, BurnRiseHook.NotLaunchpad.selector));
        manager.initialize(fake, TickMath.getSqrtPriceAtTick(0));

        _buyEth(alice, token, 3 ether);
        _sell(alice, token, IERC20(token).balanceOf(alice));
        _assertSolvent(address(0));
        (uint128 liq,,) =
            IPoolManager(address(manager)).getPositionInfo(key.toId(), address(pad), t.tickLower, t.tickUpper, 0);
        assertEq(liq, t.liquidity, "the locked position never changes");
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), t.liquidity, "and it is all the liquidity");
    }

    function test_everyoneCanSellEverythingBack_andThePriceStaysAboveLaunch() public {
        address token = _launchEth(0.5 ether);
        uint160 launchSqrt = TickMath.getSqrtPriceAtTick(_info(token).tickUpper);
        address[3] memory people = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) _buyEth(people[i], token, (i + 1) * 0.7 ether);

        _sell(creator, token, IERC20(token).balanceOf(creator));
        for (uint256 i; i < 3; ++i) _sell(people[i], token, IERC20(token).balanceOf(people[i]));

        // the burned tokens never come back, so the pool keeps some ETH and the price stays above launch
        // (the token is currency1: a lower pool price means a dearer token)
        assertLt(_sqrtPrice(token), launchSqrt);
        assertGt(pad.quotePaired(token), 0);
        assertEq(IERC20(token).balanceOf(address(manager)) + IERC20(token).balanceOf(DEAD), C.SUPPLY);
        _assertSolvent(address(0));
    }

    function _hookError(bytes4 hookFn, bytes4 err) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookFn,
            abi.encodeWithSelector(err),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /* ------------------------------ access ------------------------------ */

    function test_access_ownerOnly() public {
        vm.startPrank(alice);
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(notOwner);
        pad.setPair(address(0), true, 1 ether);
        vm.expectRevert(notOwner);
        pad.setPlatformWallet(alice);
        vm.expectRevert(notOwner);
        pad.setContestWallet(alice);
        vm.expectRevert(notOwner);
        pad.setLaunchesPaused(true);
        vm.expectRevert(notOwner);
        pad.deployHook(bytes32(0));
        vm.stopPrank();

        vm.expectRevert(BurnRiseLaunchpad.HookAlreadySet.selector);
        pad.deployHook(bytes32(0));
        vm.expectRevert(BurnRiseLaunchpad.BadTarget.selector);
        pad.setPair(address(0), true, 1);
        vm.expectRevert(BurnRiseLaunchpad.NotAContract.selector);
        pad.setPair(address(0xBEEF), true, 1e18);
        vm.expectRevert(BurnRiseLaunchpad.ZeroAddress.selector);
        pad.setPlatformWallet(address(0));
        vm.expectRevert(BurnRiseLaunchpad.ZeroAddress.selector);
        pad.setContestWallet(address(0));
    }

    function test_access_callbacks() public {
        address token = _launchEth(0);
        vm.expectRevert(BurnRiseLaunchpad.NotHook.selector);
        pad.collectPoolFee(token, 1);
        vm.expectRevert(BurnRiseLaunchpad.NotHook.selector);
        pad.onGraduated(token);
        vm.expectRevert(BurnRiseLaunchpad.NotPoolManager.selector);
        pad.unlockCallback("");
        (bool ok,) = address(pad).call{value: 1}("");
        assertFalse(ok, "only the pool manager sends ETH");
        (address launching, uint160 g) = pad.launching();
        assertEq(launching, address(0));
        assertEq(g, 0);

        PoolKey memory key = pad.poolKeyFor(token);
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams(true, -1, MIN_LIMIT);
        vm.expectRevert(BurnRiseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, sp, "");
        vm.expectRevert(BurnRiseHook.NotPoolManager.selector);
        hook.beforeInitialize(address(pad), key, 1 << 96);
        vm.expectRevert(BurnRiseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(pad), key, IPoolManager.ModifyLiquidityParams(0, 200, 1, 0), "");
        vm.expectRevert(BurnRiseHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
    }

    /* ------------------------------- fuzz ------------------------------- */

    /// Random trade sizes and directions through the launchpad: previews match the trades and the fees
    /// and burns are exact every time.
    function testFuzz_launchpadTrades(uint256 seed) public {
        address token = _launchEth(0);
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 bal = IERC20(token).balanceOf(alice);
            if (seed % 3 != 0 || bal < 1e18) {
                uint256 amt = 1e9 + (seed >> 8) % 8 ether;
                (uint256 pOut,,,) = pad.previewBuy(token, amt);
                uint256 f0 = _feesPaid(token);
                uint256 got = _buyEth(alice, token, amt);
                assertApproxEqRel(got, pOut, 1e6, "buy preview"); // rounding: under 1e-12 of the amount
                assertEq(_feesPaid(token) - f0, C.feeOn(amt, 130), "buy fee");
            } else {
                uint256 amt = 1 + (seed >> 8) % bal;
                (uint256 pOut,,) = pad.previewSell(token, amt);
                uint256 d0 = IERC20(token).balanceOf(DEAD);
                uint256 out = _sell(alice, token, amt);
                assertApproxEqRel(out, pOut, 1e6, "sell preview");
                assertEq(IERC20(token).balanceOf(DEAD) - d0, C.feeOn(amt, 50), "sell burn");
            }
        }
        _assertSolvent(address(0));
    }

    /// Random modes and sizes from another app: exact fees and burns every time.
    function testFuzz_otherAppTrades(uint256 seed) public {
        address token = _launchEth(0);
        _buyEth(bob, token, 3 ether);
        _fundRouterTrader(alice, token);
        _swap(alice, pad.poolKeyFor(token), _dir(token, true), -2 ether, 2 ether);
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 mode = seed % 4;
            if (mode == 0) _modeExactInBuy(token, 1e6 + (seed >> 8) % 3 ether);
            else if (mode == 1) _modeExactOutBuy(token, 1 ether);
            else if (mode == 2 && IERC20(token).balanceOf(alice) > 1e18) _modeExactInSell(token);
            else if (mode == 3 && IERC20(token).balanceOf(alice) > 1e18) {
                (uint256 reachable,,) = pad.previewSell(token, IERC20(token).balanceOf(alice) / 2);
                _modeExactOutSell(token, 1 + (seed >> 8) % reachable); // no more than half of alice's tokens buy
            }
        }
        _assertSolvent(address(0));
    }
}
