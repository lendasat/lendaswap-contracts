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
        coordinator = new HTLCCoordinator(address(htlc));
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
        vm.expectRevert(HTLCCoordinator.RestrictedTarget.selector);
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock, bytes32(0));
    }

    function test_restrictedTarget_coordinator_reverts() public {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(coordinator),
            value: 0,
            callData: abi.encodeWithSignature("VERSION()")
        });

        vm.prank(alice);
        vm.expectRevert(HTLCCoordinator.RestrictedTarget.selector);
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock, bytes32(0));
    }

    // ---------------------------------------------------------------
    // InsufficientBalance
    // ---------------------------------------------------------------

    function test_executeAndCreate_zeroBalance_reverts() public {
        // Calls that don't produce any WBTC for the coordinator
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);

        vm.prank(alice);
        vm.expectRevert(HTLCCoordinator.InsufficientBalance.selector);
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock, bytes32(0));
    }

    function test_redeemAndExecute_minAmountOut_reverts() public {
        // Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Bob signs EIP-712 redeem authorizing the coordinator
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, preimage, wbtcAmount, address(wbtc), alice, timelock, address(coordinator)
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

        uint256 tooHighMinOut = usdcAmount + 1;

        vm.prank(bob);
        vm.expectRevert(HTLCCoordinator.InsufficientBalance.selector);
        coordinator.redeemAndExecute(
            preimage, wbtcAmount, address(wbtc), alice, timelock,
            calls, address(usdc), tooHighMinOut,
            v, r, s
        );
    }

    // ---------------------------------------------------------------
    // RefundCallsMismatch
    // ---------------------------------------------------------------

    function test_refundAndExecute_mismatchedCalls_reverts() public {
        // Create with committed refund calls
        HTLCCoordinator.Call[] memory refundCalls = new HTLCCoordinator.Call[](1);
        refundCalls[0] = HTLCCoordinator.Call({
            target: address(wbtc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), wbtcAmount))
        });
        bytes32 refundCallsHash = keccak256(abi.encode(refundCalls));

        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        HTLCCoordinator.Call[] memory createCalls = _buildSwapCalls(
            address(usdc), address(wbtc), alice, usdcAmount, wbtcAmount
        );

        vm.prank(alice);
        coordinator.executeAndCreate(createCalls, preimageHash, address(wbtc), bob, timelock, refundCallsHash);

        vm.warp(timelock + 1);

        // Try to refund with different calls
        HTLCCoordinator.Call[] memory wrongCalls = new HTLCCoordinator.Call[](1);
        wrongCalls[0] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), usdcAmount))
        });

        vm.expectRevert(HTLCCoordinator.RefundCallsMismatch.selector);
        coordinator.refundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock,
            wrongCalls, address(wbtc), 0
        );
    }

    function test_refundAndExecute_callsWhenNoneCommitted_reverts() public {
        // Create with refundCallsHash = bytes32(0) (no calls committed)
        vm.prank(alice);
        usdc.approve(address(coordinator), usdcAmount);

        HTLCCoordinator.Call[] memory createCalls = _buildSwapCalls(
            address(usdc), address(wbtc), alice, usdcAmount, wbtcAmount
        );

        vm.prank(alice);
        coordinator.executeAndCreate(createCalls, preimageHash, address(wbtc), bob, timelock, bytes32(0));

        vm.warp(timelock + 1);

        // Try to refund with calls even though none were committed
        HTLCCoordinator.Call[] memory unexpectedCalls = new HTLCCoordinator.Call[](1);
        unexpectedCalls[0] = HTLCCoordinator.Call({
            target: address(wbtc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), wbtcAmount))
        });

        vm.expectRevert(HTLCCoordinator.RefundCallsMismatch.selector);
        coordinator.refundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock,
            unexpectedCalls, address(wbtc), 0
        );
    }

    // ---------------------------------------------------------------
    // UnknownHTLC
    // ---------------------------------------------------------------

    function test_refundAndExecute_unknownHTLC_reverts() public {
        HTLCCoordinator.Call[] memory emptyCalls = new HTLCCoordinator.Call[](0);

        vm.warp(timelock + 1);

        vm.expectRevert(HTLCCoordinator.UnknownHTLC.selector);
        coordinator.refundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock,
            emptyCalls, address(wbtc), 0
        );
    }

    function test_refundTo_unknownHTLC_reverts() public {
        vm.warp(timelock + 1);

        vm.expectRevert(HTLCCoordinator.UnknownHTLC.selector);
        coordinator.refundTo(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
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
        vm.expectRevert(abi.encodeWithSelector(HTLCCoordinator.CallFailed.selector, 0));
        coordinator.executeAndCreate(calls, preimageHash, address(wbtc), bob, timelock, bytes32(0));
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
        address caller
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        _preimage, amount, token, sender, _timelock, caller
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
