// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";
import {HTLCCoordinator} from "../src/HTLCCoordinator.sol";

contract MockWBTC is ERC20 {
    constructor() ERC20("Wrapped Bitcoin", "WBTC") {
        _mint(msg.sender, 100e8);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

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

/// @notice Tests verifying front-running protection on HTLCErc20 and HTLCCoordinator
contract HTLCFrontRunningProtectionTest is Test {
    HTLCErc20 htlc;
    HTLCCoordinator coordinator;
    MockWBTC wbtc;
    MockUSDC usdc;
    MockDEX dex;

    address alice = makeAddr("alice");

    uint256 bobPk;
    address bob;

    address attacker = makeAddr("attacker");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 wbtcAmount = 1e8;
    uint256 usdcAmount = 60_000e6;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20();
        coordinator = new HTLCCoordinator(address(htlc));
        wbtc = new MockWBTC();
        usdc = new MockUSDC();
        dex = new MockDEX();

        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        wbtc.transfer(alice, 10e8);
        usdc.transfer(address(dex), 500_000e6);
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8);
    }

    // ---------------------------------------------------------------
    // Direct redeem: msg.sender must be claimAddress
    // ---------------------------------------------------------------

    function test_directRedeem_claimAddress_succeeds() public {
        // Alice creates HTLC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Bob (claimAddress) redeems — works
        vm.prank(bob);
        htlc.redeem(preimage, wbtcAmount, address(wbtc), alice, timelock);

        assertEq(wbtc.balanceOf(bob), wbtcAmount, "bob should have 1 WBTC");
    }

    function test_directRedeem_attacker_reverts() public {
        // Alice creates HTLC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Attacker knows the preimage (e.g. from mempool) but is not the claimAddress
        // msg.sender = attacker, but key was created with claimAddress = bob
        vm.prank(attacker);
        vm.expectRevert(HTLCErc20.SwapNotFound.selector);
        htlc.redeem(preimage, wbtcAmount, address(wbtc), alice, timelock);

        // WBTC still locked
        assertEq(wbtc.balanceOf(attacker), 0, "attacker should have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should still hold 1 WBTC");
    }

    // ---------------------------------------------------------------
    // Signature redeem: attacker replays Bob's sig but has wrong msg.sender
    // ---------------------------------------------------------------

    function test_signatureRedeem_authorizedCaller_succeeds() public {
        // Alice creates HTLC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Bob signs for coordinator as the authorized caller, with bob as destination
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, preimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), bob, address(0), 0
        );

        // Coordinator calls redeem — recovers Bob as claimAddress, tokens go to coordinator
        vm.prank(address(coordinator));
        address recovered = htlc.redeemBySig(preimage, wbtcAmount, address(wbtc), alice, timelock, bob, address(0), 0, v, r, s);

        assertEq(recovered, bob, "recovered address should be bob");
        assertEq(wbtc.balanceOf(address(coordinator)), wbtcAmount, "coordinator should have 1 WBTC");
    }

    function test_signatureRedeem_attackerReplaysSignature_reverts() public {
        // Alice creates HTLC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Bob signs for coordinator as the authorized caller, with bob as destination
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, preimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), bob, address(0), 0
        );

        // Attacker replays the same signature but calls from their own address
        // ecrecover will recover a different address because msg.sender is different
        vm.prank(attacker);
        vm.expectRevert(HTLCErc20.SwapNotFound.selector);
        htlc.redeemBySig(preimage, wbtcAmount, address(wbtc), alice, timelock, bob, address(0), 0, v, r, s);

        // WBTC still locked
        assertEq(wbtc.balanceOf(attacker), 0, "attacker should have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should still hold 1 WBTC");
    }

    // ---------------------------------------------------------------
    // Coordinator redeemAndExecute: front-running protection
    // ---------------------------------------------------------------

    function test_coordinatorRedeem_bob_succeeds() public {
        // Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Bob signs EIP-712 authorizing coordinator, with bob as destination
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, preimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), bob, address(usdc), usdcAmount
        );

        // Bob calls coordinator — swap WBTC -> USDC
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
        coordinator.redeemAndExecute(
            preimage, wbtcAmount, address(wbtc), alice, timelock,
            calls, address(usdc), usdcAmount,
            bob,
            v, r, s
        );

        assertEq(usdc.balanceOf(bob), usdcAmount, "bob should have 60k USDC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
    }

    function test_coordinatorRedeem_attackerChangesDestination_reverts() public {
        // Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Bob signs EIP-712 authorizing coordinator with bob as destination
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, preimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), bob, address(wbtc), 0
        );

        // Attacker submits Bob's signature but changes destination to attacker.
        // Since destination is part of the signed EIP-712 message, ecrecover returns
        // a different address → swap key mismatch → revert.
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);

        vm.prank(attacker);
        vm.expectRevert(HTLCErc20.SwapNotFound.selector);
        coordinator.redeemAndExecute(
            preimage, wbtcAmount, address(wbtc), alice, timelock,
            calls, address(wbtc), 0,
            attacker, // wrong destination — not what Bob signed
            v, r, s
        );

        // WBTC still locked
        assertEq(wbtc.balanceOf(attacker), 0, "attacker should have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should still hold 1 WBTC");
    }

    function test_coordinatorRedeem_attackerMakesOwnSignature_reverts() public {
        // Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Attacker creates their own signature (they know the preimage from mempool)
        // but they are not Bob — ecrecover will return attacker's address, not Bob's
        (, uint256 attackerPk) = makeAddrAndKey("attacker");
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            attackerPk, preimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), attacker, address(wbtc), 0
        );

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);

        // The HTLC key includes claimAddress = bob, but ecrecover returns attacker → key mismatch
        vm.prank(attacker);
        vm.expectRevert(HTLCErc20.SwapNotFound.selector);
        coordinator.redeemAndExecute(
            preimage, wbtcAmount, address(wbtc), alice, timelock,
            calls, address(wbtc), 0,
            attacker,
            v, r, s
        );

        // WBTC still locked
        assertEq(wbtc.balanceOf(attacker), 0, "attacker should have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should still hold 1 WBTC");
    }

    // ---------------------------------------------------------------
    // Full flow: create with claimAddress, redeem via coordinator, verify delivery
    // ---------------------------------------------------------------

    function test_fullFlow_createAndRedeemViaCoordinator() public {
        // 1. Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        assertTrue(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock),
            "swap should be active"
        );

        // 2. Bob signs EIP-712 authorizing coordinator, with bob as destination
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, preimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), bob, address(usdc), usdcAmount
        );

        // 3. Bob calls coordinator to redeem and swap WBTC -> USDC
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
        coordinator.redeemAndExecute(
            preimage, wbtcAmount, address(wbtc), alice, timelock,
            calls, address(usdc), usdcAmount,
            bob,
            v, r, s
        );

        // 4. Verify final state
        assertEq(usdc.balanceOf(bob), usdcAmount, "bob should have 60k USDC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertEq(wbtc.balanceOf(address(coordinator)), 0, "coordinator should be empty");
        assertFalse(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock),
            "swap should no longer be active"
        );
    }

    // -- Helpers --

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
}
