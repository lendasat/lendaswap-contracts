// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

/// @title AtomicSwapHTLC - Hash Time Locked Contract for Atomic Swaps with Uniswap Integration
/// @notice Enables gasless atomic swaps between Bitcoin and Polygon tokens
/// @dev Uses ERC-2771 for meta-transactions (gasless execution) and HTLCs for atomic swaps
contract AtomicSwapHTLCRecoverable is ERC2771Context, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Events
    event SwapCreated(
        bytes32 indexed swapId,
        address indexed sender,
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes32 hashLock,
        uint256 timelock,
        uint24 poolFee,
        uint256 minAmountOut
    );
    event SwapClaimed(bytes32 indexed swapId, bytes32 secret);
    event SwapRefunded(bytes32 indexed swapId);
    event TokensRecovered(address indexed token, address indexed recipient, uint256 amount);

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
        address tokenIn; // Token to lock (e.g., WBTC)
        address tokenOut; // Token to receive after swap (e.g., USDC)
        uint256 amountIn;
        bytes32 hashLock; // Hash of the secret (preimage)
        uint256 timelock; // Unix timestamp after which refund is possible
        SwapState state;
        uint24 poolFee; // Uniswap pool fee (e.g., 3000 = 0.3%)
        uint256 minAmountOut; // Minimum amount of tokenOut to receive (slippage protection)
    }

    // State variables
    ISwapRouter public immutable swapRouter;
    mapping(bytes32 => Swap) public swaps;

    /// @notice Constructor
    /// @param _swapRouter Uniswap V3 SwapRouter address
    /// @param _trustedForwarder ERC-2771 trusted forwarder for meta-transactions
    constructor(
        address _swapRouter,
        address _trustedForwarder
    ) ERC2771Context(_trustedForwarder) Ownable(_msgSender()) {
        require(_swapRouter != address(0), "Invalid swap router");
        swapRouter = ISwapRouter(_swapRouter);
    }

    /// @notice Create a new HTLC swap
    /// @param swapId Unique identifier for this swap
    /// @param recipient Address to receive tokens after swap
    /// @param tokenIn Token to lock (must be approved beforehand)
    /// @param tokenOut Token to receive after Uniswap swap
    /// @param amountIn Amount of tokenIn to lock
    /// @param hashLock Hash of the secret (sha256)
    /// @param timelock Unix timestamp after which refund is possible
    /// @param poolFee Uniswap pool fee tier (500, 3000, or 10000)
    /// @param minAmountOut Minimum amount of tokenOut to receive (slippage protection)
    function createSwap(
        bytes32 swapId,
        address recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes32 hashLock,
        uint256 timelock,
        uint24 poolFee,
        uint256 minAmountOut
    ) external nonReentrant {
        require(swaps[swapId].state == SwapState.INVALID, "Swap already exists");
        require(recipient != address(0), "Invalid recipient");
        require(tokenIn != address(0) && tokenOut != address(0), "Invalid tokens");
        require(amountIn > 0, "Amount must be > 0");
        require(timelock > block.timestamp, "Timelock must be in future");
        require(hashLock != bytes32(0), "Invalid hash lock");

        // Transfer tokens from sender to this contract
        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);

        // Create swap
        swaps[swapId] = Swap({
            sender: _msgSender(),
            recipient: recipient,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            hashLock: hashLock,
            timelock: timelock,
            state: SwapState.OPEN,
            poolFee: poolFee,
            minAmountOut: minAmountOut
        });

        emit SwapCreated(
            swapId,
            _msgSender(),
            recipient,
            tokenIn,
            tokenOut,
            amountIn,
            hashLock,
            timelock,
            poolFee,
            minAmountOut
        );
    }

    /// @notice Claim a swap by revealing the secret (performs Uniswap swap and sends tokens)
    /// @param swapId The swap identifier
    /// @param secret The preimage of the hash lock
    function claimSwap(bytes32 swapId, bytes32 secret) external nonReentrant {
        Swap storage swap = swaps[swapId];

        require(swap.state == SwapState.OPEN, "Swap not open");
        require(sha256(abi.encodePacked(secret)) == swap.hashLock, "Invalid secret");
        require(block.timestamp < swap.timelock, "Swap expired");

        swap.state = SwapState.CLAIMED;

        // Approve Uniswap router to spend tokens
        IERC20(swap.tokenIn).forceApprove(address(swapRouter), swap.amountIn);

        // Execute Uniswap swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: swap.tokenIn,
            tokenOut: swap.tokenOut,
            fee: swap.poolFee,
            recipient: swap.recipient,
            deadline: block.timestamp,
            amountIn: swap.amountIn,
            amountOutMinimum: swap.minAmountOut, // Slippage protection
            sqrtPriceLimitX96: 0
        });

        swapRouter.exactInputSingle(params);

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
        IERC20(swap.tokenIn).safeTransfer(swap.sender, swap.amountIn);

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

    /// @notice Emergency function to recover ERC20 tokens from the contract
    /// @dev Can recover ANY tokens including those locked in active swaps
    /// WARNING: This is an emergency function. Recovering tokens from active swaps
    /// will break those swaps and affect users. Use with extreme caution.
    /// @param token The ERC20 token address to recover
    /// @param recipient The address to send recovered tokens to
    /// @param amount The amount of tokens to recover
    function recoverTokens(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(token != address(0), "Invalid token address");
        require(recipient != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(token).safeTransfer(recipient, amount);

        emit TokensRecovered(token, recipient, amount);
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
