// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HTLCErc20, SwapKey} from "../src/HTLCErc20.sol";

contract MockWBTC is ERC20 {
    constructor() ERC20("Wrapped Bitcoin", "WBTC") {
        _mint(msg.sender, 100e8);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

/// @notice A swap is identified by its `key`, not by its `preimageHash`. Any number of
///         swaps may share one `preimageHash`, each with independent terms and lifecycle,
///         so every lifecycle event carries the `key` a consumer must match on.
contract HTLCErc20SwapIdentityTest is Test {
    event SwapCreated(
        bytes32 indexed preimageHash,
        address indexed refundAddress,
        address indexed claimAddress,
        address token,
        uint256 amount,
        uint256 timelock,
        SwapKey key
    );
    event SwapRedeemed(bytes32 indexed preimageHash, SwapKey indexed key, bytes32 preimage);
    event SwapRefunded(bytes32 indexed preimageHash, SwapKey indexed key);

    HTLCErc20 htlc;
    MockWBTC wbtc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20(address(this));
        wbtc = new MockWBTC();
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        wbtc.transfer(alice, 10e8);
        wbtc.transfer(carol, 10e8);
    }

    function _create(address from, uint256 amount, address claimAddress, uint256 lock) internal {
        vm.startPrank(from);
        wbtc.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(wbtc), claimAddress, lock);
        vm.stopPrank();
    }

    function test_createEmitsSwapKey() public {
        uint256 amount = 1e8;
        SwapKey key = htlc.computeKey(preimageHash, amount, address(wbtc), alice, bob, timelock);

        vm.prank(alice);
        wbtc.approve(address(htlc), amount);

        vm.expectEmit(true, true, true, true, address(htlc));
        emit SwapCreated(preimageHash, alice, bob, address(wbtc), amount, timelock, key);
        vm.prank(alice);
        htlc.create(preimageHash, amount, address(wbtc), bob, timelock);
    }

    function test_redeemEmitsSwapKey() public {
        uint256 amount = 1e8;
        _create(alice, amount, bob, timelock);
        SwapKey key = htlc.computeKey(preimageHash, amount, address(wbtc), alice, bob, timelock);

        vm.expectEmit(true, true, false, true, address(htlc));
        emit SwapRedeemed(preimageHash, key, preimage);
        vm.prank(bob);
        htlc.redeem(preimage, amount, address(wbtc), alice, timelock);
    }

    function test_refundEmitsSwapKey() public {
        uint256 amount = 1e8;
        _create(alice, amount, bob, timelock);
        SwapKey key = htlc.computeKey(preimageHash, amount, address(wbtc), alice, bob, timelock);

        vm.warp(timelock);

        vm.expectEmit(true, true, false, true, address(htlc));
        emit SwapRefunded(preimageHash, key);
        vm.prank(alice);
        htlc.refund(preimageHash, amount, address(wbtc), bob, timelock);
    }

    /// Two swaps sharing a `preimageHash` are distinct swaps: both hold funds at once,
    /// and each carries its own key.
    function test_swapsSharingPreimageHashCoexist() public {
        uint256 amountA = 1e8;
        uint256 amountB = 5e7;
        uint256 timelockB = timelock + 1 hours;

        _create(alice, amountA, bob, timelock);
        _create(carol, amountB, carol, timelockB);

        SwapKey keyA = htlc.computeKey(preimageHash, amountA, address(wbtc), alice, bob, timelock);
        SwapKey keyB = htlc.computeKey(preimageHash, amountB, address(wbtc), carol, carol, timelockB);

        assertTrue(SwapKey.unwrap(keyA) != SwapKey.unwrap(keyB), "distinct terms must yield distinct keys");
        assertTrue(htlc.isActive(preimageHash, amountA, address(wbtc), alice, bob, timelock), "swap A active");
        assertTrue(htlc.isActive(preimageHash, amountB, address(wbtc), carol, carol, timelockB), "swap B active");
        assertEq(wbtc.balanceOf(address(htlc)), amountA + amountB, "both swaps hold funds");
    }

    /// Settling one swap emits that swap's key and leaves the other untouched.
    function test_redeemingOneLeavesTheOtherActive() public {
        uint256 amountA = 1e8;
        uint256 amountB = 5e7;
        uint256 timelockB = timelock + 1 hours;

        _create(alice, amountA, bob, timelock);
        _create(carol, amountB, carol, timelockB);

        SwapKey keyB = htlc.computeKey(preimageHash, amountB, address(wbtc), carol, carol, timelockB);

        // Carol redeems her own swap. The event names keyB, not keyA.
        vm.expectEmit(true, true, false, true, address(htlc));
        emit SwapRedeemed(preimageHash, keyB, preimage);
        vm.prank(carol);
        htlc.redeem(preimage, amountB, address(wbtc), carol, timelockB);

        assertTrue(
            htlc.isActive(preimageHash, amountA, address(wbtc), alice, bob, timelock), "swap A must be unaffected"
        );
        assertFalse(htlc.isActive(preimageHash, amountB, address(wbtc), carol, carol, timelockB), "swap B settled");
        assertEq(wbtc.balanceOf(address(htlc)), amountA, "only swap A's funds remain");
    }

    /// The refund path carries the same guarantee.
    function test_refundingOneLeavesTheOtherActive() public {
        uint256 amountA = 1e8;
        uint256 amountB = 5e7;

        _create(alice, amountA, bob, timelock);
        _create(carol, amountB, carol, timelock);

        SwapKey keyB = htlc.computeKey(preimageHash, amountB, address(wbtc), carol, carol, timelock);

        vm.warp(timelock);

        vm.expectEmit(true, true, false, true, address(htlc));
        emit SwapRefunded(preimageHash, keyB);
        vm.prank(carol);
        htlc.refund(preimageHash, amountB, address(wbtc), carol, timelock);

        assertTrue(
            htlc.isActive(preimageHash, amountA, address(wbtc), alice, bob, timelock), "swap A must be unaffected"
        );
        assertEq(wbtc.balanceOf(address(htlc)), amountA, "only swap A's funds remain");
    }
}
