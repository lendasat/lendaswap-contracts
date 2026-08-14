// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice A swap's storage key: keccak256 over all six swap parameters (see
///         `HTLCErc20.computeKey`). One key identifies one swap everywhere —
///         it indexes `swaps` and `preimages` here and the coordinator's
///         `deposits`, and is the identifier carried by every lifecycle event.
type SwapKey is bytes32;

/// @title HTLCErc20
/// @notice Hash Time-Locked Contract for trustless ERC20 atomic swaps
/// @dev Uses SHA-256 for preimage hashing to stay compatible with Bitcoin HTLC scripts.
///      Each swap's lifecycle state is kept in storage permanently (None → Active →
///      Redeemed/Refunded), and a redeem also stores the revealed preimage — so an
///      observer can classify a settled swap and recover its preimage with a single
///      state read instead of scanning event logs.
///      All swap parameters must be supplied on redeem/refund and are verified via hash.
///      The `claimAddress` is part of the swap key and only that address can redeem
///      (directly via msg.sender or via EIP-712 signature), preventing front-running.
/// @dev The owner's only powers are `recoverExcessToken` and `recoverEther`.
///      `lockedAmounts` accounts for every token unit owed to an active swap, and
///      `recoverExcessToken` can move only the balance above it, so no owner action
///      can reach swap funds.
contract HTLCErc20 is Ownable2Step {
    using SafeERC20 for IERC20;

    uint8 public constant VERSION = 5;

    // -- EIP-712 --
    //
    // The domain's version string tracks VERSION. Signers must use the same value,
    // or the recovered claimAddress will not match and settlement reverts.

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
            keccak256("5"),
            block.chainid,
            address(this)
        )
    );

    // -- Errors --

    error Reentrancy();

    // -- State --

    /// @notice Lifecycle of a swap. Terminal states are never deleted, so a key's
    ///         history stays readable from storage forever.
    enum SwapState {
        None,
        Active,
        Redeemed,
        Refunded
    }

    /// @dev Swap lifecycle state, by swap key. A key that ever reached a terminal
    ///      state can never be created again: the preimage of a redeemed key is
    ///      public, so a second swap under the same key would be claimable by
    ///      anyone watching the chain.
    mapping(SwapKey => SwapState) public swaps;

    /// @dev Token units owed to active swaps, per token. Rises on create, falls on every
    ///      settlement, so the contract's balance minus this is owed to nobody.
    mapping(address => uint256) public lockedAmounts;

    /// @dev The preimage a redeem revealed, by swap key (the same key as `swaps`).
    ///      Zero until redeemed; the state enum, not this value, is the authority
    ///      on whether a redeem happened.
    mapping(SwapKey => bytes32) public preimages;

    // -- Events --

    /// @dev `key` commits to every swap parameter and is a swap's unique identifier.
    ///      `preimageHash` is not unique — any number of swaps may share one, each with
    ///      its own terms. Consumers must match a swap on `key`, never on `preimageHash`.
    event SwapCreated(
        bytes32 indexed preimageHash,
        address indexed refundAddress,
        address indexed claimAddress,
        address token,
        uint256 amount,
        uint256 timelock,
        SwapKey key
    );

    event SwapRedeemed(bytes32 indexed preimageHash, SwapKey indexed key, bytes32 preimage);

    event SwapRefunded(bytes32 indexed preimageHash, SwapKey indexed key);

    event ExcessTokenRecovered(address indexed token, address indexed to, uint256 amount);

    event EtherRecovered(address indexed to, uint256 amount);

    // -- Constructor --

    constructor(address initialOwner) Ownable(initialOwner) {}

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
    /// @param preimageHash SHA-256 hash of the secret preimage — an indexed event topic,
    ///                      not an identifier: swaps may share one, and `key` tells them apart
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
        SwapKey key = _key(preimageHash, amount, token, sender, msg.sender, timelock);
        require(swaps[key] == SwapState.Active, "HTLC: swap not found");

        swaps[key] = SwapState.Redeemed;
        preimages[key] = preimage;
        lockedAmounts[token] -= amount;

        emit SwapRedeemed(preimageHash, key, preimage);

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
            claimAddress = ECDSA.recover(digest, v, r, s);
        }

        SwapKey key = _key(preimageHash, amount, token, sender, claimAddress, timelock);
        require(swaps[key] == SwapState.Active, "HTLC: swap not found");

        swaps[key] = SwapState.Redeemed;
        preimages[key] = preimage;
        lockedAmounts[token] -= amount;

        emit SwapRedeemed(preimageHash, key, preimage);

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
        revert("unimplemented");
    }

    // -- Owner functions --

    /// @notice Recover the token balance held beyond what active swaps are owed
    /// @dev An ERC20 transfer into this contract cannot be refused, so the balance can
    ///      exceed `lockedAmounts[token]`. Only that difference is movable: the subtraction
    ///      floors at what every active swap is owed, so no call here can reduce the balance
    ///      below the amount its settlements will need.
    /// @param token Token to recover the excess of
    /// @param to Recipient of the recovered tokens
    function recoverExcessToken(address token, address to) external onlyOwner nonReentrant {
        require(to != address(0), "HTLC: zero recipient");

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 locked = lockedAmounts[token];
        require(balance > locked, "HTLC: no excess");

        uint256 excess = balance - locked;

        emit ExcessTokenRecovered(token, to, excess);

        IERC20(token).safeTransfer(to, excess);
    }

    /// @notice Recover ether held by this contract
    /// @dev No function here is payable, so a balance can only come from a force-send
    ///      (selfdestruct, coinbase, or a transfer to the address before deployment). None of
    ///      it belongs to a swap, so the full balance is recoverable.
    /// @param to Recipient of the recovered ether
    function recoverEther(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "HTLC: zero recipient");

        uint256 balance = address(this).balance;
        require(balance > 0, "HTLC: no excess");

        emit EtherRecovered(to, balance);

        (bool sent,) = to.call{value: balance}("");
        require(sent, "HTLC: ether transfer failed");
    }

    /// @dev Disabled: recovery is owner-gated, so an ownerless contract could never release
    ///      a mis-sent balance again. Use `transferOwnership` / `acceptOwnership` instead.
    function renounceOwnership() public pure override {
        revert("HTLC: ownership required");
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
        return swaps[_key(preimageHash, amount, token, sender, claimAddress, timelock)] == SwapState.Active;
    }

    /// @notice A swap's lifecycle state and (if redeemed) its revealed preimage,
    ///         by swap key — one read classifies a settled swap without log scans
    /// @param key The swap key (see `computeKey`, or the `key` field of `SwapCreated`)
    function swapState(SwapKey key) external view returns (SwapState state, bytes32 preimage) {
        return (swaps[key], preimages[key]);
    }

    /// @notice Compute the storage key for a swap from its parameters
    function computeKey(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) external pure returns (SwapKey) {
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

        SwapKey key = _key(preimageHash, amount, token, msg.sender, claimAddress, timelock);
        require(swaps[key] == SwapState.Active, "HTLC: swap not found");

        swaps[key] = SwapState.Refunded;
        lockedAmounts[token] -= amount;

        emit SwapRefunded(preimageHash, key);
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
        // Neither party may be address(0). It is the address a failed signature recovery
        // resolves to, so it must never be a claimAddress that a key commits to, and a
        // zero refundAddress could never reclaim the swap once its timelock expires.
        require(claimAddress != address(0), "HTLC: zero claim address");
        require(refundAddress != address(0), "HTLC: zero refund address");

        SwapKey key = _key(preimageHash, amount, token, refundAddress, claimAddress, timelock);
        // Also rejects settled keys: the key's terms are spent — a redeemed key's
        // preimage is public, so tokens locked under it again would be claimable
        // by anyone. New swaps must use a fresh preimageHash (or other terms).
        require(swaps[key] == SwapState.None, "HTLC: swap exists");

        swaps[key] = SwapState.Active;
        lockedAmounts[token] += amount;

        emit SwapCreated(preimageHash, refundAddress, claimAddress, token, amount, timelock, key);

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
    ) internal pure returns (SwapKey) {
        bytes32 result;
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
        return SwapKey.wrap(result);
    }
}
