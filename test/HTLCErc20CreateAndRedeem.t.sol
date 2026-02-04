// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";

contract MockWBTC is ERC20 {
    constructor() ERC20("Wrapped Bitcoin", "WBTC") {
        _mint(msg.sender, 100e8);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

/// @notice E2E: user creates an HTLC with WBTC, claimAddress redeems it
contract HTLCErc20CreateAndRedeemTest is Test {
    HTLCErc20 htlc;
    MockWBTC wbtc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1e8; // 1 WBTC
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20();
        wbtc = new MockWBTC();
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        // Fund alice with WBTC
        wbtc.transfer(alice, 10e8);
    }

    function test_createAndRedeem() public {
        // 1. Alice creates an HTLC locking 1 WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Verify: WBTC moved from alice to the HTLC contract
        assertEq(wbtc.balanceOf(alice), 9e8, "alice should have 9 WBTC left");
        assertEq(wbtc.balanceOf(address(htlc)), amount, "htlc should hold 1 WBTC");
        assertTrue(
            htlc.isActive(preimageHash, amount, address(wbtc), alice, bob, timelock),
            "swap should be active"
        );

        // 2. Bob (claimAddress) redeems by revealing the preimage
        vm.prank(bob);
        htlc.redeem(preimage, amount, address(wbtc), alice, timelock);

        // Verify: WBTC moved from HTLC to Bob (msg.sender = claimAddress)
        assertEq(wbtc.balanceOf(bob), amount, "bob should have received 1 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertFalse(
            htlc.isActive(preimageHash, amount, address(wbtc), alice, bob, timelock),
            "swap should no longer be active"
        );
    }

    function test_redeemWithInvalidPreimage_reverts() public {
        // 1. Alice creates an HTLC
        vm.startPrank(alice);
        wbtc.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // 2. Bob tries to redeem with a wrong preimage — should revert
        bytes32 wrongPreimage = bytes32(uint256(0xbaadf00d));
        vm.prank(bob);
        vm.expectRevert(HTLCErc20.SwapNotFound.selector);
        htlc.redeem(wrongPreimage, amount, address(wbtc), alice, timelock);

        // Verify: nothing changed
        assertEq(wbtc.balanceOf(bob), 0, "bob should still have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), amount, "htlc should still hold 1 WBTC");
    }

    function test_redeemByNonClaimAddress_reverts() public {
        // 1. Alice creates an HTLC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // 2. Charlie (not the claimAddress) tries to redeem — should fail
        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        vm.expectRevert(HTLCErc20.SwapNotFound.selector);
        htlc.redeem(preimage, amount, address(wbtc), alice, timelock);

        // Verify: nothing changed
        assertEq(wbtc.balanceOf(charlie), 0, "charlie should have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), amount, "htlc should still hold 1 WBTC");
    }
}
