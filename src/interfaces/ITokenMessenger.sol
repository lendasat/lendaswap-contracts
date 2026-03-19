// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITokenMessenger
/// @notice Interface for Circle's CCTP TokenMessenger contract
/// @dev See https://developers.circle.com/stablecoins/cctp-getting-started
interface ITokenMessenger {
    /// @notice Deposit and burn tokens from sender to be minted on destination domain.
    /// @param amount Amount of tokens to burn (must be > 0)
    /// @param destinationDomain CCTP domain of the destination chain
    /// @param mintRecipient Address on destination domain to receive minted tokens (as bytes32)
    /// @param burnToken Address of the token to burn on this domain
    /// @return nonce Unique nonce reserved by the message
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);

    /// @notice Deposit and burn tokens from sender to be minted on destination domain,
    ///         with a specified caller on the destination domain.
    /// @param amount Amount of tokens to burn
    /// @param destinationDomain CCTP domain of the destination chain
    /// @param mintRecipient Address on destination to receive minted tokens (as bytes32)
    /// @param burnToken Address of the token to burn
    /// @param destinationCaller Address permitted to call receiveMessage on destination (as bytes32).
    ///        If bytes32(0), any address can call.
    /// @return nonce Unique nonce reserved by the message
    function depositForBurnWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external returns (uint64 nonce);

    /// @notice Deposit and burn tokens with a hook on the destination chain (V2).
    ///         When used with the Forwarding Service hookData, Circle automatically
    ///         handles the mint on the destination chain — no gas needed there.
    /// @param amount Amount of tokens to burn (includes fees)
    /// @param destinationDomain CCTP domain of the destination chain
    /// @param mintRecipient Address on destination to receive minted tokens (as bytes32)
    /// @param burnToken Address of the token to burn
    /// @param destinationCaller Address permitted to call receiveMessage on destination (bytes32).
    ///        Use bytes32(0) to allow any caller (required for forwarding service).
    /// @param maxFee Maximum fee (forwarding + protocol) deducted from the amount
    /// @param minFinalityThreshold Finality level: 1000 for fast, 2000 for standard
    /// @param hookData Hook data. For forwarding service use:
    ///        0x636374702d666f72776172640000000000000000000000000000000000000000
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;

    /// @notice Returns the local CCTP message transmitter address
    function localMessageTransmitter() external view returns (address);

    /// @notice Returns the local CCTP minter address
    function localMinter() external view returns (address);
}
