// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BurnRiseLaunchpad} from "../src/BurnRiseLaunchpad.sol";
import {BurnRiseHook} from "../src/BurnRiseHook.sol";
import {BurnRiseConfig as C} from "../src/BurnRiseConfig.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Base, MockERC20} from "./Base.sol";

/// A platform or contest wallet that accepts ETH but calls PoolManager.sync(<an ERC-20>) while being paid.
contract SyncingWallet {
    IPoolManager public immutable pm;
    Currency public immutable c;

    constructor(IPoolManager pm_, Currency c_) {
        pm = pm_;
        c = c_;
    }

    receive() external payable {
        pm.sync(c);
    }
}

/// A wallet contract without receive/fallback.
contract NoEthWallet {}

/// A router that does what Uniswap's own router does: sync() before paying in, ETH included.
contract SyncingRouter is IUnlockCallback {
    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params) external payable {
        pm.unlock(abi.encode(msg.sender, key, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address user, PoolKey memory key, IPoolManager.SwapParams memory params) =
            abi.decode(data, (address, PoolKey, IPoolManager.SwapParams));
        BalanceDelta d = pm.swap(key, params, "");
        _resolve(key.currency0, d.amount0(), user);
        _resolve(key.currency1, d.amount1(), user);
        return "";
    }

    function _resolve(Currency c, int128 amount, address user) private {
        if (amount > 0) {
            pm.take(c, user, uint128(amount));
        } else if (amount < 0) {
            pm.sync(c);
            if (Currency.unwrap(c) == address(0)) {
                pm.settle{value: uint128(-amount)}();
            } else {
                IERC20(Currency.unwrap(c)).transferFrom(user, address(pm), uint128(-amount));
                pm.settle();
            }
        }
    }

    receive() external payable {}
}

/// An aggregator or zap that launches and buys from inside its own PoolManager unlock.
contract Zap is IUnlockCallback {
    IPoolManager public immutable pm;
    BurnRiseLaunchpad public immutable pad;
    address public token;

    constructor(IPoolManager pm_, BurnRiseLaunchpad pad_) {
        pm = pm_;
        pad = pad_;
    }

    function launch() external payable {
        pm.unlock(abi.encode(true, msg.value));
    }

    function buy() external payable {
        pm.unlock(abi.encode(false, msg.value));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool isLaunch, uint256 value) = abi.decode(data, (bool, uint256));
        if (isLaunch) (token,) = pad.launch{value: value}("Zapped", "ZAP", "", address(0), value, 0);
        else pad.buy{value: value}(token, value, 0, block.timestamp);
        return "";
    }

    receive() external payable {}
}

contract ReviewTest is Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// A wallet that calls sync() while being paid can't block anything: wallets are only paid inside the
    /// launchpad's own trades, after the trader has paid in, so trades from other apps never pay them.
    function test_syncingWallet_cannotBlockTrading() public {
        MockERC20 usd = new MockERC20(6);
        SyncingWallet w = new SyncingWallet(manager, Currency.wrap(address(usd)));
        pad.setPlatformWallet(address(w));
        address token = _launchEth(1 ether);
        _buyEth(alice, token, 1 ether);
        _sell(alice, token, IERC20(token).balanceOf(alice) / 2);
        assertGt(address(w).balance, 0, "the wallet got its fees");

        PoolKey memory key = pad.poolKeyFor(token);
        _newTx(); // the wallet's sync only lasts until the end of its own transaction
        _swap(bob, key, _dir(token, true), -1 ether, 1 ether); // settles ETH without syncing first
        SyncingRouter r = new SyncingRouter(manager);
        vm.prank(carol);
        r.swap{value: 1 ether}(key, IPoolManager.SwapParams(_dir(token, true), -1 ether, MIN_LIMIT));
        _buyEth(carol, token, 1 ether);
        assertEq(pad.pendingPayouts(address(w), address(0)), 0);
        _assertSolvent(address(0));
    }

    /// Launching and buying work from inside another contract's PoolManager unlock.
    function test_launchAndBuyFromInsideAnotherUnlock() public {
        Zap z = new Zap(manager, pad);
        vm.deal(address(z), 0);
        z.launch{value: 1 ether}();
        address token = z.token();
        uint256 first = IERC20(token).balanceOf(address(z));
        assertGt(first, 0);
        z.buy{value: 1 ether}();
        assertGt(IERC20(token).balanceOf(address(z)), first);
        assertEq(platform.balance, 2 * (C.feeOn(1 ether, 130) * 30 / 130), "fees paid out inside the outer unlock");
        _assertSolvent(address(0));
    }

    function _partialFillError() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(BurnRiseHook.PartialFill.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// A swap that a price limit would stop part of the way reverts instead of paying fees on what didn't trade.
    function test_partialFillsRevert() public {
        address token = _launchEth(0);
        _buyEth(bob, token, 3 ether);
        PoolKey memory key = pad.poolKeyFor(token);
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint160 limit = uint160(uint256(sqrtP) * 995 / 1000); // a buy (zeroForOne) may move the price ~1% at most
        vm.prank(alice);
        vm.expectRevert(_partialFillError());
        router.swap{value: 10 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.prank(alice);
        vm.expectRevert(_partialFillError());
        router.swap{value: 10 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: int256(C.SUPPLY / 4), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // a swap that fits inside the same limit fills completely and pays the normal fee
        uint256 f0 = _feesPaid(token);
        vm.prank(alice);
        router.swap{value: 0.01 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(_feesPaid(token) - f0, C.feeOn(0.01 ether, 130));
    }

    function test_firstBuyCanTakeAlmostTheWholeSupply() public {
        vm.prank(creator);
        (address token, uint256 got) = pad.launch{value: 100 ether}("Fast", "FAST", "", address(0), 100 ether, 0);
        assertTrue(_graduated(token));
        assertGt(got, C.SUPPLY * 95 / 100);
        _sell(creator, token, got);
        _assertSolvent(address(0));
    }

    /// Rehearsal of script/Deploy.s.sol on a simulated chain 4663 (a real PoolManager at the hard-coded
    /// address, mock USDG/NVDA): salt search, hook deploy, pairs, pause and 2-step ownership all work.
    function test_deployScriptRehearsal() public {
        vm.chainId(4663);
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        _mockQuoteAt(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 6);
        _mockQuoteAt(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 18);
        address safe = makeAddr("safe");
        vm.setEnv("PLATFORM_WALLET", vm.toString(platform));
        vm.setEnv("FINAL_OWNER", vm.toString(safe));
        Deploy d = new Deploy();
        BurnRiseLaunchpad p = d.run();
        assertEq(uint160(address(p.hook())) & ((1 << 14) - 1), p.HOOK_FLAGS(), "hook flags");
        assertTrue(p.launchesPaused());
        assertEq(p.pendingOwner(), safe);
        (bool en, uint128 target) = p.pairs(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
        assertTrue(en);
        assertEq(target, 9_000e6);
        vm.prank(safe);
        p.acceptOwnership();
        assertEq(p.owner(), safe);
    }

    /// Two ETH tokens, a 6-decimal and an 18-decimal pair, traded in random order and sizes through the
    /// launchpad and another app, with a contest wallet that can't take ETH and creators claiming along the
    /// way; then everyone sells everything. Every sell works, every token's supply is fully accounted for,
    /// and the launchpad always holds exactly what it owes in each pair asset.
    function testFuzz_solvencyAcrossTokensAndPairs(uint256 seed) public {
        NoEthWallet cw = new NoEthWallet();
        pad.setContestWallet(address(cw));
        MockERC20 usd = _mockQuoteAt(LOW_ADDR, 6);
        MockERC20 stock = _mockQuoteAt(HIGH_ADDR, 18);
        pad.setPair(address(usd), true, 9_000e6);
        pad.setPair(address(stock), true, 48e18);

        address[4] memory toks;
        toks[0] = _launchEth(0);
        toks[1] = _launchEth(0.2 ether);
        toks[2] = _launchErc20(usd, 500e6);
        toks[3] = _launchErc20(stock, 0);
        address[3] memory people = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            for (uint256 k; k < 4; ++k) _fundRouterTrader(people[i], toks[k]);
        }

        for (uint256 i; i < 40; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _randomAction(toks[seed % 4], people[(seed >> 8) % 3], seed >> 16);
        }

        for (uint256 k; k < 4; ++k) {
            _sellAll(creator, toks[k]);
            for (uint256 i; i < 3; ++i) _sellAll(people[i], toks[k]);
            assertEq(
                IERC20(toks[k]).balanceOf(address(manager)) + IERC20(toks[k]).balanceOf(DEAD), C.SUPPLY, "supply accounted"
            );
        }
        _assertSolvent(address(0));
        _assertSolvent(address(usd));
        _assertSolvent(address(stock));
    }

    function _sellAll(address who, address token) internal {
        uint256 bal = IERC20(token).balanceOf(who);
        if (bal > 0) _sell(who, token, bal);
    }

    function _randomAction(address token, address who, uint256 r) internal {
        address q = _quote(token);
        uint256 unit = q == address(0) ? 1 ether : q == LOW_ADDR ? 2_000e6 : 20e18;
        uint256 amt = 1 + r % (unit * (1 + (r >> 200) % 3));
        uint256 bal = IERC20(token).balanceOf(who);
        uint256 kind = (r >> 100) % 6;
        if (kind == 0) {
            _buy(who, token, amt);
        } else if (kind == 1 && bal > 0) {
            _sell(who, token, 1 + (r >> 50) % bal);
        } else if (kind == 2) {
            _swap(who, pad.poolKeyFor(token), _dir(token, true), -int256(amt), q == address(0) ? amt : 0);
        } else if (kind == 3 && bal > 0) {
            _swap(who, pad.poolKeyFor(token), _dir(token, false), -int256(1 + (r >> 50) % bal), 0);
        } else if (kind == 4 && pad.creatorFees(token) > 0) {
            vm.prank(creator);
            pad.claimCreatorFees(token);
        } else {
            pad.payOutFees(q);
        }
    }
}
