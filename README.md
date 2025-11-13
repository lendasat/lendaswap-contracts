# Lendaswap Atomic Swap Smart Contracts

Smart contracts for atomic swaps between Bitcoin (via Lightning or Arkade) and Polygon tokens using Hash Time Locked
Contracts (HTLCs).

## Features

- **HTLC-based Atomic Swaps**: Trustless swaps using hash locks and timelocks
- **Uniswap V3 Integration**: Automatic token swapping on Polygon
- **Gasless Transactions**: ERC-2771 meta-transaction support for gasless execution
- **Security**: Built with OpenZeppelin contracts, ReentrancyGuard, and SafeERC20

## Contracts

### AtomicSwapHTLC

**Purpose**: Convert Bitcoin to any Polygon token (e.g., Bitcoin → USDC)

This contract locks WBTC tokens and swaps them to a desired token when claimed:

1. **Create**: User locks WBTC with a hash lock and timelock
2. **Claim**: Recipient reveals secret → WBTC is swapped to desired token (e.g., USDC) via Uniswap → Tokens sent to
   recipient
3. **Refund**: If not claimed, sender can recover their WBTC after timelock expires

### ReverseAtomicSwapHTLC

**Purpose**: Convert any Polygon token to Bitcoin (e.g., USDC → Bitcoin)

This contract locks any token and swaps to WBTC when claimed:

1. **Create**: User locks tokens (e.g., USDC) with a hash lock and timelock
2. **Claim**: Recipient reveals secret → Tokens swapped to WBTC via Uniswap → WBTC sent to recipient
3. **Refund**: If not claimed, sender can recover their tokens after timelock expires

### Key Parameters

- `swapId`: Unique identifier for the swap
- `hashLock`: SHA-256 hash of the secret (shared between both chains)
- `timelock`: Unix timestamp after which refund is possible
- `tokenIn`: Token to lock
- `tokenOut`: Token to receive after swap
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
forge test
```

Run specific test:

```bash
forge test --match-test testClaimSwap -vvv
```

Run with gas reporting:

```bash
forge test --gas-report
```

### E2E Rust Tests

End-to-end integration tests using `alloy-rs`:

```bash
cd tests
./run_tests.sh -- --nocapture
```

The E2E test suite covers:

- Local blockchain setup (Anvil)
- Contract deployment
- Complete swap lifecycle (create → claim)
- Uniswap integration
- Token transfers

## Deployment

### Deploy to Polygon Testnet (Mumbai)

```bash
forge script script/DeployHTLC.s.sol:DeployHTLC \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

### Deploy to Polygon Mainnet

```bash
forge script script/DeployHTLC.s.sol:DeployHTLC \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --chain-id 137
```

Deployment addresses will be saved to `deployments.json`.

## Gasless Execution

The contract supports **ERC-2771 meta-transactions** via the deployed `ERC2771Forwarder`. This allows users to claim
swaps **without holding POL** for gas fees - perfect for your Bitcoin↔Polygon bridge where users shouldn't need to buy
gas tokens.

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

- HTLC:
  - [0x5cead362b83bf96795d48e1c4ba9fda80920ce21](https://polygonscan.com/address/0x5cead362b83bf96795d48e1c4ba9fda80920ce21)
- Reverse HTLC:
  - [0xc4827aF7Ba7A78Ff58d7988A84D455eDdcfb528F](https://polygonscan.com/address/0xc4827aF7Ba7A78Ff58d7988A84D455eDdcfb528F)

- WBTC: `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6`
- USDC: `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`
- USDT0: `0xc2132D05D31c914a87C6611C10748AEb04B58e8F`
- Uniswap V3 Router: `0xE592427A0AEce92De3Edee1F18E0157C05861564`

## License

MIT
