// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.sol";
import {BurnRiseTokenInfo} from "../src/BurnRiseTokenInfo.sol";

/// Token info updates, against the real launchpad: only the creator on record can update.
contract TokenInfoTest is Base {
    BurnRiseTokenInfo info;
    address token;

    event TokenInfoSet(address indexed token, address indexed creator, string info);

    function setUp() public override {
        super.setUp();
        info = new BurnRiseTokenInfo(address(pad));
        token = _launchEth(0.01 ether);
    }

    function test_CreatorUpdates() public {
        string memory j = '{"image":"keep","description":"new story","x":"https://x.com/ember"}';
        vm.expectEmit(true, true, false, true, address(info));
        emit TokenInfoSet(token, creator, j);
        vm.prank(creator);
        info.setTokenInfo(token, j);
        assertEq(address(info.launchpad()), address(pad));
        assertEq(info.deployedAt(), block.timestamp);
    }

    function test_OthersCant() public {
        vm.prank(alice);
        vm.expectRevert(BurnRiseTokenInfo.NotCreator.selector);
        info.setTokenInfo(token, "{}");
        vm.prank(alice);
        vm.expectRevert(BurnRiseTokenInfo.NotCreator.selector); // not a BurnRise token: no creator on record
        info.setTokenInfo(address(0xBEEF), "{}");
    }

    function test_FollowsCreatorHandover() public {
        vm.prank(creator);
        pad.setCreator(token, bob);
        vm.prank(creator);
        vm.expectRevert(BurnRiseTokenInfo.NotCreator.selector);
        info.setTokenInfo(token, "{}");
        vm.prank(bob);
        info.setTokenInfo(token, '{"description":"bob runs it now"}');
    }

    function test_InfoLimitAndPictureBytes() public {
        bytes memory big = new bytes(513);
        for (uint256 i; i < big.length; ++i) big[i] = "a";
        vm.prank(creator);
        vm.expectRevert(BurnRiseTokenInfo.InfoTooLong.selector);
        info.setTokenInfo(token, string(big));
        // a picture after the arguments, as the website sends it, is ignored by the contract
        bytes memory call_ = abi.encodeCall(BurnRiseTokenInfo.setTokenInfo, (token, '{"image":"tx"}'));
        vm.prank(creator);
        (bool ok,) = address(info).call(bytes.concat(call_, hex"4252494d4731020000000401020304"));
        assertTrue(ok);
    }
}
