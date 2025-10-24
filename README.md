# Lendaswap Atomic Swap Smart Contracts

Smart contracts for atomic swaps between Bitcoin (via Arkade) and Polygon tokens using Hash Time Locked Contracts (HTLCs).

## Features

- **HTLC-based Atomic Swaps**: Trustless swaps using hash locks and timelocks
- **Uniswap V3 Integration**: Automatic token swapping on Polygon
- **Gasless Transactions**: ERC-2771 meta-transaction support for gasless execution
- **Security**: Built with OpenZeppelin contracts, ReentrancyGuard, and SafeERC20

## Architecture

### AtomicSwapHTLC Contract

The main contract that handles the swap lifecycle:

1. **Create Swap**: Lock tokens with a hash lock and timelock
2. **Claim Swap**: Reveal secret → Execute Uniswap swap → Send tokens to recipient
3. **Refund**: Return tokens to sender after timelock expires

#### Key Parameters

- `swapId`: Unique identifier for the swap
- `hashLock`: SHA-256 hash of the secret (shared with Bitcoin side)
- `timelock`: Unix timestamp after which refund is possible
- `tokenIn`: Token to lock (e.g., WBTC)
- `tokenOut`: Token to receive after swap (e.g., USDC)
- `poolFee`: Uniswap V3 pool fee tier (500/3000/10000)

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Polygon RPC URL
- Private key for deployment

## Setup

1. Navigate to the contracts directory:

```bash
cd contracts
```

2. Install dependencies:

```bash
forge install
```

3. Copy `.env.example` to `.env` and configure:

```bash
cp ../.env.example .env
```

Required environment variables:

```bash
RPC_URL=your_polygon_rpc_url
PRIVATE_KEY=your_private_key_for_deployment
UNISWAP_V3_ROUTER=0xE592427A0AEce92De3Edee1F18E0157C05861564  # Polygon
```

## Testing

Run all tests:

```bash
source ~/.zshenv && forge test
```

Run with verbose output:

```bash
source ~/.zshenv && forge test -vv
```

Run specific test:

```bash
source ~/.zshenv && forge test --match-test testClaimSwap -vvv
```

Run with gas reporting:

```bash
source ~/.zshenv && forge test --gas-report
```

### Test Coverage

**Solidity Tests** (Foundry):

- ✅ Creating swaps with proper validation
- ✅ Claiming swaps with correct secret
- ✅ Rejecting claims with wrong secret
- ✅ Refunding after timelock expiration
- ✅ Preventing refunds before timelock
- ✅ Preventing claims after timelock
- ✅ Access control (only sender can refund)
- ✅ Duplicate swap prevention
- ✅ Event emissions
- ✅ ERC-2771 meta-transaction support

### E2E Rust Tests

End-to-end integration tests using `alloy-rs`:

```bash
cd tests
./run_tests.sh -- --nocapture
```

The E2E test suite covers:

- ✅ Local blockchain setup (Anvil)
- ✅ Contract deployment
- ✅ Complete swap lifecycle (create → claim)
- ✅ Uniswap integration
- ✅ Token transfers

See [`tests/README.md`](tests/README.md) for details.

## Deployment

### Deploy to Polygon Testnet (Mumbai)

```bash
source ~/.zshenv && forge script script/DeployHTLC.s.sol:DeployHTLC \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

### Deploy to Polygon Mainnet

```bash
source ~/.zshenv && forge script script/DeployHTLC.s.sol:DeployHTLC \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --chain-id 137
```

Deployment addresses will be saved to `deployments.json`.

## Integration with Rust Backend

After deployment, integrate with your Rust backend:

1. Add contract ABIs to your Rust project
2. Use `alloy-rs` to interact with the contracts
3. Coordinate the secret reveal between Bitcoin and Polygon sides

### Example Rust Integration

```rust
use alloy::sol;

// Generate contract bindings
sol! {
    #[sol(rpc)]
    AtomicSwapHTLC,
    "contracts/out/AtomicSwapHTLC.sol/AtomicSwapHTLC.json"
}

// Create a swap
let secret = generate_random_bytes32();
let hash_lock = sha256(&secret);
let timelock = current_timestamp() + 3600; // 1 hour

let tx = contract
    .createSwap(
        swap_id,
        recipient,
        wbtc_address,
        usdc_address,
        amount,
        hash_lock,
        timelock,
        3000, // 0.3% pool fee
    )
    .send()
    .await?;
```

## Gasless Execution

The contract supports **ERC-2771 meta-transactions** via the deployed `ERC2771Forwarder`. This allows users to claim swaps **without holding POL** for gas fees - perfect for your Bitcoin↔Polygon bridge where users shouldn't need to buy gas tokens.

### How It Works

```
User signs meta-tx → Submit to Relayer → Relayer executes & pays gas → User receives tokens
     (off-chain, free)      (Gelato API)        (on-chain)               (no POL needed!)
```

### Testing Gasless Execution

Run the E2E gasless swap test:

```bash
cd tests
./run_tests.sh --test e2e_gasless_swap -- --nocapture
```

This demonstrates the complete flow:

- User signs EIP-712 meta-transaction (no gas)
- Relayer executes via `ERC2771Forwarder`
- User receives tokens without spending any ETH/POL

See [`tests/tests/e2e_gasless_swap.rs`](tests/tests/e2e_gasless_swap.rs) for implementation details.

### Production Integration

For production, integrate with a relayer service:

**Option 1: Gelato Relay** (Recommended)

- Hosted infrastructure for meta-transactions
- Easy integration with API
- Pay-per-transaction pricing
- See [`tests/GELATO_INTEGRATION.md`](tests/GELATO_INTEGRATION.md) for complete guide

**Option 2: OpenZeppelin Defender**

- Alternative hosted relayer service
- Similar capabilities to Gelato
- Good for enterprises

Both services support ERC-2771 and work with your deployed `ERC2771Forwarder`.

### Benefits

- ✅ **Better UX**: Users don't need POL tokens
- ✅ **Lower barrier**: No need to explain gas to users
- ✅ **Faster onboarding**: Users can claim immediately after Bitcoin confirmation
- ✅ **Cost effective**: ~$0.01-0.05 per swap to sponsor gas

## Security Considerations

1. **Secret Management**:
   - Keep the secret secure until ready to claim
   - Use cryptographically secure random generation for secrets
   - Hash with SHA-256 (same as Bitcoin)

2. **Timelock Values**:
   - Choose timelocks long enough for users to claim
   - Typical: 1-24 hours depending on use case
   - Coordinate with Bitcoin-side timelock (should be longer on Bitcoin)

3. **Slippage Protection**:
   - Current implementation has `amountOutMinimum: 0`
   - For production, calculate and set proper slippage limits
   - Consider using Uniswap's QuoterV2 for price checks

4. **Approvals**:
   - Users must approve the HTLC contract before creating swaps
   - The contract approves the Uniswap router during claims

## Contract Addresses

### Polygon Mainnet

- WBTC: `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6`
- USDC: `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`
- Uniswap V3 Router: `0xE592427A0AEce92De3Edee1F18E0157C05861564`

### Mumbai Testnet

- WBTC: Check Polygon docs
- USDC: Check Polygon docs
- Uniswap V3 Router: `0xE592427A0AEce92De3Edee1F18E0157C05861564`

## License

MIT
