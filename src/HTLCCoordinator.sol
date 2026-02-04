// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    uint8 public constant VERSION = 2;

    // -- Errors --

    error CallFailed(uint256 index);
    error RestrictedTarget();
    error InsufficientBalance();
    error UnknownHTLC();
    error RefundCallsMismatch();
    error InvalidClaimer();
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

    /// @param depositor       The original caller who created the HTLC via this coordinator
    /// @param refundCallsHash keccak256 of the pre-committed refund calls (0 = no refund calls)
    struct Deposit {
        address depositor;
        bytes32 refundCallsHash;
    }

    // -- Immutables --

    HTLCErc20 public immutable HTLC;

    // -- Storage --

    /// @dev Maps HTLC storage key -> deposit info for coordinator-created HTLCs.
    ///      Populated by executeAndCreate (convenience), used by refundAndExecute.
    mapping(bytes32 => Deposit) public deposits;

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

    constructor(address htlc) {
        HTLC = HTLCErc20(htlc);
    }

    // -- External functions --

    /// @notice Execute arbitrary calls then lock the resulting token balance in an HTLC
    /// @dev The coordinator becomes the HTLC sender. If the swap expires, anyone can
    ///      call refundAndExecute with calls matching refundCallsHash to reclaim tokens
    ///      and swap them back for the depositor.
    /// @param calls           Arbitrary calls to execute first (e.g. swap USDC -> WBTC)
    /// @param preimageHash    SHA-256 preimage hash for the HTLC
    /// @param token           ERC20 token to lock (must be the output of the calls)
    /// @param claimAddress    Address authorized to redeem the HTLC
    /// @param timelock        Unix timestamp after which a refund is possible
    /// @param refundCallsHash keccak256(abi.encode(refundCalls)) — committed at creation,
    ///                        verified at refund. Use bytes32(0) to skip call verification
    ///                        (refundAndExecute will only sweep without executing calls).
    function executeAndCreate(
        Call[] calldata calls,
        bytes32 preimageHash,
        address token,
        address claimAddress,
        uint256 timelock,
        bytes32 refundCallsHash
    ) external payable nonReentrant {
        _executeCalls(calls);

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert InsufficientBalance();

        IERC20(token).forceApprove(address(HTLC), balance);
        HTLC.create(preimageHash, balance, token, claimAddress, timelock);

        bytes32 key = HTLC.computeKey(preimageHash, balance, token, address(this), claimAddress, timelock);
        deposits[key] = Deposit({depositor: msg.sender, refundCallsHash: refundCallsHash});
    }

    /// @notice Execute arbitrary calls then lock the resulting token balance in an HTLC
    ///         with an explicit refund address
    /// @dev Enables sponsored swaps — a relayer/sponsor executes and pays gas, but
    ///      the refund address is set to the actual user. The user can call
    ///      HTLCErc20.refund directly if the swap expires.
    ///      Cannot use refundAndExecute (user refunds directly).
    /// @param calls         Arbitrary calls to execute first (e.g. DEX swap)
    /// @param preimageHash  SHA-256 preimage hash for the HTLC
    /// @param token         ERC20 token to lock (must be the output of the calls)
    /// @param refundAddress Address that can refund after timelock (the actual user)
    /// @param claimAddress  Address authorized to redeem the HTLC
    /// @param timelock      Unix timestamp after which a refund is possible
    function executeAndCreate(
        Call[] calldata calls,
        bytes32 preimageHash,
        address token,
        address refundAddress,
        address claimAddress,
        uint256 timelock
    ) external payable nonReentrant {
        _executeCalls(calls);
        _createFromBalance(preimageHash, token, refundAddress, claimAddress, timelock);
    }

    /// @notice Redeem tokens from an HTLC via EIP-712 signature, execute arbitrary
    ///         calls, then sweep the resulting balance to the caller
    /// @dev The claimAddress signs an HTLC-level EIP-712 message authorizing this
    ///      coordinator as the caller. The coordinator verifies the recovered
    ///      claimAddress matches msg.sender, ensuring only the claimAddress can
    ///      trigger this flow. Front-running safe: the HTLC signature includes
    ///      this coordinator's address, and the coordinator checks claimAddress == msg.sender.
    /// @param preimage     Secret that SHA-256 hashes to the HTLC's preimageHash
    /// @param amount       Token amount locked in the HTLC
    /// @param token        ERC20 token locked in the HTLC
    /// @param htlcSender   Address that created the HTLC
    /// @param timelock     Timelock set at HTLC creation
    /// @param calls        Arbitrary calls to execute after redeem (e.g. DEX swap)
    /// @param sweepToken   Token to sweep to the caller (address(0) for ETH)
    /// @param minAmountOut Minimum balance required before sweeping
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
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // HTLC.redeem(sig) recovers claimAddress from the signature and sends tokens
        // to msg.sender (this coordinator). The signature includes address(this) as caller.
        address claimAddress = HTLC.redeem(preimage, amount, token, htlcSender, timelock, v, r, s);

        // Only the claimAddress can call this — prevents front-running
        if (claimAddress != msg.sender) revert InvalidClaimer();

        _executeCalls(calls);
        _sweep(msg.sender, sweepToken, minAmountOut);
    }

    /// @notice Refund an expired HTLC created via this coordinator, execute the
    ///         pre-committed calls, then sweep the result to the original depositor
    /// @dev Permissionless — anyone can trigger this after timelock expiry. The calls
    ///      must match the refundCallsHash committed at creation time. If refundCallsHash
    ///      was bytes32(0), calls must be empty (direct sweep only).
    /// @param preimageHash The preimage hash used at HTLC creation
    /// @param amount       Token amount locked in the HTLC
    /// @param token        ERC20 token locked in the HTLC
    /// @param claimAddress Claim address set at HTLC creation
    /// @param timelock     Timelock set at HTLC creation
    /// @param calls        Arbitrary calls to execute after refund — must hash to the
    ///                     committed refundCallsHash (empty if hash was bytes32(0))
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
        Deposit memory deposit = deposits[key];
        if (deposit.depositor == address(0)) revert UnknownHTLC();

        // Verify calls match the commitment made at creation
        if (deposit.refundCallsHash == bytes32(0)) {
            // No calls committed — only a direct sweep is allowed
            if (calls.length != 0) revert RefundCallsMismatch();
        } else {
            if (keccak256(abi.encode(calls)) != deposit.refundCallsHash) {
                revert RefundCallsMismatch();
            }
        }

        delete deposits[key];

        HTLC.refund(preimageHash, amount, token, claimAddress, timelock);

        if (calls.length > 0) {
            _executeCalls(calls);
        }

        _sweep(deposit.depositor, sweepToken, minAmountOut);
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
        Deposit memory deposit = deposits[key];
        if (deposit.depositor == address(0)) revert UnknownHTLC();

        delete deposits[key];

        HTLC.refund(preimageHash, amount, token, claimAddress, timelock, deposit.depositor);
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
        if (balance == 0) revert InsufficientBalance();

        IERC20(token).forceApprove(address(HTLC), balance);
        HTLC.create(preimageHash, balance, token, refundAddress, claimAddress, timelock);
    }

    function _executeCalls(Call[] calldata calls) internal {
        uint256 length = calls.length;
        for (uint256 i = 0; i < length; i++) {
            Call calldata c = calls[i];
            _revertIfRestricted(c.target);

            (bool success,) = c.target.call{value: c.value}(c.callData);
            if (!success) revert CallFailed(i);
        }
    }

    function _sweep(address destination, address token, uint256 minAmountOut) internal {
        uint256 balance;
        if (token == address(0)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }

        if (balance < minAmountOut) revert InsufficientBalance();
        if (balance == 0) return;

        if (token == address(0)) {
            (bool success,) = payable(destination).call{value: balance}("");
            if (!success) revert CallFailed(type(uint256).max);
        } else {
            IERC20(token).safeTransfer(destination, balance);
        }
    }

    function _revertIfRestricted(address target) internal view {
        if (target == address(HTLC) || target == address(this)) {
            revert RestrictedTarget();
        }
    }

    /// @dev Accept ETH (e.g. from Uniswap refunds or WETH unwrapping)
    receive() external payable {}
}
