// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {DeployPermit2} from "../lib/permit2/test/utils/DeployPermit2.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";
import {HTLCCoordinator} from "../src/HTLCCoordinator.sol";

contract MockUSDC is ERC20, ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {
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

contract MockDEX {
    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }
    mapping(bytes32 => Rate) public rates;

    function setRate(address tokenIn, address tokenOut, uint256 numerator, uint256 denominator) external {
        rates[keccak256(abi.encodePacked(tokenIn, tokenOut))] = Rate(numerator, denominator);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        Rate memory rate = rates[keccak256(abi.encodePacked(tokenIn, tokenOut))];
        amountOut = (amountIn * rate.numerator) / rate.denominator;
        require(amountOut >= minAmountOut, "MockDEX: slippage");
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

/// @notice Tests for collaborative refund (pre-timelock refund with claimAddress signature)
contract HTLCCollabRefundTest is Test {
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant PERMIT2_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    HTLCErc20 htlc;
    HTLCCoordinator coordinator;
    ISignatureTransfer permit2;
    MockUSDC usdc;
    MockWBTC wbtc;
    MockDEX dex;

    // Alice = depositor (client), needs known private key for EIP-712 signing
    uint256 alicePk;
    address alice;

    // Bob = claimAddress (server), needs known private key for EIP-712 signing
    uint256 bobPk;
    address bob;

    // Relay = anyone submitting the tx (server in production)
    address relay = makeAddr("relay");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 usdcAmount = 60_000e6;
    uint256 wbtcAmount = 1e8;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20();
        permit2 = ISignatureTransfer(new DeployPermit2().deployPermit2());
        coordinator = new HTLCCoordinator(address(htlc), address(permit2));
        usdc = new MockUSDC();
        wbtc = new MockWBTC();
        dex = new MockDEX();

        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        // Fund alice and DEX
        usdc.transfer(alice, 100_000e6);
        wbtc.transfer(alice, 10e8);
        wbtc.transfer(address(dex), 50e8);
        usdc.transfer(address(dex), 500_000e6);

        dex.setRate(address(usdc), address(wbtc), 1e8, 60_000e6);
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8);

        // Alice approves Permit2 for USDC
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);
    }

    // ---------------------------------------------------------------
    // HTLCErc20.refundBySig — direct HTLC-level collaborative refund
    // ---------------------------------------------------------------

    function test_refundBySig_basic() public {
        // Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Bob signs refundBySig (waiving timelock), authorizing relay as caller
        // destination=alice, sweepToken=wbtc, minAmountOut=0
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(
            bobPk, preimageHash, wbtcAmount, address(wbtc), alice, timelock, relay, alice, address(wbtc), 0
        );

        // Relay calls refundBySig — tokens go to relay (msg.sender)
        vm.prank(relay);
        address recovered = htlc.refundBySig(
            preimageHash, wbtcAmount, address(wbtc), alice, timelock, alice, address(wbtc), 0, v, r, s
        );

        assertEq(recovered, bob, "should recover bob as claimAddress");
        assertEq(wbtc.balanceOf(relay), wbtcAmount, "relay should have the WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertFalse(htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock));
    }

    function test_refundBySig_beforeTimelock() public {
        // Verify it works BEFORE timelock (the whole point)
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Don't warp — still before timelock
        assertLt(block.timestamp, timelock, "should be before timelock");

        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(
            bobPk, preimageHash, wbtcAmount, address(wbtc), alice, timelock, relay, alice, address(wbtc), 0
        );

        vm.prank(relay);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), alice, timelock, alice, address(wbtc), 0, v, r, s);

        assertEq(wbtc.balanceOf(relay), wbtcAmount, "should succeed before timelock");
    }

    function test_refundBySig_wrongSigner_reverts() public {
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Alice signs instead of Bob — wrong signer (alice is refundAddress, not claimAddress)
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(
            alicePk, preimageHash, wbtcAmount, address(wbtc), alice, timelock, relay, alice, address(wbtc), 0
        );

        vm.prank(relay);
        vm.expectRevert("HTLC: swap not found");
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), alice, timelock, alice, address(wbtc), 0, v, r, s);
    }

    function test_refundBySig_wrongCaller_reverts() public {
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        // Signed for relay, but alice calls
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(
            bobPk, preimageHash, wbtcAmount, address(wbtc), alice, timelock, relay, alice, address(wbtc), 0
        );

        vm.prank(alice); // wrong caller
        vm.expectRevert("HTLC: swap not found");
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), alice, timelock, alice, address(wbtc), 0, v, r, s);
    }

    // ---------------------------------------------------------------
    // Coordinator.collabRefundAndExecute — direct refund (no calls)
    // ---------------------------------------------------------------

    function test_collabRefundAndExecute_direct() public {
        // Alice funds via coordinator (swap-and-lock)
        _aliceSwapAndLock();

        // Both sign for collabRefundAndExecute (sweepToken=wbtc, minAmountOut=0)
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);
        bytes32 callsHash = _computeCallsHash(calls);

        (uint8 dV, bytes32 dR, bytes32 dS) = _signCollabRefund(
            alicePk, preimageHash, wbtcAmount, address(wbtc), bob, timelock, relay, address(wbtc), 0, callsHash
        );
        (uint8 cV, bytes32 cR, bytes32 cS) = _signHTLCRefund(
            bobPk,
            preimageHash,
            wbtcAmount,
            address(wbtc),
            address(coordinator),
            timelock,
            address(coordinator),
            alice,
            address(wbtc),
            0
        );
        uint256 aliceBefore = wbtc.balanceOf(alice);

        vm.prank(relay);
        coordinator.collabRefundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock, calls, address(wbtc), 0, dV, dR, dS, cV, cR, cS
        );

        assertEq(wbtc.balanceOf(alice), aliceBefore + wbtcAmount, "alice should get WBTC back");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertEq(wbtc.balanceOf(address(coordinator)), 0, "coordinator should be empty");
    }

    function test_collabRefundAndExecute_direct_beforeTimelock() public {
        _aliceSwapAndLock();

        assertLt(block.timestamp, timelock, "should be before timelock");

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);
        bytes32 callsHash = _computeCallsHash(calls);

        (uint8 dV, bytes32 dR, bytes32 dS) = _signCollabRefund(
            alicePk, preimageHash, wbtcAmount, address(wbtc), bob, timelock, relay, address(wbtc), 0, callsHash
        );
        (uint8 cV, bytes32 cR, bytes32 cS) = _signHTLCRefund(
            bobPk,
            preimageHash,
            wbtcAmount,
            address(wbtc),
            address(coordinator),
            timelock,
            address(coordinator),
            alice,
            address(wbtc),
            0
        );

        vm.prank(relay);
        coordinator.collabRefundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock, calls, address(wbtc), 0, dV, dR, dS, cV, cR, cS
        );

        assertEq(wbtc.balanceOf(address(htlc)), 0, "should succeed before timelock");
    }

    // ---------------------------------------------------------------
    // Coordinator.collabRefundAndExecute — with DEX swap-back
    // ---------------------------------------------------------------

    function test_collabRefundAndExecute_swapBack() public {
        _aliceSwapAndLock();

        // Server takes fee + swaps WBTC -> USDC for alice
        uint256 fee = 1000; // 0.00001000 WBTC
        uint256 swapAmount = wbtcAmount - fee;
        uint256 expectedUsdc = (swapAmount * 60_000e6) / 1e8;

        // Build calls: fee skim + approve + DEX swap
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](3);
        calls[0] = HTLCCoordinator.Call({
            target: address(wbtc), value: 0, callData: abi.encodeCall(IERC20.transfer, (relay, fee))
        });
        calls[1] = HTLCCoordinator.Call({
            target: address(wbtc), value: 0, callData: abi.encodeCall(IERC20.approve, (address(dex), swapAmount))
        });
        calls[2] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)", address(wbtc), address(usdc), swapAmount, 0
            )
        });

        bytes32 callsHash = _computeCallsHash(calls);

        (uint8 dV, bytes32 dR, bytes32 dS) = _signCollabRefund(
            alicePk, preimageHash, wbtcAmount, address(wbtc), bob, timelock, relay, address(usdc), 0, callsHash
        );
        (uint8 cV, bytes32 cR, bytes32 cS) = _signHTLCRefund(
            bobPk,
            preimageHash,
            wbtcAmount,
            address(wbtc),
            address(coordinator),
            timelock,
            address(coordinator),
            alice,
            address(usdc),
            0
        );

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(relay);
        coordinator.collabRefundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock, calls, address(usdc), 0, dV, dR, dS, cV, cR, cS
        );

        assertEq(wbtc.balanceOf(relay), fee, "relay should get fee");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + expectedUsdc, "alice should get USDC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertEq(wbtc.balanceOf(address(coordinator)), 0, "coordinator should be empty");
    }

    function test_collabRefundAndExecute_feeOnly() public {
        _aliceSwapAndLock();

        // Just fee skim, no DEX swap — client gets WBTC minus fee
        uint256 fee = 1000;

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(wbtc), value: 0, callData: abi.encodeCall(IERC20.transfer, (relay, fee))
        });

        bytes32 callsHash = _computeCallsHash(calls);

        (uint8 dV, bytes32 dR, bytes32 dS) = _signCollabRefund(
            alicePk, preimageHash, wbtcAmount, address(wbtc), bob, timelock, relay, address(wbtc), 0, callsHash
        );
        (uint8 cV, bytes32 cR, bytes32 cS) = _signHTLCRefund(
            bobPk,
            preimageHash,
            wbtcAmount,
            address(wbtc),
            address(coordinator),
            timelock,
            address(coordinator),
            alice,
            address(wbtc),
            0
        );

        uint256 aliceBefore = wbtc.balanceOf(alice);

        vm.prank(relay);
        coordinator.collabRefundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock, calls, address(wbtc), 0, dV, dR, dS, cV, cR, cS
        );

        assertEq(wbtc.balanceOf(relay), fee, "relay should get fee");
        assertEq(wbtc.balanceOf(alice), aliceBefore + wbtcAmount - fee, "alice should get WBTC minus fee");
    }

    // ---------------------------------------------------------------
    // Error cases
    // ---------------------------------------------------------------

    function test_collabRefundAndExecute_unknownHTLC_reverts() public {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);
        bytes32 callsHash = _computeCallsHash(calls);

        (uint8 dV, bytes32 dR, bytes32 dS) = _signCollabRefund(
            alicePk, preimageHash, wbtcAmount, address(wbtc), bob, timelock, relay, address(wbtc), 0, callsHash
        );
        (uint8 cV, bytes32 cR, bytes32 cS) = _signHTLCRefund(
            bobPk,
            preimageHash,
            wbtcAmount,
            address(wbtc),
            address(coordinator),
            timelock,
            address(coordinator),
            alice,
            address(wbtc),
            0
        );

        vm.prank(relay);
        vm.expectRevert("Coordinator: unknown HTLC");
        coordinator.collabRefundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock, calls, address(wbtc), 0, dV, dR, dS, cV, cR, cS
        );
    }

    function test_collabRefundAndExecute_wrongDepositorSig_reverts() public {
        _aliceSwapAndLock();

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);
        bytes32 callsHash = _computeCallsHash(calls);

        // Bob signs the depositor sig (wrong — alice is depositor)
        (uint8 dV, bytes32 dR, bytes32 dS) = _signCollabRefund(
            bobPk, preimageHash, wbtcAmount, address(wbtc), bob, timelock, relay, address(wbtc), 0, callsHash
        );
        (uint8 cV, bytes32 cR, bytes32 cS) = _signHTLCRefund(
            bobPk,
            preimageHash,
            wbtcAmount,
            address(wbtc),
            address(coordinator),
            timelock,
            address(coordinator),
            alice,
            address(wbtc),
            0
        );

        vm.prank(relay);
        vm.expectRevert("Coordinator: invalid depositor signature");
        coordinator.collabRefundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock, calls, address(wbtc), 0, dV, dR, dS, cV, cR, cS
        );
    }

    function test_collabRefundAndExecute_wrongClaimSig_reverts() public {
        _aliceSwapAndLock();

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);
        bytes32 callsHash = _computeCallsHash(calls);

        (uint8 dV, bytes32 dR, bytes32 dS) = _signCollabRefund(
            alicePk, preimageHash, wbtcAmount, address(wbtc), bob, timelock, relay, address(wbtc), 0, callsHash
        );
        // Alice signs the claim sig (wrong — bob is claimAddress)
        (uint8 cV, bytes32 cR, bytes32 cS) = _signHTLCRefund(
            alicePk,
            preimageHash,
            wbtcAmount,
            address(wbtc),
            address(coordinator),
            timelock,
            address(coordinator),
            alice,
            address(wbtc),
            0
        );

        vm.prank(relay);
        vm.expectRevert("HTLC: swap not found");
        coordinator.collabRefundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock, calls, address(wbtc), 0, dV, dR, dS, cV, cR, cS
        );
    }

    function test_collabRefund_doubleSpend_reverts() public {
        _aliceSwapAndLock();

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);
        bytes32 callsHash = _computeCallsHash(calls);

        (uint8 dV, bytes32 dR, bytes32 dS) = _signCollabRefund(
            alicePk, preimageHash, wbtcAmount, address(wbtc), bob, timelock, relay, address(wbtc), 0, callsHash
        );
        (uint8 cV, bytes32 cR, bytes32 cS) = _signHTLCRefund(
            bobPk,
            preimageHash,
            wbtcAmount,
            address(wbtc),
            address(coordinator),
            timelock,
            address(coordinator),
            alice,
            address(wbtc),
            0
        );

        vm.prank(relay);
        coordinator.collabRefundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock, calls, address(wbtc), 0, dV, dR, dS, cV, cR, cS
        );

        // Try again — should fail (deposit already cleared)
        vm.prank(relay);
        vm.expectRevert("Coordinator: unknown HTLC");
        coordinator.collabRefundAndExecute(
            preimageHash, wbtcAmount, address(wbtc), bob, timelock, calls, address(wbtc), 0, dV, dR, dS, cV, cR, cS
        );
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @dev Alice does executeAndCreateWithPermit2: USDC -> DEX swap -> WBTC, lock with bob as claimAddress
    function _aliceSwapAndLock() internal {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](2);
        calls[0] = HTLCCoordinator.Call({
            target: address(usdc), value: 0, callData: abi.encodeCall(IERC20.approve, (address(dex), usdcAmount))
        });
        calls[1] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)", address(usdc), address(wbtc), usdcAmount, wbtcAmount
            )
        });

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, 0, calls);

        vm.prank(alice);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );
    }

    function _signPermit2(
        address token,
        uint256 amount,
        uint256 nonce,
        HTLCCoordinator.Call[] memory calls
    ) internal view returns (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) {
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });

        bytes32 witness = _computeWitness(preimageHash, address(wbtc), bob, address(coordinator), timelock, calls);
        signature = _signPermit2WitnessTransfer(permit, witness, alicePk);
    }

    function _computeWitness(
        bytes32 _preimageHash,
        address token,
        address claimAddress,
        address refundAddress,
        uint256 _timelock,
        HTLCCoordinator.Call[] memory calls
    ) internal view returns (bytes32 witness) {
        bytes32 callsHash;
        {
            bytes memory callsData = abi.encode(calls);
            assembly ("memory-safe") {
                callsHash := keccak256(add(callsData, 0x20), mload(callsData))
            }
        }

        bytes32 typeHash = coordinator.TYPEHASH_EXECUTE_AND_CREATE();
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), _preimageHash)
            mstore(add(ptr, 0x40), token)
            mstore(add(ptr, 0x60), claimAddress)
            mstore(add(ptr, 0x80), refundAddress)
            mstore(add(ptr, 0xa0), _timelock)
            mstore(add(ptr, 0xc0), callsHash)
            witness := keccak256(ptr, 0xe0)
            mstore(0x40, add(ptr, 0xe0))
        }
    }

    function _signPermit2WitnessTransfer(
        ISignatureTransfer.PermitTransferFrom memory permit,
        bytes32 witness,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 typehash = keccak256(
            abi.encodePacked(PERMIT2_WITNESS_TYPEHASH_STUB, coordinator.TYPESTRING_EXECUTE_AND_CREATE())
        );
        bytes32 tokenPermissionsHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permit2.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        typehash, tokenPermissionsHash, address(coordinator), permit.nonce, permit.deadline, witness
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function _computeCallsHash(HTLCCoordinator.Call[] memory calls) internal pure returns (bytes32) {
        bytes memory callsData = abi.encode(calls);
        return keccak256(callsData);
    }

    function _signHTLCRefund(
        uint256 pk,
        bytes32 _preimageHash,
        uint256 amount,
        address token,
        address refundAddress,
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
                        htlc.TYPEHASH_REFUND(),
                        _preimageHash,
                        amount,
                        token,
                        refundAddress,
                        _timelock,
                        caller,
                        destination,
                        sweepToken,
                        minAmountOut
                    )
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }

    function _signCollabRefund(
        uint256 pk,
        bytes32 _preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 _timelock,
        address caller,
        address sweepToken,
        uint256 minAmountOut,
        bytes32 callsHash
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                coordinator.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        coordinator.TYPEHASH_COLLAB_REFUND(),
                        _preimageHash,
                        amount,
                        token,
                        claimAddress,
                        _timelock,
                        caller,
                        sweepToken,
                        minAmountOut,
                        callsHash
                    )
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }
}
