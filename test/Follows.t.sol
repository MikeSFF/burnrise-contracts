// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnRiseFollows} from "../src/BurnRiseFollows.sol";

contract FollowsTest is Test {
    BurnRiseFollows f;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    event Followed(address indexed follower, address indexed followed);
    event Unfollowed(address indexed follower, address indexed followed);

    function setUp() public {
        vm.warp(1_800_000_000);
        f = new BurnRiseFollows();
    }

    function test_Follow_CountsBothSidesAndEmits() public {
        vm.expectEmit(true, true, false, true, address(f));
        emit Followed(alice, bob);
        vm.prank(alice);
        f.follow(bob);
        assertTrue(f.isFollowing(alice, bob));
        assertFalse(f.isFollowing(bob, alice));
        assertEq(f.followerCount(bob), 1);
        assertEq(f.followingCount(alice), 1);
        assertEq(f.followerCount(alice), 0);
        assertEq(f.deployedAt(), 1_800_000_000);
    }

    function test_Unfollow_UndoesItAndEmits() public {
        vm.startPrank(alice);
        f.follow(bob);
        vm.expectEmit(true, true, false, true, address(f));
        emit Unfollowed(alice, bob);
        f.unfollow(bob);
        vm.stopPrank();
        assertFalse(f.isFollowing(alice, bob));
        assertEq(f.followerCount(bob), 0);
        assertEq(f.followingCount(alice), 0);
    }

    function test_CantFollowYourselfOrNobody() public {
        vm.startPrank(alice);
        vm.expectRevert(BurnRiseFollows.CantFollow.selector);
        f.follow(alice);
        vm.expectRevert(BurnRiseFollows.CantFollow.selector);
        f.follow(address(0));
        vm.stopPrank();
    }

    function test_CantFollowTwice_OrUnfollowSomeoneYouDontFollow() public {
        vm.startPrank(alice);
        f.follow(bob);
        vm.expectRevert(BurnRiseFollows.AlreadyFollowing.selector);
        f.follow(bob);
        vm.expectRevert(BurnRiseFollows.NotFollowing.selector);
        f.unfollow(carol);
        vm.stopPrank();
    }

    function test_ManyFollowers() public {
        vm.prank(alice);
        f.follow(carol);
        vm.prank(bob);
        f.follow(carol);
        vm.prank(carol);
        f.follow(alice);
        assertEq(f.followerCount(carol), 2);
        assertEq(f.followingCount(carol), 1);
        assertEq(f.followerCount(alice), 1);
        vm.prank(bob);
        f.unfollow(carol);
        assertEq(f.followerCount(carol), 1);
        assertEq(f.followingCount(bob), 0);
    }

    /// Any sequence of follows and unfollows keeps the counts equal to the real number of follows.
    function testFuzz_CountsMatch(uint8[24] calldata moves) public {
        address[4] memory w = [alice, bob, carol, address(0xD0D)];
        for (uint256 i; i < moves.length; ++i) {
            address from = w[moves[i] % 4];
            address to = w[(moves[i] >> 2) % 4];
            bool unf = moves[i] >> 4 & 1 == 1;
            bool was = f.isFollowing(from, to);   // read before the prank, which only covers the next call
            if (from == to) {
                vm.expectRevert(BurnRiseFollows.CantFollow.selector);
                vm.prank(from);
                f.follow(to);
            } else if (unf) {
                if (!was) vm.expectRevert(BurnRiseFollows.NotFollowing.selector);
                vm.prank(from);
                f.unfollow(to);
            } else {
                if (was) vm.expectRevert(BurnRiseFollows.AlreadyFollowing.selector);
                vm.prank(from);
                f.follow(to);
            }
        }
        for (uint256 a; a < 4; ++a) {
            uint256 followers;
            uint256 following;
            for (uint256 b; b < 4; ++b) {
                if (f.isFollowing(w[b], w[a])) ++followers;
                if (f.isFollowing(w[a], w[b])) ++following;
            }
            assertEq(f.followerCount(w[a]), followers);
            assertEq(f.followingCount(w[a]), following);
        }
    }
}
