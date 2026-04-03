// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT, SendParam, MessagingFee} from "./interfaces/IOFT.sol";

/// @title USDT0BridgeAdapter
/// @notice Adapter for bridging USDT0 cross-chain via LayerZero's OFT standard.
/// @dev On Arbitrum/Polygon, the USDT0 token and OFT are separate contracts:
///      - Token: the ERC20 (e.g. 0xFd086bC7...on Arbitrum)
///      - OFT:   the OFTAdapter that wraps the token for cross-chain sends
///               (e.g. 0x14E4A1B1...on Arbitrum)
///
///      Flow:
///        1. Coordinator redeems HTLC → TBTC lands in coordinator
///        2. DEX swap: TBTC → USDT0 token (output stays in coordinator)
///        3. Coordinator calls this adapter's `bridgeBalance()` via Call[]
///        4. Adapter pulls USDT0 token, approves OFT, calls OFT send()
///        5. LayerZero delivers USDT0 on destination chain
///
///      LayerZero messaging fees are paid via msg.value forwarded from the
///      coordinator's Call[]. On Arbitrum L2 these are tiny (~$0.001-0.01).
contract USDT0BridgeAdapter {
    using SafeERC20 for IERC20;

    string public constant VERSION = "5";

    // -- Errors --

    error ZeroAmount();
    error ZeroRecipient();
    error InsufficientEthForFee(uint256 required, uint256 available);
    error NotOwner();

    // -- Events --

    event BridgeInitiated(
        uint32 indexed dstEid,
        bytes32 to,
        uint256 amount,
        uint256 nativeFee,
        address indexed caller
    );

    // -- Immutables --

    /// The USDT0 ERC20 token contract.
    IERC20 public immutable USDT0_TOKEN;
    /// The USDT0 OFT/OFTAdapter contract (has quoteSend/send).
    IOFT public immutable USDT0_OFT;
    /// Address that can withdraw accumulated ETH dust.
    address public owner;

    // -- Constructor --

    /// @param usdt0Token Address of the USDT0 ERC20 token on this chain
    /// @param usdt0Oft Address of the USDT0 OFT/OFTAdapter on this chain
    /// @param _owner Address that can withdraw ETH and transfer ownership
    constructor(address usdt0Token, address usdt0Oft, address _owner) {
        USDT0_TOKEN = IERC20(usdt0Token);
        USDT0_OFT = IOFT(usdt0Oft);
        owner = _owner;
    }

    /// @notice Accept ETH (LayerZero refunds excess here).
    receive() external payable {}

    // -- External functions --

    /// @notice Pull the caller's full USDT0 balance and bridge it cross-chain via LayerZero OFT.
    /// @dev Designed for the HTLCCoordinator Call[] flow:
    ///      1. Coordinator calls USDT0.approve(adapter, type(uint256).max)
    ///      2. Coordinator calls adapter.bridgeBalance{value: lzFee}(dstEid, to)
    ///      The adapter reads the caller's USDT0 balance, pulls it via transferFrom,
    ///      approves the OFT to spend it, and sends cross-chain.
    ///      LayerZero fees are paid from msg.value forwarded by the coordinator.
    /// @param dstEid LayerZero endpoint ID of the destination chain
    /// @param to Recipient address on destination chain (left-padded bytes32)
    function bridgeBalance(uint32 dstEid, bytes32 to) external payable {
        if (to == bytes32(0)) revert ZeroRecipient();

        // Pull caller's full USDT0 token balance
        uint256 amount = USDT0_TOKEN.balanceOf(msg.sender);
        if (amount == 0) revert ZeroAmount();

        // Transfer funds from Coordinator contract (msg.sender) into this contract.
        USDT0_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        // Approve the OFT contract to spend tokens (OFTAdapter uses transferFrom internally)
        USDT0_TOKEN.forceApprove(address(USDT0_OFT), amount);

        // Build send parameters: taxi mode (immediate), no compose, 1% slippage tolerance
        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: to,
            amountLD: amount,
            minAmountLD: amount * 99 / 100,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        // Get exact LayerZero fee
        MessagingFee memory fee = USDT0_OFT.quoteSend(sendParam, false);

        if (msg.value < fee.nativeFee) {
            revert InsufficientEthForFee(fee.nativeFee, msg.value);
        }

        // Bridge via OFT — locks token on source, mints on destination.
        // OFT requires msg.value == fee.nativeFee (exact match), so we send
        // exactly the quoteSend fee. Any excess ETH from the coordinator's
        // deterministic estimate stays in the adapter and can be withdrawn.
        USDT0_OFT.send{value: fee.nativeFee}(sendParam, fee, address(this));

        emit BridgeInitiated(dstEid, to, amount, fee.nativeFee, msg.sender);
    }

    // -- Owner functions --

    /// @notice Withdraw accumulated ETH dust from LayerZero fee refunds.
    function withdraw(address to) external {
        if (msg.sender != owner) revert NotOwner();
        (bool success,) = to.call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }

    /// @notice Transfer ownership to a new address.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        owner = newOwner;
    }

    // -- View helpers --

    /// @notice Convert an EVM address to an OFT-compatible bytes32 (left-padded with zeros)
    function addressToBytes32(address addr) external pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @notice Convert an OFT bytes32 back to an EVM address
    function bytes32ToAddress(bytes32 b) external pure returns (address) {
        return address(uint160(uint256(b)));
    }
}
