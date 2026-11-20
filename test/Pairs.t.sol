// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BurnRiseLaunchpad} from "../src/BurnRiseLaunchpad.sol";
import {BurnRiseConfig as C} from "../src/BurnRiseConfig.sol";
import {Base, MockERC20} from "./Base.sol";

/// A pair token that keeps 1% of every transfer (not supported).
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Taxed", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 cut = value / 100;
            super._update(from, address(0xdead), cut);
            value -= cut;
        }
        super._update(from, to, value);
    }
}

/// ERC-20 pairs (USDG-style 6 decimals, stock tokens with 18), with the pair asset sorting below or above
/// the token in the pool, and the smallest and very large graduation targets.
contract PairsTest is Base {
    function _pair(address at, uint8 dec, uint128 target) internal returns (MockERC20 q) {
        q = _mockQuoteAt(at, dec);
        pad.setPair(address(q), true, target);
    }

    /// Launch, first buy, launchpad trades, every mode from another app, graduation, everyone exits.
    function _flow(address at, uint8 dec, uint128 target) internal {
        MockERC20 q = _pair(at, dec, target);

        // a launch without a first buy opens at a market cap of 2/5 of the target
        address plain = _launchErc20(q, 0);
        assertEq(_tokenIs0(plain), at == HIGH_ADDR, "currency order");
        BurnRiseLaunchpad.TokenInfo memory t = _info(plain);
        if (_tokenIs0(plain)) assertEq(t.tickUpper, C.MAX_TICK);
        else assertEq(t.tickLower, C.MIN_TICK);
        assertApproxEqRel(_marketCap(plain), uint256(target) * 2 / 5, 0.021e18, "launch market cap");
        assertLt(IERC20(plain).balanceOf(DEAD), 1e12, "only rounding dust");

        // the creator's first buy, then buys and sells through the launchpad
        address token = _launchErc20(q, target / 10);
        uint256 fee = C.feeOn(target / 10, 130);
        assertEq(pad.creatorFees(token), fee * 90 / 130, "0.9% to the creator");
        assertEq(q.balanceOf(platform), fee * 30 / 130, "0.3% to the dev wallet");
        assertEq(q.balanceOf(contest), fee - fee * 90 / 130 - fee * 30 / 130, "0.1% to the contest wallet");
        uint256 got = _buyErc20(alice, q, token, target / 8);
        (uint256 pOut,,) = pad.previewSell(token, got / 2);
        uint256 out = _sell(alice, token, got / 2);
        assertApproxEqAbs(out, pOut, 10, "sell preview");
        _assertSolvent(address(q));

        // every trade mode from another app
        _allModes(token, target / 20);

        // graduation once the target is in the pool
        while (!_graduated(token)) {
            assertLt(pad.quotePaired(token), uint256(target) + uint256(target) / 1e6 + 10, "below the target");
            _buyErc20(bob, q, token, target / 4);
        }
        assertGe(pad.quotePaired(token), target, "graduated at the target");

        // everyone sells everything back: it all works and the launchpad still holds what it owes
        _sell(creator, token, IERC20(token).balanceOf(creator));
        _sell(alice, token, IERC20(token).balanceOf(alice));
        _sell(bob, token, IERC20(token).balanceOf(bob));
        assertEq(IERC20(token).balanceOf(address(manager)) + IERC20(token).balanceOf(DEAD), C.SUPPLY, "all back in the pool or burned");
        assertTrue(_graduated(token), "stays graduated");
        _assertSolvent(address(q));

        // creator fees in the pair asset
        uint256 owed = pad.creatorFees(token);
        uint256 b0 = q.balanceOf(creator);
        vm.prank(creator);
        pad.claimCreatorFees(token);
        assertEq(q.balanceOf(creator) - b0, owed);
        _assertSolvent(address(q));
    }

    function test_usdgPair_quoteIsCurrency0() public {
        _flow(LOW_ADDR, 6, 9_000e6);
    }

    function test_usdgPair_quoteIsCurrency1() public {
        _flow(HIGH_ADDR, 6, 9_000e6);
    }

    function test_stockPair_quoteIsCurrency0() public {
        _flow(LOW_ADDR, 18, 48e18);
    }

    function test_stockPair_quoteIsCurrency1() public {
        _flow(HIGH_ADDR, 18, 48e18);
    }

    function test_smallestTarget_quoteIsCurrency0() public {
        _flow(LOW_ADDR, 6, 1e6); // 1 USDG
    }

    function test_smallestTarget_quoteIsCurrency1() public {
        _flow(HIGH_ADDR, 6, 1e6);
    }

    function test_hugeTarget_bothOrders() public {
        _flow(LOW_ADDR, 18, 1e33);
        _flow(HIGH_ADDR, 18, 1e33);
    }

    function test_tinyEthTarget() public {
        pad.setPair(address(0), true, 0.01 ether);
        address token = _launchEth(0.001 ether);
        _buyEth(alice, token, 0.002 ether);
        _sell(alice, token, IERC20(token).balanceOf(alice) / 10);
        _buyEth(bob, token, 0.01 ether);
        assertTrue(_graduated(token));
        assertGe(pad.quotePaired(token), 0.01 ether);
        _assertSolvent(address(0));
    }

    function test_feeOnTransferPairToken_cannotTrade() public {
        FeeOnTransferToken f = new FeeOnTransferToken();
        pad.setPair(address(f), true, 1_000e18);
        f.mint(creator, 100e18);
        vm.startPrank(creator);
        f.approve(address(pad), type(uint256).max);
        vm.expectRevert();
        pad.launch("Tax", "TAX", "", address(f), 10e18, 0);
        (address token,) = pad.launch("Tax", "TAX", "", address(f), 0, 0); // a launch without a buy works
        vm.expectRevert();
        pad.buy(token, 10e18, 0, block.timestamp);
        vm.stopPrank();
    }
}
