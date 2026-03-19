// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenMessenger} from "./interfaces/ITokenMessenger.sol";
import {IMessageTransmitter} from "./interfaces/IMessageTransmitter.sol";

/// @title CCTPBridgeAdapter
/// @notice Adapter for Circle's CCTP that integrates with the HTLCCoordinator call flow.
/// @dev Designed to be called as a `Call` target within HTLCCoordinator's executeAndCreate,
///      redeemAndExecute, or refundAndExecute flows.
///
///      Source chain flow (burn):
///        1. Coordinator redeems HTLC → USDC lands in coordinator
///        2. Coordinator calls this adapter's `bridge()` via Call[]
///        3. Adapter burns USDC via CCTP TokenMessenger
///        4. Off-chain service fetches attestation from Circle
///        5. Attestation submitted on destination chain to mint USDC
///
///      Destination chain flow (mint + optional forward):
///        Off-chain service calls MessageTransmitter.receiveMessage() directly,
///        or calls this adapter's `receiveAndForward()` to mint + forward in one tx.
contract CCTPBridgeAdapter {
    using SafeERC20 for IERC20;

    // -- Errors --

    error ZeroAmount();
    error ZeroRecipient();

    // -- Events --

    event BridgeInitiated(
        uint64 indexed nonce,
        uint32 indexed destinationDomain,
        bytes32 mintRecipient,
        uint256 amount,
        address indexed caller
    );

    event BridgeReceived(
        bytes32 indexed messageHash,
        address recipient,
        uint256 amount
    );

    // -- Immutables --

    ITokenMessenger public immutable TOKEN_MESSENGER;
    IMessageTransmitter public immutable MESSAGE_TRANSMITTER;
    address public immutable USDC;

    // -- CCTP Domain Constants --
    // These are Circle's canonical domain IDs for CCTP

    uint32 public constant DOMAIN_ETHEREUM = 0;
    uint32 public constant DOMAIN_AVALANCHE = 1;
    uint32 public constant DOMAIN_OPTIMISM = 2;
    uint32 public constant DOMAIN_ARBITRUM = 3;
    uint32 public constant DOMAIN_BASE = 6;
    uint32 public constant DOMAIN_POLYGON = 7;
    uint32 public constant DOMAIN_SOLANA = 5;

    // -- Constructor --

    /// @param tokenMessenger Address of Circle's TokenMessenger on this chain
    /// @param messageTransmitter Address of Circle's MessageTransmitter on this chain
    /// @param usdc Address of USDC on this chain
    constructor(address tokenMessenger, address messageTransmitter, address usdc) {
        TOKEN_MESSENGER = ITokenMessenger(tokenMessenger);
        MESSAGE_TRANSMITTER = IMessageTransmitter(messageTransmitter);
        USDC = usdc;
    }

    // -- External functions --

    /// @notice Burn USDC via CCTP to bridge to a destination chain.
    ///         Designed to be called by the HTLCCoordinator as part of a Call[] sequence.
    /// @dev The caller must have transferred USDC to this contract (or approved it) before calling.
    ///      When used within HTLCCoordinator.redeemAndExecute, the coordinator holds the USDC
    ///      after redeem and uses a prior Call to transfer/approve USDC to this adapter.
    /// @param amount Amount of USDC to bridge
    /// @param destinationDomain CCTP domain ID of the destination chain
    /// @param mintRecipient Recipient address on destination chain (left-padded bytes32)
    /// @return nonce The CCTP message nonce (used to fetch attestation)
    function bridge(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient
    ) external returns (uint64 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (mintRecipient == bytes32(0)) revert ZeroRecipient();

        // Pull USDC from caller
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);

        // Approve TokenMessenger to burn
        IERC20(USDC).forceApprove(address(TOKEN_MESSENGER), amount);

        // Initiate CCTP burn
        nonce = TOKEN_MESSENGER.depositForBurn(
            amount,
            destinationDomain,
            mintRecipient,
            USDC
        );

        emit BridgeInitiated(nonce, destinationDomain, mintRecipient, amount, msg.sender);
    }

    /// @notice Burn USDC via CCTP with a restricted destination caller.
    ///         Only the specified destinationCaller can receive the message on the destination chain.
    /// @param amount Amount of USDC to bridge
    /// @param destinationDomain CCTP domain ID of the destination chain
    /// @param mintRecipient Recipient address on destination chain (left-padded bytes32)
    /// @param destinationCaller Address authorized to call receiveMessage on destination (bytes32).
    ///        Use bytes32(0) to allow any caller.
    /// @return nonce The CCTP message nonce
    function bridgeWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller
    ) external returns (uint64 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (mintRecipient == bytes32(0)) revert ZeroRecipient();

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(USDC).forceApprove(address(TOKEN_MESSENGER), amount);

        nonce = TOKEN_MESSENGER.depositForBurnWithCaller(
            amount,
            destinationDomain,
            mintRecipient,
            USDC,
            destinationCaller
        );

        emit BridgeInitiated(nonce, destinationDomain, mintRecipient, amount, msg.sender);
    }

    /// @notice Pull the caller's full USDC allowance and bridge it via CCTP V2 with
    ///         Circle's Forwarding Service (gasless on destination chain).
    /// @dev Designed for the HTLCCoordinator Call[] flow:
    ///      1. Coordinator calls USDC.approve(adapter, type(uint256).max)
    ///      2. Coordinator calls adapter.bridgeBalance(destDomain, recipient)
    ///      The adapter reads the caller's USDC balance, pulls it via transferFrom,
    ///      and burns it via depositForBurnWithHook with forwarding service hookData.
    ///      The transferFrom happens inside this contract (not in the coordinator's
    ///      calldata), so it bypasses the coordinator's dangerous-selector check.
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

        emit BridgeInitiated(0, destinationDomain, mintRecipient, amount, msg.sender);
    }

    /// @notice Convenience: receive a CCTP message (minting USDC) and forward to a recipient
    ///         in a single transaction.
    /// @dev Calls MessageTransmitter.receiveMessage which mints USDC to this contract,
    ///      then forwards the minted amount to the specified recipient.
    ///      The mintRecipient in the original burn must be set to this adapter's address.
    /// @param message The full CCTP message bytes
    /// @param attestation The Circle attestation signature(s)
    /// @param recipient Final recipient of the minted USDC
    /// @param expectedAmount Expected USDC amount (for safety check)
    function receiveAndForward(
        bytes calldata message,
        bytes calldata attestation,
        address recipient,
        uint256 expectedAmount
    ) external {
        uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));

        MESSAGE_TRANSMITTER.receiveMessage(message, attestation);

        uint256 received = IERC20(USDC).balanceOf(address(this)) - balanceBefore;
        require(received >= expectedAmount, "CCTPBridgeAdapter: insufficient mint");

        IERC20(USDC).safeTransfer(recipient, received);

        emit BridgeReceived(keccak256(message), recipient, received);
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
