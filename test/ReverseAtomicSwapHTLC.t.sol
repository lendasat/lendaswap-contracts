// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/ReverseAtomicSwapHTLC.sol";
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

// Mock Uniswap Router for testing
contract MockSwapRouter {
    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        // Simple mock: transfer tokenIn from sender and mint tokenOut to recipient
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Mock 1:1 swap ratio for simplicity (in reality, this would depend on pool)
        amountOut = params.amountIn;

        // Mint and transfer tokenOut to recipient
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);

        return amountOut;
    }
}

contract ReverseAtomicSwapHTLCTest is Test {
    ReverseAtomicSwapHTLC public htlc;
    MockERC20 public wbtc;
    MockERC20 public usdc;
    MockSwapRouter public router;
    ERC2771Forwarder public forwarder;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public relayer = address(0x3);

    bytes32 public secret = bytes32(uint256(12345));
    bytes32 public hashLock;

    function setUp() public {
        // Deploy mock tokens
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC");
        usdc = new MockERC20("USD Coin", "USDC");

        // Deploy mock router
        router = new MockSwapRouter();

        // Deploy forwarder for meta-transactions (LOCAL TESTING ONLY)
        forwarder = new ERC2771Forwarder("ERC2771Forwarder");

        // Deploy HTLC contract
        htlc = new ReverseAtomicSwapHTLC(address(router), address(forwarder));

        // Mint tokens to alice
        usdc.mint(alice, 100 * 10 ** 18);

        // Calculate hash lock
        hashLock = sha256(abi.encodePacked(secret));

        // Label addresses for better trace output
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(relayer, "Relayer");
        vm.label(address(htlc), "ReverseHTLC");
        vm.label(address(wbtc), "WBTC");
        vm.label(address(usdc), "USDC");
    }

    function testCreateSwap() public {
        vm.startPrank(alice);

        uint256 amount = 10 * 10 ** 18; // 10 USDC
        bytes32 swapId = keccak256("swap1");

        // Approve HTLC to spend USDC
        usdc.approve(address(htlc), amount);

        // Create swap (should swap USDC to WBTC and lock WBTC)
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            block.timestamp + 1 hours,
            3000,
            0
        );

        vm.stopPrank();

        // Verify swap was created
        ReverseAtomicSwapHTLC.Swap memory swap = htlc.getSwap(swapId);
        assertEq(swap.sender, alice);
        assertEq(swap.recipient, bob);
        assertEq(swap.amountIn, amount);
        assertEq(swap.amountOut, amount); // 1:1 in mock
        assertEq(swap.hashLock, hashLock);
        assertTrue(htlc.isSwapOpen(swapId));

        // Verify WBTC is locked in contract
        assertEq(wbtc.balanceOf(address(htlc)), amount);

        // Verify Alice's USDC was spent
        assertEq(usdc.balanceOf(alice), 90 * 10 ** 18);
    }

    function testClaimSwap() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        usdc.approve(address(htlc), amount);
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            block.timestamp + 1 hours,
            3000,
            0
        );
        vm.stopPrank();

        // Bob claims the swap with the secret
        uint256 bobBalanceBefore = wbtc.balanceOf(bob);

        vm.prank(bob);
        htlc.claimSwap(swapId, secret);

        // Verify swap was claimed
        ReverseAtomicSwapHTLC.Swap memory swap = htlc.getSwap(swapId);
        assertEq(uint256(swap.state), uint256(ReverseAtomicSwapHTLC.SwapState.CLAIMED));
        assertFalse(htlc.isSwapOpen(swapId));

        // Verify Bob received WBTC
        assertEq(wbtc.balanceOf(bob), bobBalanceBefore + amount);

        // Verify contract no longer has WBTC
        assertEq(wbtc.balanceOf(address(htlc)), 0);
    }

    function testClaimSwapWithWrongSecret() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        usdc.approve(address(htlc), amount);
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            block.timestamp + 1 hours,
            3000,
            0
        );
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
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        usdc.approve(address(htlc), amount);
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            timelock,
            3000,
            0
        );

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.stopPrank();

        // Fast forward time past timelock
        vm.warp(timelock + 1);

        // Alice refunds the swap (should swap WBTC back to USDC)
        vm.prank(alice);
        htlc.refundSwap(swapId);

        // Verify swap was refunded
        ReverseAtomicSwapHTLC.Swap memory swap = htlc.getSwap(swapId);
        assertEq(uint256(swap.state), uint256(ReverseAtomicSwapHTLC.SwapState.REFUNDED));
        assertFalse(htlc.isSwapOpen(swapId));

        // Verify Alice got USDC back (mock does 1:1 swap)
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + amount);

        // Verify contract no longer has WBTC
        assertEq(wbtc.balanceOf(address(htlc)), 0);
    }

    function testCannotRefundBeforeTimelock() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        usdc.approve(address(htlc), amount);
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            timelock,
            3000,
            0
        );
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
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        usdc.approve(address(htlc), amount);
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            timelock,
            3000,
            0
        );
        vm.stopPrank();

        // Fast forward time
        vm.warp(timelock + 1);

        // Bob tries to refund (should fail)
        vm.prank(bob);
        vm.expectRevert("Only sender can refund");
        htlc.refundSwap(swapId);
    }

    function testCannotClaimAfterTimelock() public {
        // Setup: Alice creates a swap
        vm.startPrank(alice);
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 timelock = block.timestamp + 1 hours;

        usdc.approve(address(htlc), amount);
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            timelock,
            3000,
            0
        );
        vm.stopPrank();

        // Fast forward time past timelock
        vm.warp(timelock + 1);

        // Bob tries to claim (should fail)
        vm.prank(bob);
        vm.expectRevert("Swap expired");
        htlc.claimSwap(swapId, secret);
    }

    function testCannotCreateDuplicateSwap() public {
        vm.startPrank(alice);
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        usdc.approve(address(htlc), amount * 2);

        // Create first swap
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            block.timestamp + 1 hours,
            3000,
            0
        );

        // Try to create duplicate swap
        vm.expectRevert("Swap already exists");
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            block.timestamp + 1 hours,
            3000,
            0
        );

        vm.stopPrank();
    }

    function testMetaTransactionSupport() public view {
        // Verify the contract has a trusted forwarder set
        assertTrue(htlc.isTrustedForwarder(address(forwarder)));
    }

    function testSlippageProtection() public {
        // Setup: Alice creates a swap with minAmountOut for initial swap
        // Note: No minRefundAmount - refunds accept any amount to prevent permanent fund locking
        vm.startPrank(alice);
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");
        uint256 minAmountOut = 9 * 10 ** 18; // 10% slippage tolerance on creation

        usdc.approve(address(htlc), amount);
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            block.timestamp + 1 hours,
            3000,
            minAmountOut
        );
        vm.stopPrank();

        // Verify slippage protection value is stored
        ReverseAtomicSwapHTLC.Swap memory swap = htlc.getSwap(swapId);
        assertEq(swap.minAmountOut, minAmountOut);
    }

    function testEmitsEventsCorrectly() public {
        vm.startPrank(alice);
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap1");

        usdc.approve(address(htlc), amount);

        // Test SwapCreated event
        vm.expectEmit(true, true, true, false); // Don't check data for amountOut (mock returns it)
        emit ReverseAtomicSwapHTLC.SwapCreated(
            swapId,
            alice,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            amount, // Mock does 1:1
            hashLock,
            block.timestamp + 1 hours,
            3000,
            0
        );

        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            block.timestamp + 1 hours,
            3000,
            0
        );
        vm.stopPrank();

        // Test SwapClaimed event
        vm.expectEmit(true, false, false, true);
        emit ReverseAtomicSwapHTLC.SwapClaimed(swapId, secret);

        vm.prank(bob);
        htlc.claimSwap(swapId, secret);
    }

    function testRefundEmitsEventCorrectly() public {
        vm.startPrank(alice);
        uint256 amount = 10 * 10 ** 18;
        bytes32 swapId = keccak256("swap2");
        uint256 timelock = block.timestamp + 1 hours;

        usdc.approve(address(htlc), amount);
        htlc.createSwap(
            swapId,
            bob,
            address(usdc),
            address(wbtc),
            amount,
            hashLock,
            timelock,
            3000,
            0
        );
        vm.stopPrank();

        // Fast forward time
        vm.warp(timelock + 1);

        // Test SwapRefunded event
        vm.expectEmit(true, false, false, false);
        emit ReverseAtomicSwapHTLC.SwapRefunded(swapId, amount); // Mock returns 1:1

        vm.prank(alice);
        htlc.refundSwap(swapId);
    }
}
