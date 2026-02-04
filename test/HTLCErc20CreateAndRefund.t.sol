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

/// @notice E2E: user creates an HTLC with WBTC, timelock expires, sender refunds
contract HTLCErc20CreateAndRefundTest is Test {
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

        wbtc.transfer(alice, 10e8);
    }

    function test_createAndRefund() public {
        // 1. Alice creates an HTLC locking 1 WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(wbtc), bob, timelock);
        vm.stopPrank();

        assertEq(wbtc.balanceOf(alice), 9e8);
        assertEq(wbtc.balanceOf(address(htlc)), amount);

        // 2. Bob never redeems — timelock expires
        vm.warp(timelock + 1);

        // 3. Alice refunds and gets her WBTC back
        vm.prank(alice);
        htlc.refund(preimageHash, amount, address(wbtc), bob, timelock);

        assertEq(wbtc.balanceOf(alice), 10e8, "alice should have all 10 WBTC back");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertFalse(
            htlc.isActive(preimageHash, amount, address(wbtc), alice, bob, timelock),
            "swap should no longer be active"
        );
    }

    function test_refundBeforeTimelock_reverts() public {
        // 1. Alice creates an HTLC
        vm.startPrank(alice);
        wbtc.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // 2. Alice tries to refund before timelock expires — should revert
        vm.prank(alice);
        vm.expectRevert(HTLCErc20.TimelockNotExpired.selector);
        htlc.refund(preimageHash, amount, address(wbtc), bob, timelock);

        // Verify: nothing changed
        assertEq(wbtc.balanceOf(alice), 9e8, "alice should still have 9 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), amount, "htlc should still hold 1 WBTC");
    }
}
