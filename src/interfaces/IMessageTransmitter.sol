// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMessageTransmitter
/// @notice Interface for Circle's CCTP MessageTransmitter contract
/// @dev Used on the destination chain to receive and process cross-chain messages
interface IMessageTransmitter {
    /// @notice Receive a message. Messages with a non-zero destination caller can only
    ///         be received by that caller.
    /// @param message The full CCTP message body
    /// @param attestation Concatenated 65-byte signatures from Circle attesters
    /// @return success True if the message was received successfully
    function receiveMessage(bytes calldata message, bytes calldata attestation)
        external
        returns (bool success);

    /// @notice Returns the domain of this MessageTransmitter
    function localDomain() external view returns (uint32);
}
