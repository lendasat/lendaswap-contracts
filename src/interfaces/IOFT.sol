// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MessagingFee
/// @notice LayerZero V2 messaging fee structure
struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

/// @title MessagingReceipt
/// @notice Receipt returned after sending a LayerZero message
struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

/// @title SendParam
/// @notice Parameters for OFT cross-chain send
struct SendParam {
    uint32 dstEid;         // Destination LayerZero endpoint ID
    bytes32 to;            // Recipient address (left-padded bytes32)
    uint256 amountLD;      // Amount in local decimals
    uint256 minAmountLD;   // Minimum amount on destination (slippage protection)
    bytes extraOptions;    // Additional LayerZero executor options
    bytes composeMsg;      // Composed message payload (empty for simple transfers)
    bytes oftCmd;          // OFT command: empty = taxi (immediate), bytes(1) = bus (batched)
}

/// @title OFTReceipt
/// @notice Receipt with actual amounts sent/received after fees
struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

/// @title OFTLimit
/// @notice Min/max send limits for the OFT
struct OFTLimit {
    uint256 minAmountLD;
    uint256 maxAmountLD;
}

/// @title OFTFeeDetail
/// @notice Fee breakdown for an OFT send
struct OFTFeeDetail {
    int256 feeAmountLD;
    string description;
}

/// @title IOFT
/// @notice Minimal interface for LayerZero V2 OFT (Omnichain Fungible Token).
/// @dev See https://docs.layerzero.network/v2/developers/evm/oft/quickstart
interface IOFT {
    /// @notice Estimate the messaging fee for a cross-chain send.
    /// @param _sendParam The send parameters
    /// @param _payInLzToken Whether to pay fees in LZ token (false = native gas)
    /// @return msgFee The estimated messaging fee (nativeFee + lzTokenFee)
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken)
        external
        view
        returns (MessagingFee memory msgFee);

    /// @notice Send tokens cross-chain via LayerZero.
    /// @param _sendParam The send parameters
    /// @param _fee The messaging fee (from quoteSend). Excess native fee is refunded.
    /// @param _refundAddress Address to receive excess native fee refund
    /// @return msgReceipt The messaging receipt (guid, nonce, fee)
    /// @return oftReceipt The OFT receipt (amountSent, amountReceived)
    function send(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt);

    /// @notice Whether the OFT requires approval before send().
    /// @dev true for OFTAdapter (lock model), false for OFT (burn model).
    function approvalRequired() external view returns (bool);

    /// @notice The underlying token address.
    /// @dev For OFT: returns address(this). For OFTAdapter: returns the wrapped token.
    function token() external view returns (address);
}
