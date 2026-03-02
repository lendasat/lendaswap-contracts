// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {HTLCErc20} from "./HTLCErc20.sol";

/// @title HTLCCoordinator
/// @notice Coordinates arbitrary call execution with HTLCErc20 create, redeem and refund
/// @dev Three primary flows:
///   1. executeAndCreate – run arbitrary calls (e.g. DEX swap), then lock the
///      resulting token balance in an HTLC.
///   2. redeemAndExecute – redeem tokens from an HTLC via EIP-712 signature,
///      run arbitrary calls (e.g. DEX swap), then sweep the result to the caller.
///      Front-running safe: the HTLC-level signature binds to this coordinator as
///      msg.sender, and the coordinator verifies claimAddress == msg.sender.
///   3. refundAndExecute – refund an expired HTLC (created via this coordinator),
///      run arbitrary calls (e.g. swap WBTC back to USDC), then sweep to the
///      original depositor.
contract HTLCCoordinator {
    using SafeERC20 for IERC20;

    uint8 public constant VERSION = 3;

    bytes32 public constant TYPEHASH_EXECUTE_AND_CREATE = keccak256(
        "ExecuteAndCreate(bytes32 preimageHash,address token,address claimAddress,address refundAddress,uint256 timelock,bytes32 callsHash)"
    );

    string public constant TYPESTRING_EXECUTE_AND_CREATE =
        "ExecuteAndCreate witness)ExecuteAndCreate(bytes32 preimageHash,address token,address claimAddress,address refundAddress,uint256 timelock,bytes32 callsHash)TokenPermissions(address token,uint256 amount)";

    // -- Errors --

    error Reentrancy();

    // -- Types --

    /// @param target   Contract address to call
    /// @param value    ETH to forward with the call
    /// @param callData ABI-encoded function calldata
    struct Call {
        address target;
        uint256 value;
        bytes callData;
    }

    // -- Immutables --

    HTLCErc20 public immutable HTLC;
    ISignatureTransfer public immutable PERMIT2;

    // -- Storage --

    /// @dev Maps HTLC storage key -> original depositor address.
    ///      Populated by executeAndCreate, used by refundAndExecute / refundTo.
    mapping(bytes32 => address) public deposits;

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

    // -- Constructor --

    constructor(address htlc, address permit2) {
        HTLC = HTLCErc20(htlc);
        PERMIT2 = ISignatureTransfer(permit2);
    }

    // -- External functions --

    /// @notice Pull tokens from depositor via Permit2, execute arbitrary calls, then
    ///         lock the resulting balance in an HTLC with the coordinator as sender
    /// @dev The coordinator becomes the HTLC sender (depositor tracking enabled).
    ///      If the swap expires, only the depositor can call refundAndExecute;
    ///      refundTo is permissionless but always sends tokens to the depositor.
    /// @param calls        Arbitrary calls to execute (e.g. DEX swap)
    /// @param preimageHash SHA-256 preimage hash for the HTLC
    /// @param token        Output ERC20 token to lock in the HTLC (e.g. WBTC after a USDC→WBTC swap).
    ///                     The input token is specified in permit.permitted.token.
    /// @param claimAddress Address authorized to redeem the HTLC
    /// @param timelock     Unix timestamp after which a refund is possible
    /// @param depositor    Address whose tokens are pulled via Permit2
    /// @param permit       Permit2 permit data (input token, amount, nonce, deadline)
    /// @param signature    Permit2 signature from the depositor
    function executeAndCreateWithPermit2(
        Call[] calldata calls,
        bytes32 preimageHash,
        address token,
        address claimAddress,
        uint256 timelock,
        address depositor,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant {
        _permit2Transfer(
            token, preimageHash, claimAddress, address(this), timelock, calls, depositor, permit, signature
        );

        _executeCalls(calls);

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "Coordinator: insufficient balance");

        IERC20(token).forceApprove(address(HTLC), balance);
        HTLC.create(preimageHash, balance, token, claimAddress, timelock);

        bytes32 key = HTLC.computeKey(preimageHash, balance, token, address(this), claimAddress, timelock);
        deposits[key] = depositor;
    }

    /// @notice Pull tokens from refundAddress via Permit2, execute arbitrary calls,
    ///         then lock the resulting balance in an HTLC with an explicit refund address
    /// @dev The refundAddress is set as the HTLC sender — user refunds directly on HTLCErc20.
    ///      Cannot use refundAndExecute (no depositor tracking).
    /// @param calls         Arbitrary calls to execute (e.g. DEX swap)
    /// @param preimageHash  SHA-256 preimage hash for the HTLC
    /// @param token         Output ERC20 token to lock in the HTLC (e.g. WBTC after a USDC→WBTC swap).
    ///                      The input token is specified in permit.permitted.token.
    /// @param refundAddress Address that can refund after timelock (the actual user)
    /// @param claimAddress  Address authorized to redeem the HTLC
    /// @param timelock      Unix timestamp after which a refund is possible
    /// @param permit        Permit2 permit data (input token, amount, nonce, deadline)
    /// @param signature     Permit2 signature from the refundAddress
    function executeAndCreateWithPermit2(
        Call[] calldata calls,
        bytes32 preimageHash,
        address token,
        address refundAddress,
        address claimAddress,
        uint256 timelock,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant {
        _permit2Transfer(
            token, preimageHash, claimAddress, refundAddress, timelock, calls, refundAddress, permit, signature
        );

        _executeCalls(calls);
        _createFromBalance(preimageHash, token, refundAddress, claimAddress, timelock);
    }

    /// @notice Redeem tokens from an HTLC via EIP-712 signature, execute arbitrary
    ///         calls, then sweep the resulting balance to a signed destination
    /// @dev The claimAddress signs an HTLC-level EIP-712 message authorizing this
    ///      coordinator as the caller and binding the destination address. Anyone can
    ///      submit the transaction, but the destination is cryptographically guaranteed
    ///      by the claimAddress's signature. If a malicious submitter changes the
    ///      destination, ecrecover returns the wrong address → swap key mismatch → revert.
    /// @param preimage     Secret that SHA-256 hashes to the HTLC's preimageHash
    /// @param amount       Token amount locked in the HTLC
    /// @param token        ERC20 token locked in the HTLC
    /// @param htlcSender   Address that created the HTLC
    /// @param timelock     Timelock set at HTLC creation
    /// @param calls        Arbitrary calls to execute after redeem (e.g. DEX swap)
    /// @param sweepToken   Token to sweep to the destination (address(0) for ETH)
    /// @param minAmountOut Minimum balance required before sweeping
    /// @param destination  Address to receive swept tokens (signed by claimAddress)
    /// @param v            ECDSA recovery id (HTLC-level signature)
    /// @param r            ECDSA signature component (HTLC-level signature)
    /// @param s            ECDSA signature component (HTLC-level signature)
    function redeemAndExecute(
        bytes32 preimage,
        uint256 amount,
        address token,
        address htlcSender,
        uint256 timelock,
        Call[] calldata calls,
        address sweepToken,
        uint256 minAmountOut,
        address destination,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // HTLC.redeemBySig recovers claimAddress from the signature and sends tokens
        // to msg.sender (this coordinator). The signature includes address(this) as
        // caller, destination, sweepToken, and minAmountOut — no separate claimAddress
        // check needed, and execution parameters cannot be tampered with.
        bytes32 callsHash = _computeCallsHash(calls);
        HTLC.redeemBySig(preimage, amount, token, htlcSender, timelock, destination, sweepToken, minAmountOut, callsHash, v, r, s);

        _executeCalls(calls);
        _sweep(destination, sweepToken, minAmountOut);
    }

    /// @notice Refund an expired HTLC created via this coordinator, execute arbitrary
    ///         calls (e.g. swap WBTC back to USDC), then sweep to the original depositor
    /// @dev Restricted to the original depositor only. Arbitrary calls are executed
    ///      with the coordinator as msg.sender, so only the depositor should control
    ///      what calls are made (prevents token theft via malicious calls).
    ///      For permissionless refund without calls, use refundTo instead.
    /// @param preimageHash The preimage hash used at HTLC creation
    /// @param amount       Token amount locked in the HTLC
    /// @param token        ERC20 token locked in the HTLC
    /// @param claimAddress Claim address set at HTLC creation
    /// @param timelock     Timelock set at HTLC creation
    /// @param calls        Arbitrary calls to execute after refund (e.g. DEX swap-back)
    /// @param sweepToken   Token to sweep to the depositor (address(0) for ETH)
    /// @param minAmountOut Minimum balance required before sweeping
    function refundAndExecute(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 timelock,
        Call[] calldata calls,
        address sweepToken,
        uint256 minAmountOut
    ) external nonReentrant {
        bytes32 key = HTLC.computeKey(preimageHash, amount, token, address(this), claimAddress, timelock);
        address depositor = deposits[key];
        require(depositor != address(0), "Coordinator: unknown HTLC");
        require(msg.sender == depositor, "Coordinator: unauthorized");

        delete deposits[key];

        HTLC.refund(preimageHash, amount, token, claimAddress, timelock);

        if (calls.length > 0) {
            _executeCalls(calls);
        }

        _sweep(depositor, sweepToken, minAmountOut);
    }

    /// @notice Refund an expired coordinator-created HTLC and send the locked
    ///         token directly to the original depositor (no swap-back)
    /// @dev Permissionless — anyone can trigger this after timelock expiry.
    ///      Tokens always go to the depositor regardless of who calls.
    /// @param preimageHash The preimage hash used at HTLC creation
    /// @param amount       Token amount locked in the HTLC
    /// @param token        ERC20 token locked in the HTLC
    /// @param claimAddress Claim address set at HTLC creation
    /// @param timelock     Timelock set at HTLC creation
    function refundTo(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 timelock
    ) external nonReentrant {
        bytes32 key = HTLC.computeKey(preimageHash, amount, token, address(this), claimAddress, timelock);
        address depositor = deposits[key];
        require(depositor != address(0), "Coordinator: unknown HTLC");

        delete deposits[key];

        HTLC.refund(preimageHash, amount, token, claimAddress, timelock, depositor);
    }

    // -- Internal helpers --

    function _createFromBalance(
        bytes32 preimageHash,
        address token,
        address refundAddress,
        address claimAddress,
        uint256 timelock
    ) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "Coordinator: insufficient balance");

        IERC20(token).forceApprove(address(HTLC), balance);
        HTLC.create(preimageHash, balance, token, refundAddress, claimAddress, timelock);
    }

    function _executeCalls(Call[] calldata calls) internal {
        uint256 length = calls.length;
        for (uint256 i = 0; i < length; i++) {
            Call calldata c = calls[i];
            _revertIfRestricted(c.target);
            _revertIfDangerousSelector(c.callData);

            (bool success,) = c.target.call{value: c.value}(c.callData);
            if (!success) revert("Coordinator: call failed");
        }
    }

    function _sweep(address destination, address token, uint256 minAmountOut) internal {
        uint256 balance;
        if (token == address(0)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }

        require(balance >= minAmountOut, "Coordinator: insufficient balance");
        if (balance == 0) return;

        if (token == address(0)) {
            (bool success,) = payable(destination).call{value: balance}("");
            if (!success) revert("Coordinator: call failed");
        } else {
            IERC20(token).safeTransfer(destination, balance);
        }
    }

    function _permit2Transfer(
        address token,
        bytes32 preimageHash,
        address claimAddress,
        address refundAddress,
        uint256 timelock,
        Call[] calldata calls,
        address signer,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) internal {
        bytes32 callsHash = _computeCallsHash(calls);

        bytes32 witness;
        {
            bytes32 typeHash = TYPEHASH_EXECUTE_AND_CREATE;
            assembly ("memory-safe") {
                let ptr := mload(0x40)
                mstore(ptr, typeHash)
                mstore(add(ptr, 0x20), preimageHash)
                mstore(add(ptr, 0x40), token)
                mstore(add(ptr, 0x60), claimAddress)
                mstore(add(ptr, 0x80), refundAddress)
                mstore(add(ptr, 0xa0), timelock)
                mstore(add(ptr, 0xc0), callsHash)
                witness := keccak256(ptr, 0xe0)
                mstore(0x40, add(ptr, 0xe0))
            }
        }

        PERMIT2.permitWitnessTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: permit.permitted.amount}),
            signer,
            witness,
            TYPESTRING_EXECUTE_AND_CREATE,
            signature
        );
    }

    function _computeCallsHash(Call[] calldata calls) internal pure returns (bytes32 callsHash) {
        bytes memory callsData = abi.encode(calls);
        assembly ("memory-safe") {
            callsHash := keccak256(add(callsData, 0x20), mload(callsData))
        }
    }

    /// @dev Defense-in-depth: block transferFrom-family selectors that could drain
    ///      third-party approvals. Even though Permit2 is the primary token-pull
    ///      mechanism, this prevents any residual risk from arbitrary call execution.
    function _revertIfDangerousSelector(bytes calldata callData) internal pure {
        if (callData.length >= 4) {
            bytes4 selector = bytes4(callData[:4]);
            // ERC-20/721 transferFrom
            require(selector != bytes4(0x23b872dd), "Coordinator: transferFrom not allowed");
            // ERC-721 safeTransferFrom(address,address,uint256)
            require(selector != bytes4(0x42842e0e), "Coordinator: transferFrom not allowed");
            // ERC-721 safeTransferFrom(address,address,uint256,bytes)
            require(selector != bytes4(0xb88d4fde), "Coordinator: transferFrom not allowed");
            // ERC-1155 safeTransferFrom
            require(selector != bytes4(0xf242432a), "Coordinator: transferFrom not allowed");
            // ERC-1155 safeBatchTransferFrom
            require(selector != bytes4(0x2eb2c2d6), "Coordinator: transferFrom not allowed");
        }
    }

    function _revertIfRestricted(address target) internal view {
        require(
            target != address(HTLC) && target != address(this) && target != address(PERMIT2),
            "Coordinator: restricted target"
        );
    }

    /// @dev Accept ETH (e.g. from Uniswap refunds or WETH unwrapping)
    receive() external payable {}
}
