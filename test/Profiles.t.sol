// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnRiseProfiles} from "../src/BurnRiseProfiles.sol";

contract ProfilesTest is Test {
    BurnRiseProfiles p;
    address team = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    event ProfileSet(address indexed user, string name, string bio, uint8 picture);

    function setUp() public {
        vm.warp(1_800_000_000);
        p = new BurnRiseProfiles(team);
    }

    function test_SetProfile_StoresNameAndEmitsBioAndPicture() public {
        vm.expectEmit(true, false, false, true, address(p));
        emit ProfileSet(alice, "Vaseto", "the best hacker", 1);
        vm.prank(alice);
        p.setProfile("Vaseto", "the best hacker", 1);
        assertEq(p.nameOf(alice), "Vaseto");
        assertEq(p.ownerOfName("vaseto"), alice);
        assertEq(p.ownerOfName("VASETO"), alice);
        assertEq(p.deployedAt(), 1_800_000_000);
    }

    function test_NamesAreUniqueWhateverTheCase() public {
        vm.prank(alice);
        p.setProfile("Vaseto", "", 0);
        vm.prank(bob);
        vm.expectRevert(BurnRiseProfiles.NameTaken.selector);
        p.setProfile("vASETO", "", 0);
    }

    function test_ChangingNameFreesTheOldOne() public {
        vm.startPrank(alice);
        p.setProfile("first_name", "", 0);
        p.setProfile("second", "", 2);
        vm.stopPrank();
        assertEq(p.ownerOfName("first_name"), address(0));
        assertEq(p.ownerOfName("second"), alice);
        vm.prank(bob);
        p.setProfile("FIRST_name", "", 0);
        assertEq(p.ownerOfName("first_name"), bob);
    }

    function test_SameNameNewCaseAndClearing() public {
        vm.startPrank(alice);
        p.setProfile("popo", "bio", 1);
        p.setProfile("PoPo", "new bio", 2); // same name, new case: still hers
        assertEq(p.nameOf(alice), "PoPo");
        assertEq(p.ownerOfName("popo"), alice);
        p.setProfile("", "only a bio", 0); // no username
        vm.stopPrank();
        assertEq(p.nameOf(alice), "");
        assertEq(p.ownerOfName("popo"), address(0));
    }

    function test_NameRules() public {
        string[6] memory bad = ["ab", "this_name_is_way_too_long", "has space", "emoji\xf0\x9f\x94\xa5", "dash-ed", "dot.ted"];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(BurnRiseProfiles.BadName.selector);
            p.setProfile(bad[i], "", 0);
            assertEq(p.ownerOfName(bad[i]), address(0));
        }
        vm.prank(alice);
        p.setProfile("abc_123_XYZ", "", 0);
        vm.prank(bob);
        p.setProfile("a2345678901234567890", "", 0); // exactly 20
    }

    function test_BioAndPictureLimits() public {
        bytes memory bio = new bytes(641);
        for (uint256 i; i < bio.length; ++i) bio[i] = "a";
        vm.prank(alice);
        vm.expectRevert(BurnRiseProfiles.BioTooLong.selector);
        p.setProfile("alice", string(bio), 0);
        vm.prank(alice);
        vm.expectRevert(BurnRiseProfiles.BadPicture.selector);
        p.setProfile("alice", "", 3);
        assembly { mstore(bio, 640) }
        vm.prank(alice);
        p.setProfile("alice", string(bio), 2);
    }

    function test_KeptNamesOnlyForTheTeam() public {
        assertEq(p.ownerOfName("BurnRise"), team);
        vm.prank(alice);
        vm.expectRevert(BurnRiseProfiles.NameTaken.selector);
        p.setProfile("BurnRise", "", 0);
        vm.prank(alice);
        vm.expectRevert(BurnRiseProfiles.NameTaken.selector);
        p.setProfile("ADMIN", "", 0);
        vm.startPrank(team);
        p.setProfile("BurnRise", "official", 1);
        p.setProfile("BurnRiseX", "official", 2); // the team moves on: "burnrise" stays kept
        vm.stopPrank();
        assertEq(p.ownerOfName("burnrise"), team);
        vm.prank(alice);
        vm.expectRevert(BurnRiseProfiles.NameTaken.selector);
        p.setProfile("burnrise", "", 0);
    }

    function test_ExtraCalldataAfterTheArgumentsIsIgnored() public {
        bytes memory call_ = abi.encodeCall(BurnRiseProfiles.setProfile, ("withpic", "hi", uint8(1)));
        bytes memory pic = hex"4252494d4731010000000401020304"; // the website's picture marker, type, length, bytes
        vm.prank(alice);
        (bool ok,) = address(p).call(bytes.concat(call_, pic));
        assertTrue(ok);
        assertEq(p.nameOf(alice), "withpic");
    }
}
