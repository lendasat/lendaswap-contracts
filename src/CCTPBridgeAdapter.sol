// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenMessenger} from "./interfaces/ITokenMessenger.sol";

/// @title CCTPBridgeAdapter
/// @notice Adapter for Circle's CCTP V2 that integrates with the HTLCCoordinator call flow.
/// @dev Designed to be called as a `Call` target within HTLCCoordinator's executeAndCreate,
///      redeemAndExecute, or refundAndExecute flows.
///
///      Flow:
///        1. Coordinator redeems HTLC → USDC lands in coordinator
///        2. Coordinator calls this adapter's `bridgeBalance()` via Call[]
///        3. Adapter pulls USDC from coordinator and burns via CCTP V2 with Forwarding Service
///        4. Circle automatically mints on destination chain — no gas needed there
contract CCTPBridgeAdapter {
    using SafeERC20 for IERC20;

    string public constant VERSION = "2";

    // -- Errors --

    error ZeroAmount();
    error ZeroRecipient();

    // -- Events --

    event BridgeInitiated(
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 amount,
        address indexed caller
    );

    // -- Immutables --

    ITokenMessenger public immutable TOKEN_MESSENGER;
    address public immutable USDC;

    // -- Constructor --

    /// @param tokenMessenger Address of Circle's TokenMessenger V2 on this chain
    /// @param usdc Address of USDC on this chain
    constructor(address tokenMessenger, address usdc) {
        TOKEN_MESSENGER = ITokenMessenger(tokenMessenger);
        USDC = usdc;
    }

    // -- External functions --

    /// @notice Pull the caller's full USDC allowance and bridge it via CCTP V2 with
    ///         Circle's Forwarding Service (gasless on destination chain).
    /// @dev Designed for the HTLCCoordinator Call[] flow:
    ///      1. Coordinator calls USDC.approve(adapter, type(uint256).max)
    ///      2. Coordinator calls adapter.bridgeBalance(destDomain, recipient, maxFee)
    ///      The adapter reads the caller's USDC balance, pulls it via transferFrom,
    ///      and burns it via depositForBurnWithHook with forwarding service hookData.
    /// @param destinationDomain CCTP domain ID of the destination chain
    /// @param mintRecipient Recipient address on destination chain (left-padded bytes32)
    /// @param maxFee Maximum CCTP forwarding fee in USDC units (fetched from IRIS API)
    function bridgeBalance(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee
    ) external {
        if (mintRecipient == bytes32(0)) revert ZeroRecipient();

        // Pull caller's full USDC balance
        uint256 amount = IERC20(USDC).balanceOf(msg.sender);
        if (amount == 0) revert ZeroAmount();

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);

        // Approve TokenMessenger V2
        IERC20(USDC).forceApprove(address(TOKEN_MESSENGER), amount);

        // Forwarding service hookData: "cctp-forward" + version 0 + data length 0
        bytes memory hookData = hex"636374702d666f72776172640000000000000000000000000000000000000000";

        // Burn via CCTP V2 with forwarding service — Circle auto-mints on destination
        TOKEN_MESSENGER.depositForBurnWithHook(
            amount,
            destinationDomain,
            mintRecipient,
            USDC,
            bytes32(0),     // destinationCaller: allow any (required for forwarding)
            maxFee,
            1000,           // minFinalityThreshold: fast transfer
            hookData
        );

        emit BridgeInitiated(destinationDomain, mintRecipient, amount, msg.sender);
    }

    // -- View helpers --

    /// @notice Convert an EVM address to a CCTP-compatible bytes32 (left-padded with zeros)
    /// @param addr The EVM address to convert
    /// @return The bytes32 representation
    function addressToBytes32(address addr) external pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @notice Convert a CCTP bytes32 back to an EVM address
    /// @param b The bytes32 to convert
    /// @return The EVM address
    function bytes32ToAddress(bytes32 b) external pure returns (address) {
        return address(uint160(uint256(b)));
    }
}
