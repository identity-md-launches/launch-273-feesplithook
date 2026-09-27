// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {THRW} from "../src/THRW.sol";

contract THRWTest is Test {
    THRW private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new THRW();
    }

    function test_metadataAndSingleMint() public view {
        assertEq(token.name(), "Threeway");
        assertEq(token.symbol(), "THRW");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transferAndAllowance(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        vm.prank(ALICE);
        token.approve(address(this), amount);
        assertTrue(token.transferFrom(ALICE, BOB, amount));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.allowance(ALICE, address(this)), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_failuresAndNoPrivilegedSelectors() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(ALICE);
        vm.expectRevert();
        token.transfer(BOB, 1);
        vm.expectRevert();
        token.transferFrom(ALICE, BOB, 1);
        string[6] memory selectors = [
            "mint(address,uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "burn(uint256)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(selectors[i], ALICE, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
