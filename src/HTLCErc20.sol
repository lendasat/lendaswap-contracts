// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HTLCErc20
/// @notice Hash Time-Locked Contract for trustless ERC20 atomic swaps
/// @dev Uses SHA-256 for preimage hashing to stay compatible with Bitcoin HTLC scripts.
///      Swap existence is tracked with a single bool per swap for minimal storage cost.
///      All swap parameters must be supplied on redeem/refund and are verified via hash.
///      The `claimAddress` is part of the swap key and only that address can redeem
///      (directly via msg.sender or via EIP-712 signature), preventing front-running.
contract HTLCErc20 {
    using SafeERC20 for IERC20;

    uint8 public constant VERSION = 3;

    // -- EIP-712 --

    bytes32 public constant TYPEHASH_REDEEM = keccak256(
        "Redeem(bytes32 preimage,uint256 amount,address token,address sender,uint256 timelock,address caller,address destination,address sweepToken,uint256 minAmountOut,bytes32 callsHash)"
    );

    bytes32 public constant TYPEHASH_REFUND = keccak256(
        "Refund(bytes32 preimageHash,uint256 amount,address token,address refundAddress,uint256 timelock,address caller,address destination,address sweepToken,uint256 minAmountOut)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR = keccak256(
        abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("HTLCErc20"),
            keccak256("3"),
            block.chainid,
            address(this)
        )
    );

    // -- Errors --

    error Reentrancy();

    // -- State --

    /// @dev Tracks locked swaps. Key is keccak256 of all swap parameters.
    mapping(bytes32 => bool) public swaps;

    // -- Events --

    event SwapCreated(
        bytes32 indexed preimageHash,
        address indexed refundAddress,
        address indexed claimAddress,
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
    /// @param claimAddress Address authorized to redeem the locked tokens
    /// @param timelock Unix timestamp after which the sender can reclaim tokens
    function create(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 timelock
    ) external nonReentrant {
        _create(preimageHash, amount, token, msg.sender, claimAddress, timelock);
    }

    /// @notice Lock ERC20 tokens with an explicit refund address
    /// @dev Tokens are always pulled from msg.sender. The refundAddress param controls
    ///      who can call refund — useful for coordinators/routers acting on behalf of a user.
    /// @param preimageHash SHA-256 hash of the secret preimage
    /// @param amount Token amount to lock (caller must have approved this contract)
    /// @param token ERC20 token address to lock
    /// @param refundAddress Address that can refund after timelock (does not have to be msg.sender)
    /// @param claimAddress Address authorized to redeem the locked tokens
    /// @param timelock Unix timestamp after which the refund address can reclaim tokens
    function create(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address refundAddress,
        address claimAddress,
        uint256 timelock
    ) external nonReentrant {
        _create(preimageHash, amount, token, refundAddress, claimAddress, timelock);
    }

    /// @notice Redeem tokens by revealing the correct preimage (direct claim)
    /// @dev Only the designated claimAddress can call this — msg.sender is used as
    ///      claimAddress in the key lookup. Tokens are sent to msg.sender.
    /// @param preimage Secret whose SHA-256 hash matches the preimageHash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param sender Address that created the swap
    /// @param timelock Timelock that was set at creation
    function redeem(
        bytes32 preimage,
        uint256 amount,
        address token,
        address sender,
        uint256 timelock
    ) external nonReentrant {
        bytes32 preimageHash = sha256(abi.encodePacked(preimage));

        // msg.sender is used as claimAddress — only the designated address can claim
        bytes32 key = _key(preimageHash, amount, token, sender, msg.sender, timelock);
        require(swaps[key], "HTLC: swap not found");

        delete swaps[key];

        emit SwapRedeemed(preimageHash, preimage);

        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Redeem tokens using an EIP-712 signature from the claimAddress (gasless / delegated)
    /// @dev Anyone can call this function. The claimAddress is recovered from the signature
    ///      which includes msg.sender as the authorized caller, destination, sweepToken,
    ///      minAmountOut, and callsHash. Tokens are sent to msg.sender (not claimAddress).
    ///      All execution parameters are cryptographically bound to the signature, so the
    ///      outcome is guaranteed by the signer regardless of who submits the transaction.
    /// @param preimage Secret whose SHA-256 hash matches the preimageHash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param sender Address that created the swap
    /// @param timelock Timelock that was set at creation
    /// @param destination Address where the caller intends to route tokens after redeem
    /// @param sweepToken Token the caller will sweep to destination (bound to signature)
    /// @param minAmountOut Minimum amount of sweepToken required (bound to signature)
    /// @param callsHash Hash of the calls array (bound to signature, prevents call substitution)
    /// @param v ECDSA recovery id
    /// @param r ECDSA signature component
    /// @param s ECDSA signature component
    /// @return claimAddress The address recovered from the signature
    function redeemBySig(
        bytes32 preimage,
        uint256 amount,
        address token,
        address sender,
        uint256 timelock,
        address destination,
        address sweepToken,
        uint256 minAmountOut,
        bytes32 callsHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (address claimAddress) {
        bytes32 preimageHash = sha256(abi.encodePacked(preimage));

        // Scoped to reduce stack depth: compute digest and recover signer
        {
            bytes32 structHash = keccak256(
                abi.encode(
                    TYPEHASH_REDEEM, preimage, amount, token, sender, timelock,
                    msg.sender, destination, sweepToken, minAmountOut, callsHash
                )
            );
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
            claimAddress = ecrecover(digest, v, r, s);
        }

        bytes32 key = _key(preimageHash, amount, token, sender, claimAddress, timelock);
        require(swaps[key], "HTLC: swap not found");

        delete swaps[key];

        emit SwapRedeemed(preimageHash, preimage);

        // Tokens go to msg.sender (the authorized caller), not claimAddress
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Reclaim tokens after the timelock has expired
    /// @dev Convenience wrapper — tokens are sent back to msg.sender
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param claimAddress Claim address that was set at creation
    /// @param timelock Timelock that was set at creation
    function refund(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 timelock
    ) external nonReentrant {
        _refund(preimageHash, amount, token, claimAddress, timelock);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Reclaim tokens after the timelock has expired, sending to a specified destination
    /// @dev msg.sender must still be the original sender (enforced via the hash).
    ///      Useful for sending tokens to a coordinator/router for further processing.
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param claimAddress Claim address that was set at creation
    /// @param timelock Timelock that was set at creation
    /// @param destination Address to receive the refunded tokens
    function refund(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 timelock,
        address destination
    ) external nonReentrant {
        _refund(preimageHash, amount, token, claimAddress, timelock);
        IERC20(token).safeTransfer(destination, amount);
    }

    /// @notice Refund tokens before timelock using an EIP-712 signature from the claimAddress
    /// @dev The claimAddress signs to waive the timelock, enabling collaborative refunds.
    ///      Anyone can call this function. The claimAddress is recovered from the signature.
    ///      Tokens are sent to msg.sender (not the refund address or claimAddress).
    ///      All execution parameters are cryptographically bound to the signature.
    /// @param preimageHash The preimage hash used at creation (NOT the preimage — refunder doesn't know it)
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param refundAddress The original sender/refund address from HTLC creation
    /// @param timelock Timelock that was set at creation
    /// @param destination Address where the caller intends to route tokens after refund
    /// @param sweepToken Token the caller will sweep to destination (bound to signature)
    /// @param minAmountOut Minimum amount of sweepToken required (bound to signature)
    /// @param v ECDSA recovery id
    /// @param r ECDSA signature component
    /// @param s ECDSA signature component
    /// @return claimAddress The address recovered from the signature
    function refundBySig(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address refundAddress,
        uint256 timelock,
        address destination,
        address sweepToken,
        uint256 minAmountOut,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (address claimAddress) {
        // Scoped to reduce stack depth
        {
            bytes32 structHash = keccak256(
                abi.encode(
                    TYPEHASH_REFUND,
                    preimageHash,
                    amount,
                    token,
                    refundAddress,
                    timelock,
                    msg.sender,
                    destination,
                    sweepToken,
                    minAmountOut
                )
            );
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
            claimAddress = ecrecover(digest, v, r, s);
        }

        bytes32 key = _key(preimageHash, amount, token, refundAddress, claimAddress, timelock);
        require(swaps[key], "HTLC: swap not found");

        delete swaps[key];

        emit SwapRefunded(preimageHash);

        // Tokens go to msg.sender (the authorized caller), not refundAddress
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    // -- View functions --

    /// @notice Check whether a swap with the given parameters is active
    function isActive(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) external view returns (bool) {
        return swaps[_key(preimageHash, amount, token, sender, claimAddress, timelock)];
    }

    /// @notice Compute the storage key for a swap from its parameters
    function computeKey(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) external pure returns (bytes32) {
        return _key(preimageHash, amount, token, sender, claimAddress, timelock);
    }

    // -- Internal --

    function _refund(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 timelock
    ) internal {
        require(block.timestamp >= timelock, "HTLC: timelock not expired");

        bytes32 key = _key(preimageHash, amount, token, msg.sender, claimAddress, timelock);
        require(swaps[key], "HTLC: swap not found");

        delete swaps[key];

        emit SwapRefunded(preimageHash);
    }

    function _create(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address refundAddress,
        address claimAddress,
        uint256 timelock
    ) internal {
        require(amount > 0, "HTLC: zero amount");
        require(timelock > block.timestamp, "HTLC: timelock too soon");

        bytes32 key = _key(preimageHash, amount, token, refundAddress, claimAddress, timelock);
        require(!swaps[key], "HTLC: swap exists");

        swaps[key] = true;

        emit SwapCreated(preimageHash, refundAddress, claimAddress, token, amount, timelock);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev Compute the storage key from all swap parameters using assembly for gas efficiency
    function _key(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address refundAddress,
        address claimAddress,
        uint256 timelock
    ) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, preimageHash)
            mstore(add(ptr, 0x20), amount)
            mstore(add(ptr, 0x40), token)
            mstore(add(ptr, 0x60), refundAddress)
            mstore(add(ptr, 0x80), claimAddress)
            mstore(add(ptr, 0xa0), timelock)
            result := keccak256(ptr, 0xc0)
        }
    }
}
