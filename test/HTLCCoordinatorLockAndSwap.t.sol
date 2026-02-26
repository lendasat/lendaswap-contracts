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

    // Bob needs a known private key for EIP-712 signing
    uint256 bobPk;
    address bob;

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 wbtcAmount = 1e8; // 1 WBTC
    uint256 expectedUsdc = 60_000e6; // 60,000 USDC
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

        // Fund alice with WBTC
        wbtc.transfer(alice, 10e8);

        // Fund the DEX with USDC liquidity
        usdc.transfer(address(dex), 500_000e6);

        // Configure rate: 1 WBTC = 60,000 USDC
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8);
    }

    function test_lockThenRedeemAndSwap() public {
        // 1. Alice locks WBTC in the HTLC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Verify: WBTC moved from Alice to the HTLC
        assertEq(wbtc.balanceOf(alice), 9e8, "alice should have 9 WBTC left");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should hold 1 WBTC");
        assertTrue(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock),
            "swap should be active"
        );

        // 2. Build calls array first so we can compute callsHash for signing
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

        bytes32 callsHash = _computeCallsHash(calls);

        // 3. Bob signs HTLC-level EIP-712 sig authorizing the coordinator, with bob as destination
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, preimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), bob, address(usdc), expectedUsdc, callsHash
        );

        // 4. Bob redeems via coordinator: redeem WBTC, swap WBTC -> USDC, sweep USDC to Bob
        vm.prank(bob);
        coordinator.redeemAndExecute(
            preimage, wbtcAmount, address(wbtc), alice, timelock,
            calls, address(usdc), expectedUsdc,
            bob,
            v, r, s
        );

        // Verify: Bob received USDC, HTLC is empty
        assertEq(usdc.balanceOf(bob), expectedUsdc, "bob should have 60k USDC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertEq(wbtc.balanceOf(address(coordinator)), 0, "coordinator should have no leftover WBTC");
        assertFalse(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock),
            "swap should no longer be active"
        );
    }

    function test_lockThenRedeemWithInvalidPreimage_reverts() public {
        // 1. Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // 2. Bob tries to redeem with wrong preimage — signature will recover a valid
        //    address but the preimage hash won't match any swap
        bytes32 wrongPreimage = bytes32(uint256(0xbaadf00d));
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);
        bytes32 callsHash = _computeCallsHash(calls);
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, wrongPreimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), bob, address(usdc), 0, callsHash
        );

        vm.prank(bob);
        vm.expectRevert("HTLC: swap not found");
        coordinator.redeemAndExecute(
            wrongPreimage, wbtcAmount, address(wbtc), alice, timelock,
            calls, address(usdc), 0,
            bob,
            v, r, s
        );

        // Verify: WBTC still locked
        assertEq(usdc.balanceOf(bob), 0, "bob should still have 0 USDC");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should still hold 1 WBTC");
    }

    function test_lockThenRefund_wbtc() public {
        // 1. Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        assertEq(wbtc.balanceOf(alice), 9e8, "alice should have 9 WBTC left");

        // 2. Bob never claims — timelock expires
        vm.warp(timelock + 1);

        // 3. Alice refunds directly on the HTLC — gets her WBTC back
        vm.prank(alice);
        htlc.refund(preimageHash, wbtcAmount, address(wbtc), bob, timelock);

        // Verify: Alice got her WBTC back
        assertEq(wbtc.balanceOf(alice), 10e8, "alice should have all 10 WBTC back");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertFalse(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock),
            "swap should no longer be active"
        );
    }

    function test_lockThenNonClaimAddressRedeems_reverts() public {
        // 1. Alice locks WBTC directly in the HTLC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // 2. Charlie (not the claimAddress) tries to redeem — should fail
        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        vm.expectRevert("HTLC: swap not found");
        htlc.redeem(preimage, wbtcAmount, address(wbtc), alice, timelock);

        // Verify: WBTC still locked
        assertEq(wbtc.balanceOf(charlie), 0, "charlie should have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc should still hold 1 WBTC");
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
        uint256 minAmountOut,
        bytes32 callsHash
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        _preimage, amount, token, sender, _timelock, caller,
                        destination, sweepToken, minAmountOut, callsHash
                    )
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }

    function _computeCallsHash(HTLCCoordinator.Call[] memory calls) internal pure returns (bytes32 callsHash) {
        bytes memory callsData = abi.encode(calls);
        assembly ("memory-safe") {
            callsHash := keccak256(add(callsData, 0x20), mload(callsData))
        }
    }
}
