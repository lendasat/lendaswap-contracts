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

/// @notice Edge-case and error-path tests for HTLCCoordinator
contract HTLCCoordinatorEdgeCasesTest is Test {
    HTLCErc20 htlc;
    HTLCCoordinator coordinator;
    MockUSDC usdc;
    MockWBTC wbtc;
    MockDEX dex;

    address alice = makeAddr("alice");

    // Bob needs a known private key for EIP-712 signing
    uint256 bobPk;
    address bob;

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 usdcAmount = 60_000e6;
    uint256 wbtcAmount = 1e8;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20();
        coordinator = new HTLCCoordinator(address(htlc), address(0));
        usdc = new MockUSDC();
        wbtc = new MockWBTC();
        dex = new MockDEX();

        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        // Fund alice
        usdc.transfer(alice, 100_000e6);
        wbtc.transfer(alice, 10e8);

        // Fund DEX with liquidity
        wbtc.transfer(address(dex), 50e8);
        usdc.transfer(address(dex), 500_000e6);

        // Configure rates: 60,000 USDC = 1 WBTC
        dex.setRate(address(usdc), address(wbtc), 1e8, 60_000e6);
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8);
    }

    // ---------------------------------------------------------------
    // executeAndCreate overload 2: explicit refundAddress
    // ---------------------------------------------------------------

    function test_executeAndCreate_explicitRefundAddress() public {
        // Relayer executes on behalf of Alice — Alice is the refundAddress
        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        HTLCCoordinator.Call[] memory calls = _buildSwapCalls(
            address(usdc), address(wbtc), alice, usdcAmount, wbtcAmount
        );

        // Relayer calls with Alice as the refund address
        address relayer = makeAddr("relayer");
        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        vm.prank(relayer);
        // overload 2: (calls, preimageHash, token, refundAddress, claimAddress, timelock)
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), alice, bob, timelock);

        // Verify: HTLC created with Alice as sender (refund address)
        assertTrue(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock),
            "swap should be active with alice as sender"
        );

        // Alice can refund directly on the HTLC (no coordinator deposit needed)
        vm.warp(timelock + 1);
        vm.prank(alice);
        htlc.refund(preimageHash, wbtcAmount, address(wbtc), bob, timelock);

        assertEq(wbtc.balanceOf(alice), 10e8 + wbtcAmount, "alice should have her WBTC back");
    }

    // ---------------------------------------------------------------
    // RestrictedTarget
    // ---------------------------------------------------------------

    function test_restrictedTarget_htlc_reverts() public {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(htlc),
            value: 0,
            callData: abi.encodeWithSignature("VERSION()")
        });

        vm.prank(alice);
        vm.expectRevert("Coordinator: restricted target");
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock);
    }

    function test_restrictedTarget_coordinator_reverts() public {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(coordinator),
            value: 0,
            callData: abi.encodeWithSignature("VERSION()")
        });

        vm.prank(alice);
        vm.expectRevert("Coordinator: restricted target");
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock);
    }

    // ---------------------------------------------------------------
    // InsufficientBalance
    // ---------------------------------------------------------------

    function test_executeAndCreate_zeroBalance_reverts() public {
        // Calls that don't produce any WBTC for the coordinator
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);

        vm.prank(alice);
        vm.expectRevert("Coordinator: insufficient balance");
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock);
    }

    function test_redeemAndExecute_minAmountOut_reverts() public {
        // Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        uint256 tooHighMinOut = usdcAmount + 1;

        // Bob signs EIP-712 redeem authorizing the coordinator, with bob as destination
        // Note: minAmountOut is bound to the signature, so Bob commits to tooHighMinOut
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, preimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), bob, address(usdc), tooHighMinOut
        );

        // Bob redeems and swaps, but sets minAmountOut higher than DEX output
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
                address(wbtc), address(usdc), wbtcAmount, usdcAmount
            )
        });

        vm.prank(bob);
        vm.expectRevert("Coordinator: insufficient balance");
        coordinator.redeemAndExecute(
            preimage, wbtcAmount, address(wbtc), alice, timelock,
            calls, address(usdc), tooHighMinOut,
            bob,
            v, r, s
        );
    }

    // ---------------------------------------------------------------
    // UnknownHTLC
    // ---------------------------------------------------------------

    function test_refundAndExecute_unknownHTLC_reverts() public {
        HTLCCoordinator.Call[] memory emptyCalls = new HTLCCoordinator.Call[](0);

        vm.warp(timelock + 1);

        vm.expectRevert("Coordinator: unknown HTLC");
        coordinator.refundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock,
            emptyCalls, address(wbtc), 0
        );
    }

    function test_refundTo_unknownHTLC_reverts() public {
        vm.warp(timelock + 1);

        vm.expectRevert("Coordinator: unknown HTLC");
        coordinator.refundTo(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
    }

    // ---------------------------------------------------------------
    // Unauthorized (refundAndExecute restricted to depositor)
    // ---------------------------------------------------------------

    function test_refundAndExecute_nonDepositor_reverts() public {
        // Alice creates the swap
        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        HTLCCoordinator.Call[] memory calls = _buildSwapCalls(
            address(usdc), address(wbtc), alice, usdcAmount, wbtcAmount
        );

        vm.prank(alice);
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock);

        // Timelock expires
        vm.warp(timelock + 1);

        // Attacker builds malicious calls to steal the refunded tokens
        HTLCCoordinator.Call[] memory maliciousCalls = new HTLCCoordinator.Call[](1);
        address attacker = makeAddr("attacker");
        maliciousCalls[0] = HTLCCoordinator.Call({
            target: address(wbtc),
            value: 0,
            callData: abi.encodeCall(IERC20.transfer, (attacker, wbtcAmount))
        });

        // Attacker calls refundAndExecute — should be rejected
        vm.prank(attacker);
        vm.expectRevert("Coordinator: unauthorized");
        coordinator.refundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock,
            maliciousCalls, address(wbtc), 0
        );

        // Verify: WBTC still locked in HTLC (attacker couldn't steal)
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should still hold WBTC");
        assertEq(wbtc.balanceOf(attacker), 0, "attacker should have 0 WBTC");
    }

    function test_refundAndExecute_depositorSucceeds() public {
        // Alice creates the swap
        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        HTLCCoordinator.Call[] memory calls = _buildSwapCalls(
            address(usdc), address(wbtc), alice, usdcAmount, wbtcAmount
        );

        vm.prank(alice);
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.warp(timelock + 1);

        // Alice (depositor) triggers refundAndExecute — should succeed
        HTLCCoordinator.Call[] memory refundCalls = new HTLCCoordinator.Call[](2);
        refundCalls[0] = HTLCCoordinator.Call({
            target: address(wbtc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), wbtcAmount))
        });
        refundCalls[1] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(wbtc), address(usdc), wbtcAmount, usdcAmount
            )
        });

        vm.prank(alice);
        coordinator.refundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock,
            refundCalls, address(usdc), usdcAmount
        );

        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + usdcAmount, "alice should have USDC back");
    }

    // ---------------------------------------------------------------
    // CallFailed
    // ---------------------------------------------------------------

    function test_executeAndCreate_callFailed_reverts() public {
        // Call a contract with bogus calldata that will revert
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature("nonExistentFunction()")
        });

        vm.prank(alice);
        vm.expectRevert("Coordinator: call failed");
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _signHTLCRedeem(
        uint256 pk,
        bytes32 _preimage,
        uint256 amount,
        address token,
        address sender,
        uint256 _timelock,
        address caller,
        address destination,
        address sweepToken,
        uint256 minAmountOut
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        _preimage, amount, token, sender, _timelock, caller,
                        destination, sweepToken, minAmountOut
                    )
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }

    /// @dev Build the standard 3-call sequence: transferFrom, approve DEX, swap
    function _buildSwapCalls(
        address tokenIn,
        address tokenOut,
        address from,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal view returns (HTLCCoordinator.Call[] memory calls) {
        calls = new HTLCCoordinator.Call[](3);

        calls[0] = HTLCCoordinator.Call({
            target: tokenIn,
            value: 0,
            callData: abi.encodeCall(IERC20.transferFrom, (from, address(coordinator), amountIn))
        });

        calls[1] = HTLCCoordinator.Call({
            target: tokenIn,
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), amountIn))
        });

        calls[2] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                tokenIn, tokenOut, amountIn, minAmountOut
            )
        });
    }
}
