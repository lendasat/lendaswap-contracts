// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/ERC20HTLC.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ERC20HTLCTest is Test {
    ERC20HTLC public htlc;
    MockERC20 public wbtc;
    ERC2771Forwarder public forwarder;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public relayer = address(0x3);

    bytes32 public secret = bytes32(uint256(12345));
    bytes32 public hashLock;

    function setUp() public {
        // Deploy mock token
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC");

        // Deploy forwarder for meta-transactions (LOCAL TESTING ONLY)
        forwarder = new ERC2771Forwarder("ERC2771Forwarder");

        // Deploy HTLC contract
        htlc = new ERC20HTLC(address(forwarder));

        // Mint tokens to alice
        wbtc.mint(alice, 10 * 10 ** 18);

        // Calculate hash lock
        hashLock = sha256(abi.encodePacked(secret));

        // Label addresses for better trace output
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(relayer, "Relayer");
        vm.label(address(htlc), "HTLC");
        vm.label(address(wbtc), "WBTC");
    }

    function testCreateSwap() public {
        vm.startPrank(alice);

        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        // Approve HTLC to spend WBTC
        wbtc.approve(address(htlc), amount);

        // Create swap
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, block.timestamp + 1 hours);

        vm.stopPrank();

        // Verify swap was created
        ERC20HTLC.Swap memory swap = htlc.getSwap(swapId);
        assertEq(swap.sender, alice);
        assertEq(swap.recipient, bob);
        assertEq(swap.token, address(wbtc));
        assertEq(swap.amount, amount);
        assertEq(swap.hashLock, hashLock);
        assertTrue(htlc.isSwapOpen(swapId));

        // Verify tokens were transferred
        assertEq(wbtc.balanceOf(address(htlc)), amount);
    }

    function testClaimSwap() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, block.timestamp + 1 hours);
        vm.stopPrank();

        // Bob claims the swap with the secret
        uint256 bobBalanceBefore = wbtc.balanceOf(bob);

        vm.prank(bob);
        htlc.claimSwap(swapId, secret);

        // Verify swap was claimed
        ERC20HTLC.Swap memory swap = htlc.getSwap(swapId);
        assertEq(uint256(swap.state), uint256(ERC20HTLC.SwapState.CLAIMED));
        assertFalse(htlc.isSwapOpen(swapId));

        // Verify Bob received WBTC
        assertEq(wbtc.balanceOf(bob), bobBalanceBefore + amount);
    }

    function testAnyoneCanClaimWithSecret() public {
        // Setup: Alice creates a swap for Bob
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 bobBalanceBefore = wbtc.balanceOf(bob);

        // Relayer (third party) claims on behalf of Bob with the secret
        vm.prank(relayer);
        htlc.claimSwap(swapId, secret);

        // Verify Bob received tokens (not the relayer)
        assertEq(wbtc.balanceOf(bob), bobBalanceBefore + amount);
        assertEq(wbtc.balanceOf(relayer), 0);
    }

    function testClaimSwapWithWrongSecret() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, block.timestamp + 1 hours);
        vm.stopPrank();

        // Bob tries to claim with wrong secret
        bytes32 wrongSecret = bytes32(uint256(99999));

        vm.prank(bob);
        vm.expectRevert("Invalid secret");
        htlc.claimSwap(swapId, wrongSecret);

        // Verify swap is still open
        assertTrue(htlc.isSwapOpen(swapId));
    }

    function testRefundSwap() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, timelock);

        uint256 aliceBalanceBefore = wbtc.balanceOf(alice);
        vm.stopPrank();

        // Fast forward time past timelock
        vm.warp(timelock + 1);

        // Alice refunds the swap
        vm.prank(alice);
        htlc.refundSwap(swapId);

        // Verify swap was refunded
        ERC20HTLC.Swap memory swap = htlc.getSwap(swapId);
        assertEq(uint256(swap.state), uint256(ERC20HTLC.SwapState.REFUNDED));
        assertFalse(htlc.isSwapOpen(swapId));

        // Verify Alice got tokens back
        assertEq(wbtc.balanceOf(alice), aliceBalanceBefore + amount);
    }

    function testCannotRefundBeforeTimelock() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, timelock);
        vm.stopPrank();

        // Try to refund before timelock
        vm.prank(alice);
        vm.expectRevert("Timelock not expired");
        htlc.refundSwap(swapId);

        // Verify swap is still open
        assertTrue(htlc.isSwapOpen(swapId));
    }

    function testOnlySenderCanRefund() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, timelock);
        vm.stopPrank();

        // Fast forward time
        vm.warp(timelock + 1);

        // Bob tries to refund (should fail)
        vm.prank(bob);
        vm.expectRevert("Only sender can refund");
        htlc.refundSwap(swapId);
    }
    
    function testCannotCreateDuplicateSwap() public {
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), amount * 2);

        // Create first swap
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, block.timestamp + 1 hours);

        // Try to create duplicate swap
        vm.expectRevert("Swap already exists");
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, block.timestamp + 1 hours);

        vm.stopPrank();
    }

    function testCannotClaimNonExistentSwap() public {
        bytes32 swapId = keccak256("nonexistent");

        vm.prank(bob);
        vm.expectRevert("Swap not open");
        htlc.claimSwap(swapId, secret);
    }

    function testCannotRefundNonExistentSwap() public {
        bytes32 swapId = keccak256("nonexistent");

        vm.prank(alice);
        vm.expectRevert("Swap not open");
        htlc.refundSwap(swapId);
    }

    function testCannotClaimAlreadyClaimedSwap() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, block.timestamp + 1 hours);
        vm.stopPrank();

        // Bob claims the swap
        vm.prank(bob);
        htlc.claimSwap(swapId, secret);

        // Try to claim again
        vm.prank(bob);
        vm.expectRevert("Swap not open");
        htlc.claimSwap(swapId, secret);
    }

    function testCannotRefundAlreadyRefundedSwap() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, timelock);
        vm.stopPrank();

        // Fast forward time past timelock
        vm.warp(timelock + 1);

        // Alice refunds the swap
        vm.prank(alice);
        htlc.refundSwap(swapId);

        // Try to refund again
        vm.prank(alice);
        vm.expectRevert("Swap not open");
        htlc.refundSwap(swapId);
    }

    function testMetaTransactionSupport() public view {
        // Verify the contract has a trusted forwarder set
        assertTrue(htlc.isTrustedForwarder(address(forwarder)));
    }

    function testEmitsSwapCreatedEvent() public {
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        wbtc.approve(address(htlc), amount);

        // Test SwapCreated event
        vm.expectEmit(true, true, true, true);
        emit ERC20HTLC.SwapCreated(swapId, alice, bob, address(wbtc), amount, hashLock, timelock);

        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, timelock);
        vm.stopPrank();
    }

    function testEmitsSwapClaimedEvent() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, block.timestamp + 1 hours);
        vm.stopPrank();

        // Test SwapClaimed event
        vm.expectEmit(true, false, false, true);
        emit ERC20HTLC.SwapClaimed(swapId, secret);

        vm.prank(bob);
        htlc.claimSwap(swapId, secret);
    }

    function testEmitsSwapRefundedEvent() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        wbtc.approve(address(htlc), amount);
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, timelock);
        vm.stopPrank();

        // Fast forward time past timelock
        vm.warp(timelock + 1);

        // Test SwapRefunded event
        vm.expectEmit(true, false, false, false);
        emit ERC20HTLC.SwapRefunded(swapId);

        vm.prank(alice);
        htlc.refundSwap(swapId);
    }

    function testCreateSwapWithZeroAmount() public {
        vm.startPrank(alice);
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), 1 * 10 ** 18);

        vm.expectRevert("Amount must be > 0");
        htlc.createSwap(swapId, bob, address(wbtc), 0, hashLock, block.timestamp + 1 hours);

        vm.stopPrank();
    }

    function testCreateSwapWithInvalidRecipient() public {
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), amount);

        vm.expectRevert("Invalid recipient");
        htlc.createSwap(swapId, address(0), address(wbtc), amount, hashLock, block.timestamp + 1 hours);

        vm.stopPrank();
    }

    function testCreateSwapWithInvalidToken() public {
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        vm.expectRevert("Invalid token");
        htlc.createSwap(swapId, bob, address(0), amount, hashLock, block.timestamp + 1 hours);

        vm.stopPrank();
    }

    function testCreateSwapWithInvalidHashLock() public {
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), amount);

        vm.expectRevert("Invalid hash lock");
        htlc.createSwap(swapId, bob, address(wbtc), amount, bytes32(0), block.timestamp + 1 hours);

        vm.stopPrank();
    }

    function testCreateSwapWithPastTimelock() public {
        vm.startPrank(alice);
        uint256 amount = 1 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        wbtc.approve(address(htlc), amount);

        vm.expectRevert("Timelock must be in future");
        htlc.createSwap(swapId, bob, address(wbtc), amount, hashLock, block.timestamp - 1);

        vm.stopPrank();
    }

    function testMultipleSwapsWithDifferentTokens() public {
        // Deploy another token
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");
        usdc.mint(alice, 10 * 10 ** 18);

        vm.startPrank(alice);
        uint256 wbtcAmount = 1 * 10 ** 18;
        uint256 usdcAmount = 2 * 10 ** 18;
        bytes32 swapId1 = keccak256("swap1");
        bytes32 swapId2 = keccak256("swap2");

        // Create swap with WBTC
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.createSwap(swapId1, bob, address(wbtc), wbtcAmount, hashLock, block.timestamp + 1 hours);

        // Create swap with USDC
        bytes32 secret2 = bytes32(uint256(54321));
        bytes32 hashLock2 = sha256(abi.encodePacked(secret2));
        usdc.approve(address(htlc), usdcAmount);
        htlc.createSwap(swapId2, bob, address(usdc), usdcAmount, hashLock2, block.timestamp + 2 hours);

        vm.stopPrank();

        // Verify both swaps exist
        ERC20HTLC.Swap memory swap1 = htlc.getSwap(swapId1);
        ERC20HTLC.Swap memory swap2 = htlc.getSwap(swapId2);

        assertEq(swap1.token, address(wbtc));
        assertEq(swap1.amount, wbtcAmount);
        assertEq(swap2.token, address(usdc));
        assertEq(swap2.amount, usdcAmount);

        // Claim both swaps
        vm.prank(bob);
        htlc.claimSwap(swapId1, secret);

        vm.prank(bob);
        htlc.claimSwap(swapId2, secret2);

        // Verify Bob received both tokens
        assertEq(wbtc.balanceOf(bob), wbtcAmount);
        assertEq(usdc.balanceOf(bob), usdcAmount);
    }
}