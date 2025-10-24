# Gelato Relay Integration Guide

Complete guide for implementing gasless transactions in production using Gelato Relay.

## Overview

Gelato Relay is a production-ready infrastructure for executing meta-transactions (ERC-2771) without requiring users to hold gas tokens. This is perfect for your Bitcoin ↔ Polygon atomic swap bridge where users shouldn't need POL tokens to claim their swaps.

## How It Works

```
┌─────────┐          ┌──────────────┐          ┌────────────┐
│   Bob   │          │ Gelato Relay │          │   HTLC     │
│ (User)  │          │  (Service)   │          │ Contract   │
└─────────┘          └──────────────┘          └────────────┘
     │                       │                        │
     │ 1. Sign Meta-Tx       │                        │
     │  (EIP-712)           │                        │
     │ - NO gas needed!      │                        │
     │                       │                        │
     │ 2. Submit Request     │                        │
     │──────────────────────>│                        │
     │                       │                        │
     │                       │ 3. Execute via         │
     │                       │    Forwarder           │
     │                       │───────────────────────>│
     │                       │   (Gelato pays gas)    │
     │                       │                        │
     │                       │<───────────────────────│
     │                       │    4. Success          │
     │<──────────────────────│                        │
     │    5. Confirmation    │                        │
```

## Setup

### 1. Install Gelato SDK

Add to your `Cargo.toml`:

```toml
[dependencies]
reqwest = { version = "0.12", features = ["json"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
```

### 2. Get Gelato API Key

1. Go to [Gelato Dashboard](https://app.gelato.network/)
2. Create an account
3. Create a new Relay project
4. Note your API key
5. Fund your account for gas sponsorship

### 3. Configure Environment

```bash
# Add to .env
GELATO_API_KEY=your_api_key_here
GELATO_RELAY_URL=https://relay.gelato.digital
```

## Implementation

### Client-Side: Sign Meta-Transaction

This is what Bob (the user) does. **No gas tokens needed!**

```rust
use alloy::primitives::Address;
use alloy::primitives::Bytes;
use alloy::primitives::FixedBytes;
use alloy::primitives::U256;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::SolStruct;

sol! {
    struct ForwardRequest {
        address from;
        address to;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        uint256 deadline;
        bytes data;
    }
}

pub async fn create_gasless_claim_request(
    bob_signer: &PrivateKeySigner,
    htlc_address: Address,
    forwarder_address: Address,
    swap_id: FixedBytes<32>,
    secret: FixedBytes<32>,
    nonce: U256,
) -> Result<GelatoRequest> {
    let bob_address = bob_signer.address();

    // 1. Prepare the claimSwap call data
    let claim_call = AtomicSwapHTLC::claimSwapCall {
        swapId: swap_id,
        secret,
    };
    let call_data = claim_call.abi_encode();

    // 2. Get deadline (current time + 5 minutes)
    let deadline = U256::from(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() + 300);

    // 3. Create ForwardRequest
    let request = ForwardRequest {
        from: bob_address,
        to: htlc_address,
        value: U256::ZERO,
        gas: U256::from(300000u64),
        nonce,
        deadline,
        data: Bytes::from(call_data),
    };

    // 4. Create EIP-712 domain for the forwarder
    let domain = alloy::sol_types::eip712_domain! {
        name: "LendaswapForwarder",
        version: "1",
        chain_id: 137, // Polygon mainnet
        verifying_contract: forwarder_address,
    };

    // 5. Sign with EIP-712
    let signature = bob_signer.sign_typed_data(&request, &domain).await?;

    // 6. Return Gelato-compatible request
    Ok(GelatoRequest {
        chain_id: 137,
        target: forwarder_address,
        data: encode_execute_call(request, signature.as_bytes()),
        fee_token: "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE".to_string(), // Native token
        is_relayed_call: true,
    })
}

fn encode_execute_call(request: ForwardRequest, signature: &[u8]) -> String {
    let execute_call = ERC2771Forwarder::executeCall {
        request: ERC2771Forwarder::ForwardRequestData {
            from: request.from,
            to: request.to,
            value: request.value,
            gas: request.gas,
            deadline: request.deadline,
            data: request.data,
            signature: Bytes::from(signature.to_vec()),
        },
    };

    format!("0x{}", hex::encode(execute_call.abi_encode()))
}
```

### Server-Side: Submit to Gelato

This is what your backend does (or Bob can do directly from browser).

```rust
use reqwest::Client;
use serde::Deserialize;
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GelatoRequest {
    chain_id: u64,
    target: Address,
    data: String,
    fee_token: String,
    is_relayed_call: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GelatoResponse {
    task_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TaskStatus {
    task_state: String,
    transaction_hash: Option<String>,
    block_number: Option<u64>,
}

pub async fn submit_to_gelato(api_key: &str, request: GelatoRequest) -> Result<String> {
    let client = Client::new();

    let response = client
        .post("https://relay.gelato.digital/relays/v2/sponsored-call")
        .header("Content-Type", "application/json")
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&request)
        .send()
        .await?;

    if !response.status().is_success() {
        let error_text = response.text().await?;
        anyhow::bail!("Gelato API error: {}", error_text);
    }

    let gelato_response: GelatoResponse = response.json().await?;

    Ok(gelato_response.task_id)
}

pub async fn check_task_status(api_key: &str, task_id: &str) -> Result<TaskStatus> {
    let client = Client::new();

    let response = client
        .get(format!(
            "https://relay.gelato.digital/tasks/status/{}",
            task_id
        ))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await?;

    let status: TaskStatus = response.json().await?;
    Ok(status)
}
```

### Complete Integration Example

```rust
use anyhow::Result;

pub struct GaslessSwapClaimer {
    gelato_api_key: String,
    forwarder_address: Address,
    htlc_address: Address,
    chain_id: u64,
}

impl GaslessSwapClaimer {
    pub async fn claim_swap_gasless(
        &self,
        bob_signer: &PrivateKeySigner,
        swap_id: FixedBytes<32>,
        secret: FixedBytes<32>,
    ) -> Result<String> {
        println!("Creating gasless claim request for Bob...");

        // 1. Get Bob's nonce from forwarder
        let provider = ProviderBuilder::new().on_http(polygon_rpc_url);
        let forwarder = ERC2771Forwarder::new(self.forwarder_address, &provider);
        let nonce = forwarder.nonces(bob_signer.address()).call().await?._0;

        // 2. Create and sign the meta-transaction
        let gelato_request = create_gasless_claim_request(
            bob_signer,
            self.htlc_address,
            self.forwarder_address,
            swap_id,
            secret,
            nonce,
        )
        .await?;

        // 3. Submit to Gelato
        println!("Submitting to Gelato Relay...");
        let task_id = submit_to_gelato(&self.gelato_api_key, gelato_request).await?;
        println!("Task submitted! ID: {}", task_id);

        // 4. Wait for execution
        let tx_hash = self.wait_for_execution(&task_id).await?;
        println!("Transaction executed! Hash: {}", tx_hash);

        Ok(tx_hash)
    }

    async fn wait_for_execution(&self, task_id: &str) -> Result<String> {
        use tokio::time::sleep;
        use tokio::time::Duration;

        for _ in 0..60 {
            // Try for 1 minute
            let status = check_task_status(&self.gelato_api_key, task_id).await?;

            match status.task_state.as_str() {
                "ExecSuccess" => {
                    return Ok(status.transaction_hash.unwrap());
                }
                "ExecReverted" | "Cancelled" => {
                    anyhow::bail!("Task failed: {}", status.task_state);
                }
                "CheckPending" | "ExecPending" | "WaitingForConfirmation" => {
                    println!("Status: {}...", status.task_state);
                    sleep(Duration::from_secs(1)).await;
                }
                _ => {
                    println!("Unknown status: {}", status.task_state);
                    sleep(Duration::from_secs(1)).await;
                }
            }
        }

        anyhow::bail!("Task timeout")
    }
}
```

## Integration with Your Lendaswap Backend

In your `swap_processor.rs`:

```rust
// OLD: Bob pays gas directly
let tx = htlc.claimSwap(swap_id, secret).send().await?;

// NEW: Gasless via Gelato
let claimer = GaslessSwapClaimer {
    gelato_api_key: env::var("GELATO_API_KEY")?,
    forwarder_address: env::var("FORWARDER_ADDRESS")?.parse()?,
    htlc_address: env::var("HTLC_ADDRESS")?.parse()?,
    chain_id: 137,
};

let tx_hash = claimer.claim_swap_gasless(
    &bob_signer,
    swap_id,
    secret,
).await?;
```

## Cost Management

### Gas Sponsorship

You pay for users' gas via Gelato:

1. **Deposit POL** to your Gelato account
2. **Set spending limits** per day/month
3. **Monitor usage** in Gelato dashboard

### Estimated Costs

- `claimSwap` execution: ~150,000 gas
- Gelato fee: ~10% overhead
- Total cost per swap: ~$0.01-0.05 (depending on POL price)

### Cost Optimization

```rust
// Option 1: Only sponsor small amounts
if swap.usd_amount < 100.0 {
    claim_gasless(bob, swap_id, secret).await?;
} else {
    // User pays their own gas for large amounts
    claim_normal(bob, swap_id, secret).await?;
}

// Option 2: Charge a small fee and sponsor all
let fee_percentage = 0.5; // 0.5%
let fee_amount = swap.usd_amount * fee_percentage / 100.0;
// Deduct fee and sponsor the claim
```

## Testing

### Local Testing

Use the E2E test we created:

```bash
cd contracts/tests
./run_tests.sh --test e2e_gasless_swap -- --nocapture
```

This simulates the exact flow without needing Gelato API keys.

### Testnet Testing

1. Deploy contracts to Polygon Mumbai testnet
2. Use Gelato's testnet endpoint
3. Get free test POL from faucet
4. Test with real Gelato integration

## Troubleshooting

### "Insufficient funds"

- Fund your Gelato account with POL
- Check balance in Gelato dashboard

### "Invalid signature"

- Ensure EIP-712 domain matches deployed forwarder
- Check chain ID (137 for mainnet, 80001 for Mumbai)
- Verify nonce is correct

### "Transaction reverted"

- Check if swap is still open
- Verify secret is correct
- Ensure timelock hasn't expired

## Alternative: OpenZeppelin Defender

If you prefer OpenZeppelin Defender instead of Gelato:

```rust
// Submit to Defender Relay API
let response = client
    .post("https://api.defender.openzeppelin.com/relayer/...")
    .header("X-Api-Key", defender_api_key)
    .json(&request)
    .send()
    .await?;
```

Both services support ERC-2771 and work with the same contract implementation.

## Security Considerations

1. **Deadline**: Always set reasonable deadlines (5-10 minutes)
2. **Nonce Management**: Track nonces to prevent replay attacks
3. **Rate Limiting**: Limit requests per user to prevent abuse
4. **Monitoring**: Alert on unusual gas consumption
5. **Fallback**: Allow direct execution if Gelato is down

## Production Checklist

- [ ] Deploy contracts to Polygon mainnet
- [ ] Get Gelato API key and fund account
- [ ] Set environment variables
- [ ] Test on Mumbai testnet first
- [ ] Implement error handling and retries
- [ ] Set up monitoring and alerts
- [ ] Configure spending limits
- [ ] Document for users

## Resources

- [Gelato Relay Docs](https://docs.gelato.network/developer-services/relay)
- [ERC-2771 Specification](https://eips.ethereum.org/EIPS/eip-2771)
- [OpenZeppelin Defender](https://docs.openzeppelin.com/defender/)
- [Lendaswap E2E Test](./tests/e2e_gasless_swap.rs)

## Support

For Gelato-specific issues:

- Discord: https://discord.gg/gelato
- Telegram: https://t.me/gelatonetwork

For contract issues:

- Open an issue in this repository
