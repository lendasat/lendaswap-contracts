// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";
import {HTLCCoordinator} from "../src/HTLCCoordinator.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockWBTC is ERC20 {
    constructor() ERC20("Wrapped Bitcoin", "WBTC") {
        _mint(msg.sender, 100e8);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

/// @notice Mock DEX with configurable rates per token pair
contract MockDEX {
    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }

    mapping(bytes32 => Rate) public rates;

    function setRate(address tokenIn, address tokenOut, uint256 numerator, uint256 denominator) external {
        rates[keccak256(abi.encodePacked(tokenIn, tokenOut))] = Rate(numerator, denominator);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        Rate memory rate = rates[keccak256(abi.encodePacked(tokenIn, tokenOut))];
        amountOut = (amountIn * rate.numerator) / rate.denominator;
        require(amountOut >= minAmountOut, "MockDEX: slippage");

        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

/// @notice E2E: Alice locks WBTC in an HTLC first, Bob redeems via coordinator
///         which swaps WBTC -> USDC so Bob receives USDC.
contract HTLCCoordinatorLockAndSwapTest is Test {
    HTLCErc20 htlc;
    HTLCCoordinator coordinator;
    MockUSDC usdc;
    MockWBTC wbtc;
    MockDEX dex;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 wbtcAmount = 1e8; // 1 WBTC
    uint256 expectedUsdc = 60_000e6; // 60,000 USDC
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20();
        coordinator = new HTLCCoordinator(address(htlc));
        usdc = new MockUSDC();
        wbtc = new MockWBTC();
        dex = new MockDEX();

        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        // Fund alice with WBTC
        wbtc.transfer(alice, 10e8);

        // Fund the DEX with USDC liquidity
        usdc.transfer(address(dex), 500_000e6);

        // Configure rate: 1 WBTC = 60,000 USDC
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8);
    }

    function test_lockThenRedeemAndSwap() public {
        // 1. Alice locks WBTC in the HTLC with the coordinator as recipient
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), address(coordinator), timelock);
        vm.stopPrank();

        // Verify: WBTC moved from Alice to the HTLC
        assertEq(wbtc.balanceOf(alice), 9e8, "alice should have 9 WBTC left");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should hold 1 WBTC");
        assertTrue(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, address(coordinator), timelock),
            "swap should be active"
        );

        // 2. Bob redeems via coordinator: redeem WBTC, swap WBTC -> USDC, sweep USDC to Bob
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](2);

        calls[0] = HTLCCoordinator.Call({
            target: address(wbtc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), wbtcAmount))
        });

        calls[1] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(wbtc),
                address(usdc),
                wbtcAmount,
                expectedUsdc
            )
        });

        vm.prank(bob);
        coordinator.redeemAndExecute(
            preimage,
            wbtcAmount,
            address(wbtc),
            alice,
            timelock,
            calls,
            address(usdc),
            expectedUsdc
        );

        // Verify: Bob received USDC, HTLC is empty
        assertEq(usdc.balanceOf(bob), expectedUsdc, "bob should have 60k USDC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertEq(wbtc.balanceOf(address(coordinator)), 0, "coordinator should have no leftover WBTC");
        assertFalse(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, address(coordinator), timelock),
            "swap should no longer be active"
        );
    }

    function test_lockThenRedeemWithInvalidPreimage_reverts() public {
        // 1. Alice locks WBTC
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), address(coordinator), timelock);
        vm.stopPrank();

        // 2. Bob tries to redeem with wrong preimage
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](2);
        calls[0] = HTLCCoordinator.Call({
            target: address(wbtc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), wbtcAmount))
        });
        calls[1] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(wbtc),
                address(usdc),
                wbtcAmount,
                expectedUsdc
            )
        });

        bytes32 wrongPreimage = bytes32(uint256(0xbaadf00d));
        vm.prank(bob);
        vm.expectRevert(HTLCErc20.SwapNotFound.selector);
        coordinator.redeemAndExecute(
            wrongPreimage,
            wbtcAmount,
            address(wbtc),
            alice,
            timelock,
            calls,
            address(usdc),
            expectedUsdc
        );

        // Verify: WBTC still locked
        assertEq(usdc.balanceOf(bob), 0, "bob should still have 0 USDC");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should still hold 1 WBTC");
    }

    function test_lockThenRefund_wbtc() public {
        // 1. Alice locks WBTC with coordinator as recipient
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), address(coordinator), timelock);
        vm.stopPrank();

        assertEq(wbtc.balanceOf(alice), 9e8, "alice should have 9 WBTC left");

        // 2. Bob never claims — timelock expires
        vm.warp(timelock + 1);

        // 3. Alice refunds directly on the HTLC — gets her WBTC back
        vm.prank(alice);
        htlc.refund(preimageHash, wbtcAmount, address(wbtc), address(coordinator), timelock);

        // Verify: Alice got her WBTC back
        assertEq(wbtc.balanceOf(alice), 10e8, "alice should have all 10 WBTC back");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertFalse(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, address(coordinator), timelock),
            "swap should no longer be active"
        );
    }

    function test_lockThenThirdPartyRedeems_recipientReceives() public {
        // 1. Alice locks WBTC directly in the HTLC with Bob as recipient
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        assertEq(wbtc.balanceOf(alice), 9e8, "alice should have 9 WBTC left");
        assertEq(wbtc.balanceOf(bob), 0, "bob should have 0 WBTC");

        // 2. Charlie (a third party) reveals the preimage — tokens go to Bob, not Charlie
        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        htlc.redeem(preimage, wbtcAmount, address(wbtc), alice, bob, timelock);

        // Verify: Bob received the WBTC, Charlie got nothing
        assertEq(wbtc.balanceOf(bob), wbtcAmount, "bob should have 1 WBTC");
        assertEq(wbtc.balanceOf(charlie), 0, "charlie should have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
    }
}
