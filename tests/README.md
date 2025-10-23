# Lendaswap E2E Tests

End-to-end integration tests for the Lendaswap atomic swap smart contracts, written in Rust using `alloy-rs`.

## Overview

These tests verify the complete atomic swap flow:
1. **Setup**: Local blockchain (Anvil) with test accounts
2. **Deploy**: Smart contracts (HTLC, Forwarder, Mock tokens)
3. **Create Swap**: Alice locks WBTC with hash lock and timelock
4. **Claim Swap**: Bob reveals secret and receives USDC via Uniswap

## Prerequisites

- Rust toolchain installed
- Foundry installed (for `anvil`)
- Contracts compiled (`forge build` in parent directory)

## Running Tests

### Quick Start

```bash
# From the contracts/tests directory
source ~/.zshenv && cargo test -- --nocapture
```

### Run Specific Test

```bash
source ~/.zshenv && cargo test test_e2e_atomic_swap_happy_path -- --nocapture
```

### Without Output

```bash
source ~/.zshenv && cargo test
```

## Test Structure

### `e2e_swap.rs`

Complete happy path test covering:

- ✅ Local blockchain setup (Anvil)
- ✅ Contract deployments
- ✅ Token minting and approvals
- ✅ Swap creation with hash lock
- ✅ Swap claim with secret reveal
- ✅ Automatic Uniswap swap execution
- ✅ Token transfers to recipient
- ✅ State verification

### Contract Bindings

The tests use `alloy::sol!` macro to generate type-safe contract bindings from compiled artifacts:

```rust
sol!(AtomicSwapHTLC, "../out/AtomicSwapHTLC.sol/AtomicSwapHTLC.json");
```

This provides:
- Type-safe function calls
- Automatic ABI encoding/decoding
- Event parsing
- Error handling

## Test Output

```
=== Starting E2E Atomic Swap Test ===

1. Setting up local blockchain (Anvil)...
   ✓ Anvil running at: http://localhost:51159/
   ✓ Alice address: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
   ✓ Bob address: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8

2. Deploying smart contracts...
   ✓ WBTC deployed
   ✓ USDC deployed
   ✓ Router deployed
   ✓ Forwarder deployed
   ✓ HTLC deployed

3. Setting up swap parameters...
   ✓ Secret generated
   ✓ Hash lock created

4. Creating atomic swap...
   ✓ Tokens approved
   ✓ Swap created on-chain
   ✓ HTLC holds tokens

5. Executing swap (Bob claims with secret)...
   ✓ Secret revealed
   ✓ Uniswap swap executed
   ✓ Tokens transferred to Bob

=== E2E Test Completed Successfully ===
```

## Integrating with Your Project

To use these patterns in your main Rust backend:

### 1. Add Dependencies

```toml
[dependencies]
alloy = { version = "0.7", features = ["full", "sol-types"] }
```

### 2. Generate Contract Bindings

```rust
use alloy::sol;

sol! {
    #[sol(rpc)]
    AtomicSwapHTLC,
    "path/to/AtomicSwapHTLC.json"
}
```

### 3. Create Swap

```rust
let provider = ProviderBuilder::new()
    .with_recommended_fillers()
    .wallet(wallet)
    .on_http(rpc_url);

let htlc = AtomicSwapHTLC::new(htlc_address, &provider);

// Generate secret (coordinate with Bitcoin side)
let secret = FixedBytes::<32>::from(random_bytes());
let hash_lock = sha256(&secret);

// Create swap
let tx = htlc
    .createSwap(
        swap_id,
        recipient,
        wbtc_address,
        usdc_address,
        amount,
        hash_lock,
        timelock,
        pool_fee
    )
    .send()
    .await?
    .get_receipt()
    .await?;
```

### 4. Claim Swap

```rust
// After Bitcoin side completes, reveal secret
let tx = htlc
    .claimSwap(swap_id, secret)
    .send()
    .await?
    .get_receipt()
    .await?;
```

## Troubleshooting

### "No such file or directory" for anvil

Make sure to source your shell environment:
```bash
source ~/.zshenv && cargo test
```

Or add Foundry to your PATH:
```bash
export PATH="$HOME/.foundry/bin:$PATH"
```

### Contract artifacts not found

Compile contracts first:
```bash
cd ..
forge build
cd tests
```

### Test timeout

Increase timeout in Cargo.toml:
```toml
[profile.test]
timeout = 300  # 5 minutes
```

## Next Steps

Future test scenarios to add:

- ⏳ **Refund test**: Test timelock expiration and refund flow
- ⏳ **Invalid secret test**: Attempt claim with wrong secret
- ⏳ **Multiple concurrent swaps**: Test multiple users swapping simultaneously
- ⏳ **Meta-transaction test**: Test gasless claims via ERC-2771
- ⏳ **Slippage test**: Test with price changes during swap

## License

MIT
