// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BurnRiseConfig as C} from "../src/BurnRiseConfig.sol";
import {BurnRiseTestRouter, IBurnRisePoolKeys} from "../test-helpers/BurnRiseTestRouter.sol";
import {Base, MockERC20} from "./Base.sol";

/// The optional testnet router: a separate app trading BurnRise pools, like DexScreener or an aggregator.
contract TestRouterTest is Base {
    BurnRiseTestRouter tr;

    function setUp() public override {
        super.setUp();
        tr = new BurnRiseTestRouter(IPoolManager(address(manager)), IBurnRisePoolKeys(address(pad)));
    }

    function test_testRouter_eth() public {
        address token = _launchEth(0);
        vm.startPrank(alice);
        uint256 got = tr.buy{value: 0.5 ether}(token, 0.5 ether, 0);
        assertEq(IERC20(token).balanceOf(alice), got);
        IERC20(token).approve(address(tr), got);
        uint256 eth0 = alice.balance;
        uint256 out = tr.sell(token, got / 2, 0);
        assertEq(alice.balance - eth0, out);
        vm.expectRevert(bytes("send exactly amountIn as value for ETH, nothing otherwise"));
        tr.buy{value: 1}(token, 2, 0);
        vm.stopPrank();

        // fees from another app wait for the next launchpad trade, or for payOutFees
        uint256 owedPlatform = pad.pendingPayouts(platform, address(0));
        assertEq(owedPlatform, C.feeOn(0.5 ether, 130) * 30 / 130 + _platformShareOfSell(token));
        pad.payOutFees(address(0));
        assertEq(platform.balance, owedPlatform);
        _assertSolvent(address(0));
    }

    function test_testRouter_erc20() public {
        MockERC20 usd = _mockQuoteAt(LOW_ADDR, 6);
        pad.setPair(address(usd), true, 9_000e6);
        address token = _launchErc20(usd, 0);
        usd.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usd.approve(address(tr), type(uint256).max);
        IERC20(token).approve(address(tr), type(uint256).max);
        uint256 got = tr.buy(token, 500e6, 0);
        assertGt(tr.sell(token, got / 2, 0), 0);
        vm.stopPrank();
        pad.payOutFees(address(usd));
        assertGt(usd.balanceOf(platform), 0);
        _assertSolvent(address(usd));
    }

    /// The platform's share of the sell's fee, from what's owed in total minus the buy's share.
    function _platformShareOfSell(address token) internal view returns (uint256) {
        uint256 totalFees = pad.creatorFees(token) + pad.pendingPayouts(platform, address(0))
            + pad.pendingPayouts(contest, address(0));
        uint256 sellFee = totalFees - C.feeOn(0.5 ether, 130);
        return sellFee * 30 / 130;
    }
}
