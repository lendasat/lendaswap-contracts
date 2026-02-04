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

/// @notice E2E: Alice swaps USDC -> WBTC via DEX and locks WBTC in an HTLC, Bob claims the WBTC
contract HTLCCoordinatorCreateAndClaimTest is Test {
    HTLCErc20 htlc;
    HTLCCoordinator coordinator;
    MockUSDC usdc;
    MockWBTC wbtc;
    MockDEX dex;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 usdcAmount = 60_000e6; // 60,000 USDC
    uint256 expectedWbtc = 1e8; // 1 WBTC
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20();
        coordinator = new HTLCCoordinator(address(htlc));
        usdc = new MockUSDC();
        wbtc = new MockWBTC();
        dex = new MockDEX();

        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        // Fund alice with USDC
        usdc.transfer(alice, 100_000e6);

        // Fund the DEX with liquidity
        wbtc.transfer(address(dex), 50e8);
        usdc.transfer(address(dex), 500_000e6);

        // Configure rates: 60,000 USDC = 1 WBTC
        dex.setRate(address(usdc), address(wbtc), 1e8, 60_000e6); // USDC -> WBTC
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8); // WBTC -> USDC
    }

    function test_executeAndCreate_thenBobClaims() public {
        // 1. Alice approves the coordinator to pull her USDC
        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        // 2. Build calls: pull USDC from Alice, approve DEX, swap USDC -> WBTC
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](3);

        calls[0] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.transferFrom, (alice, address(coordinator), usdcAmount))
        });

        calls[1] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), usdcAmount))
        });

        calls[2] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(usdc),
                address(wbtc),
                usdcAmount,
                expectedWbtc
            )
        });

        // 3. Alice creates the swap via the coordinator (Bob is claimAddress)
        vm.prank(alice);
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock, bytes32(0));

        // Verify: USDC left Alice, WBTC is locked in the HTLC
        assertEq(usdc.balanceOf(alice), 40_000e6, "alice should have 40k USDC left");
        assertEq(wbtc.balanceOf(address(htlc)), expectedWbtc, "htlc should hold 1 WBTC");
        assertTrue(
            htlc.isActive(preimageHash, expectedWbtc, address(wbtc), address(coordinator), bob, timelock),
            "swap should be active"
        );

        // 4. Bob claims directly on the HTLC (msg.sender = claimAddress)
        vm.prank(bob);
        htlc.redeem(preimage, expectedWbtc, address(wbtc), address(coordinator), timelock);

        // Verify: Bob received WBTC, HTLC is empty
        assertEq(wbtc.balanceOf(bob), expectedWbtc, "bob should have 1 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertFalse(
            htlc.isActive(preimageHash, expectedWbtc, address(wbtc), address(coordinator), bob, timelock),
            "swap should no longer be active"
        );
    }

    function test_claimWithInvalidPreimage_reverts() public {
        // 1. Alice creates the swap
        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](3);
        calls[0] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.transferFrom, (alice, address(coordinator), usdcAmount))
        });
        calls[1] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), usdcAmount))
        });
        calls[2] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(usdc),
                address(wbtc),
                usdcAmount,
                expectedWbtc
            )
        });

        vm.prank(alice);
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock, bytes32(0));

        // 2. Bob tries to claim with the wrong preimage
        bytes32 wrongPreimage = bytes32(uint256(0xbaadf00d));
        vm.prank(bob);
        vm.expectRevert(HTLCErc20.SwapNotFound.selector);
        htlc.redeem(wrongPreimage, expectedWbtc, address(wbtc), address(coordinator), timelock);

        // Verify: WBTC still locked
        assertEq(wbtc.balanceOf(bob), 0, "bob should still have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), expectedWbtc, "htlc should still hold 1 WBTC");
    }

    function test_executeAndCreate_withRefundCalls_thenRefund() public {
        // 1. Build the refund calls that swap WBTC back to USDC
        HTLCCoordinator.Call[] memory refundCalls = new HTLCCoordinator.Call[](2);

        refundCalls[0] = HTLCCoordinator.Call({
            target: address(wbtc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), expectedWbtc))
        });

        refundCalls[1] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(wbtc),
                address(usdc),
                expectedWbtc,
                usdcAmount
            )
        });

        bytes32 refundCallsHash = keccak256(abi.encode(refundCalls));

        // 2. Alice approves and creates the swap with committed refund calls
        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        HTLCCoordinator.Call[] memory createCalls = new HTLCCoordinator.Call[](3);

        createCalls[0] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.transferFrom, (alice, address(coordinator), usdcAmount))
        });

        createCalls[1] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), usdcAmount))
        });

        createCalls[2] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(usdc),
                address(wbtc),
                usdcAmount,
                expectedWbtc
            )
        });

        vm.prank(alice);
        coordinator.executeAndCreate(createCalls, preimageHash, address(wbtc), bob, timelock, refundCallsHash);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        assertEq(wbtc.balanceOf(address(htlc)), expectedWbtc, "htlc should hold 1 WBTC");

        // 3. Bob never claims — timelock expires
        vm.warp(timelock + 1);

        // 4. Anyone can trigger the refund — swap WBTC back to USDC for Alice
        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        coordinator.refundAndExecute(
            preimageHash,
            expectedWbtc,
            address(wbtc),
            bob,
            timelock,
            refundCalls,
            address(usdc),
            usdcAmount
        );

        // Verify: HTLC is empty, Alice got her USDC back
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + usdcAmount, "alice should have her USDC back");
    }

    function test_executeAndCreate_thenRefundTo_wbtc() public {
        // 1. Alice creates the swap (no refund calls — she'll take the WBTC directly)
        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](3);

        calls[0] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.transferFrom, (alice, address(coordinator), usdcAmount))
        });

        calls[1] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), usdcAmount))
        });

        calls[2] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(usdc),
                address(wbtc),
                usdcAmount,
                expectedWbtc
            )
        });

        vm.prank(alice);
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock, bytes32(0));

        assertEq(wbtc.balanceOf(address(htlc)), expectedWbtc, "htlc should hold 1 WBTC");
        assertEq(wbtc.balanceOf(alice), 0, "alice should have 0 WBTC");

        // 2. Bob never claims — timelock expires
        vm.warp(timelock + 1);

        // 3. Anyone can trigger refundTo — WBTC goes directly to Alice
        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        coordinator.refundTo(preimageHash, expectedWbtc, address(wbtc), bob, timelock);

        // Verify: Alice received the WBTC directly
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertEq(wbtc.balanceOf(alice), expectedWbtc, "alice should have 1 WBTC");
    }
}
