// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HTLCErc20
/// @notice Hash Time-Locked Contract for trustless ERC20 atomic swaps
/// @dev Uses SHA-256 for preimage hashing to stay compatible with Bitcoin HTLC scripts.
///      Swap existence is tracked with a single bool per swap for minimal storage cost.
///      All swap parameters must be supplied on redeem/refund and are verified via hash.
contract HTLCErc20 {
    using SafeERC20 for IERC20;

    uint8 public constant VERSION = 1;

    // -- Errors --

    error ZeroAmount();
    error TimelockTooSoon();
    error TimelockNotExpired();
    error SwapExists();
    error SwapNotFound();
    error InvalidPreimage();
    error Reentrancy();

    // -- State --

    /// @dev Tracks locked swaps. Key is keccak256 of all swap parameters.
    mapping(bytes32 => bool) public swaps;

    // -- Events --

    event SwapCreated(
        bytes32 indexed preimageHash,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 timelock
    );

    event SwapRedeemed(bytes32 indexed preimageHash, bytes32 preimage);

    event SwapRefunded(bytes32 indexed preimageHash);

    // -- Reentrancy guard via transient storage (EIP-1153) --

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(0) {
                mstore(0, 0x37ed32e8) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(0, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(0, 0)
        }
    }

    // -- External functions --

    /// @notice Lock ERC20 tokens into a new hash time-locked swap
    /// @dev Convenience wrapper — uses msg.sender as the sender (refund address)
    /// @param preimageHash SHA-256 hash of the secret preimage — used as the swap identifier in events
    /// @param amount Token amount to lock (caller must have approved this contract)
    /// @param token ERC20 token address to lock
    /// @param recipient Address that receives tokens on redeem
    /// @param timelock Unix timestamp after which the sender can reclaim tokens
    function create(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address recipient,
        uint256 timelock
    ) external nonReentrant {
        _create(preimageHash, amount, token, msg.sender, recipient, timelock);
    }

    /// @notice Lock ERC20 tokens with an explicit sender (refund address)
    /// @dev Tokens are always pulled from msg.sender. The sender param controls
    ///      who can call refund — useful for coordinators/routers acting on behalf of a user.
    /// @param preimageHash SHA-256 hash of the secret preimage
    /// @param amount Token amount to lock (caller must have approved this contract)
    /// @param token ERC20 token address to lock
    /// @param sender Address that can refund after timelock (does not have to be msg.sender)
    /// @param recipient Address that receives tokens on redeem
    /// @param timelock Unix timestamp after which the sender can reclaim tokens
    function create(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address recipient,
        uint256 timelock
    ) external nonReentrant {
        _create(preimageHash, amount, token, sender, recipient, timelock);
    }

    /// @notice Redeem tokens by revealing the correct preimage
    /// @dev Anyone can call this; tokens always go to the designated recipient
    /// @param preimage Secret whose SHA-256 hash matches the preimageHash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param sender Address that created the swap
    /// @param recipient Address that receives the tokens
    /// @param timelock Timelock that was set at creation
    function redeem(
        bytes32 preimage,
        uint256 amount,
        address token,
        address sender,
        address recipient,
        uint256 timelock
    ) external nonReentrant {
        bytes32 preimageHash = sha256(abi.encodePacked(preimage));

        bytes32 key = _key(preimageHash, amount, token, sender, recipient, timelock);
        if (!swaps[key]) revert SwapNotFound();

        delete swaps[key];

        emit SwapRedeemed(preimageHash, preimage);

        IERC20(token).safeTransfer(recipient, amount);
    }

    /// @notice Reclaim tokens after the timelock has expired
    /// @dev Convenience wrapper — tokens are sent back to msg.sender
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param recipient Recipient that was set at creation
    /// @param timelock Timelock that was set at creation
    function refund(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address recipient,
        uint256 timelock
    ) external nonReentrant {
        _refund(preimageHash, amount, token, recipient, timelock);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Reclaim tokens after the timelock has expired, sending to a specified destination
    /// @dev msg.sender must still be the original sender (enforced via the hash).
    ///      Useful for sending tokens to a coordinator/router for further processing.
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param recipient Recipient that was set at creation
    /// @param timelock Timelock that was set at creation
    /// @param destination Address to receive the refunded tokens
    function refund(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address recipient,
        uint256 timelock,
        address destination
    ) external nonReentrant {
        _refund(preimageHash, amount, token, recipient, timelock);
        IERC20(token).safeTransfer(destination, amount);
    }

    // -- View functions --

    /// @notice Check whether a swap with the given parameters is active
    function isActive(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address recipient,
        uint256 timelock
    ) external view returns (bool) {
        return swaps[_key(preimageHash, amount, token, sender, recipient, timelock)];
    }

    /// @notice Compute the storage key for a swap from its parameters
    function computeKey(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address recipient,
        uint256 timelock
    ) external pure returns (bytes32) {
        return _key(preimageHash, amount, token, sender, recipient, timelock);
    }

    // -- Internal --

    function _refund(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address recipient,
        uint256 timelock
    ) internal {
        if (block.timestamp < timelock) revert TimelockNotExpired();

        bytes32 key = _key(preimageHash, amount, token, msg.sender, recipient, timelock);
        if (!swaps[key]) revert SwapNotFound();

        delete swaps[key];

        emit SwapRefunded(preimageHash);
    }

    function _create(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address recipient,
        uint256 timelock
    ) internal {
        if (amount == 0) revert ZeroAmount();
        if (timelock <= block.timestamp) revert TimelockTooSoon();

        bytes32 key = _key(preimageHash, amount, token, sender, recipient, timelock);
        if (swaps[key]) revert SwapExists();

        swaps[key] = true;

        emit SwapCreated(preimageHash, sender, recipient, token, amount, timelock);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev Compute the storage key from all swap parameters using assembly for gas efficiency
    function _key(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address recipient,
        uint256 timelock
    ) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, preimageHash)
            mstore(add(ptr, 0x20), amount)
            mstore(add(ptr, 0x40), token)
            mstore(add(ptr, 0x60), sender)
            mstore(add(ptr, 0x80), recipient)
            mstore(add(ptr, 0xa0), timelock)
            result := keccak256(ptr, 0xc0)
        }
    }
}
