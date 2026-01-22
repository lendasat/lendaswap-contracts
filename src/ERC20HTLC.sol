// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20HTLC - Hash Time Locked Contract for ERC20 Token Atomic Swaps
/// @notice Enables atomic swaps for any ERC20 token (e.g., WBTC)
/// @dev Uses ERC-2771 for meta-transactions (gasless execution) and HTLCs for atomic swaps
/// @dev Can be used for both directions: BTC→ERC20 or ERC20→BTC
contract ERC20HTLC is ERC2771Context, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Contract version for identification
    string public constant VERSION = "1.0.0";

    // Events
    event SwapCreated(
        bytes32 indexed swapId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes32 hashLock,
        uint256 timelock
    );
    event SwapClaimed(bytes32 indexed swapId, bytes32 secret);
    event SwapRefunded(bytes32 indexed swapId);

    // Swap states
    enum SwapState {
        INVALID,
        OPEN,
        CLAIMED,
        REFUNDED
    }

    // Swap structure
    struct Swap {
        address sender;
        address recipient;
        address token;
        uint256 amount;
        bytes32 hashLock;
        uint256 timelock;
        SwapState state;
    }

    // State variables
    mapping(bytes32 => Swap) public swaps;

    /// @notice Constructor
    /// @param _trustedForwarder ERC-2771 trusted forwarder for meta-transactions
    constructor(address _trustedForwarder) ERC2771Context(_trustedForwarder) Ownable(_msgSender()) {}

    /// @notice Create a new HTLC swap
    /// @param swapId Unique identifier for this swap
    /// @param recipient Address to receive tokens on claim
    /// @param token ERC20 token to lock (must be approved beforehand)
    /// @param amount Amount of tokens to lock
    /// @param hashLock Hash of the secret (sha256)
    /// @param timelock Unix timestamp after which refund is possible
    function createSwap(
        bytes32 swapId,
        address recipient,
        address token,
        uint256 amount,
        bytes32 hashLock,
        uint256 timelock
    ) external nonReentrant {
        require(swaps[swapId].state == SwapState.INVALID, "Swap already exists");
        require(recipient != address(0), "Invalid recipient");
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount must be > 0");
        require(timelock > block.timestamp, "Timelock must be in future");
        require(hashLock != bytes32(0), "Invalid hash lock");

        // Transfer tokens from sender to this contract
        IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);

        // Create swap
        swaps[swapId] = Swap({
            sender: _msgSender(),
            recipient: recipient,
            token: token,
            amount: amount,
            hashLock: hashLock,
            timelock: timelock,
            state: SwapState.OPEN
        });

        emit SwapCreated(swapId, _msgSender(), recipient, token, amount, hashLock, timelock);
    }

    /// @notice Claim a swap by revealing the secret
    /// @param swapId The swap identifier
    /// @param secret The preimage of the hash lock
    function claimSwap(bytes32 swapId, bytes32 secret) external nonReentrant {
        Swap storage swap = swaps[swapId];

        require(swap.state == SwapState.OPEN, "Swap not open");
        require(sha256(abi.encodePacked(secret)) == swap.hashLock, "Invalid secret");

        swap.state = SwapState.CLAIMED;

        // Transfer tokens to recipient
        IERC20(swap.token).safeTransfer(swap.recipient, swap.amount);

        emit SwapClaimed(swapId, secret);
    }

    /// @notice Refund a swap after timelock expires
    /// @param swapId The swap identifier
    function refundSwap(bytes32 swapId) external nonReentrant {
        Swap storage swap = swaps[swapId];

        require(swap.state == SwapState.OPEN, "Swap not open");
        require(block.timestamp >= swap.timelock, "Timelock not expired");
        require(_msgSender() == swap.sender, "Only sender can refund");

        swap.state = SwapState.REFUNDED;

        // Return tokens to sender
        IERC20(swap.token).safeTransfer(swap.sender, swap.amount);

        emit SwapRefunded(swapId);
    }

    /// @notice Get swap details
    /// @param swapId The swap identifier
    function getSwap(bytes32 swapId) external view returns (Swap memory) {
        return swaps[swapId];
    }

    /// @notice Check if a swap exists and is open
    /// @param swapId The swap identifier
    function isSwapOpen(bytes32 swapId) external view returns (bool) {
        return swaps[swapId].state == SwapState.OPEN;
    }

    /// @notice Override for ERC-2771 context
    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    /// @notice Override for ERC-2771 context
    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice Override for ERC-2771 context
    function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}