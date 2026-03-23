# Lendaswap Atomic Swap Smart Contracts

Smart contracts for atomic swaps between Bitcoin (via Lightning, Arkade, or on-chain) and EVM tokens using Hash Time
Locked Contracts (HTLCs). Deployed on Polygon, Ethereum, and Arbitrum.

## Features

- **HTLC-based Atomic Swaps**: Trustless swaps using hash locks and timelocks
- **Multi-chain**: Deployed on Polygon, Ethereum, and Arbitrum
- **DEX Integration**: Arbitrary call execution for on-chain token swaps (e.g., Uniswap V3)
- **Gasless Transactions**: EIP-712 signature-based redeem/refund (no gas needed for the claimer)
- **Permit2 Support**: Gasless token approvals via Uniswap Permit2
- **Security**: OpenZeppelin SafeERC20, transient-storage reentrancy guard (EIP-1153)

## Contracts

### HTLCErc20

**Purpose**: Lock and release ERC20 tokens in a hash time-locked swap.

Minimal storage design — only a single `bool` per swap. All parameters are verified via hash on redeem/refund.

1. **Create**: Lock ERC20 tokens with a preimage hash and timelock
2. **Redeem**: Claim address reveals preimage to unlock tokens (supports EIP-712 signatures)
3. **Refund**: Sender reclaims tokens after timelock expiry (supports EIP-712 signatures)

### HTLCCoordinator

**Purpose**: Compose arbitrary calls (e.g., DEX swaps) with HTLC create/redeem/refund in a single transaction.

Three primary flows:

1. **executeAndCreate**: Run arbitrary calls (e.g., swap USDC to WBTC via Uniswap), then lock the resulting tokens in an
   HTLC. Uses Permit2 for gasless token approvals.
2. **redeemAndExecute**: Redeem tokens from an HTLC via EIP-712 signature, run arbitrary calls (e.g., swap WBTC to
   USDC), then sweep the result to the caller.
3. **refundAndExecute**: Refund an expired HTLC, run arbitrary calls (e.g., swap back to original token), then sweep to
   the original depositor.

### Key Parameters

- `preimageHash`: SHA-256 hash of the secret (compatible with Bitcoin HTLC scripts)
- `timelock`: Unix timestamp after which refund is possible
- `token`: ERC20 token address to lock
- `claimAddress`: Address authorized to redeem (prevents front-running)
- `refundAddress`: Address that can reclaim after timelock

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
```

## Testing

Run all tests:

```bash
forge test
```

## Gasless Execution

Both contracts support **EIP-712 signature-based** gasless execution. Users sign a typed message off-chain, and a
relayer submits the transaction and pays gas.

### How It Works

```
User signs EIP-712 msg → Submit to Relayer → Relayer executes & pays gas → User receives tokens
      (off-chain, free)                            (on-chain)                (no gas needed!)
```

- **HTLCErc20**: Redeem and refund both accept EIP-712 signatures, allowing a third party to submit on behalf of the
  user.
- **HTLCCoordinator**: Uses Permit2 for gasless token approvals on `executeAndCreate`.

### Testing Gasless Execution

```bash
cd tests
./run_tests.sh --test e2e_gasless_swap -- --nocapture
```

See [`tests/tests/e2e_gasless_swap.rs`](tests/tests/e2e_gasless_swap.rs) for implementation details.

## Security Considerations

1. **Secret Management**: Use cryptographically secure random generation. Hash with SHA-256 (same as Bitcoin).
2. **Timelock Values**: Coordinate with Bitcoin-side timelock (should be longer on Bitcoin). Typical: 1-24 hours.
3. **Slippage Protection**: Set proper `minAmountOut` when using the coordinator with DEX calls.
4. **Front-running**: `claimAddress` is part of the swap key — only that address can redeem.

## Contract Addresses

### Polygon (Chain ID: 137)

- HTLCErc20: [`0x5317dccd55dde04d5f7ba2e34fe8b1b214f1e022`](https://polygonscan.com/address/0x5317dccd55dde04d5f7ba2e34fe8b1b214f1e022)
- HTLCCoordinator: [`0x57ef7025f9f6f135e8338e18eb3027acb9d4785c`](https://polygonscan.com/address/0x57ef7025f9f6f135e8338e18eb3027acb9d4785c)

Tokens:

- WBTC: `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6`

### Ethereum (Chain ID: 1)

- HTLCErc20: [`0x5317dccd55dde04d5f7ba2e34fe8b1b214f1e022`](https://etherscan.io/address/0x5317dccd55dde04d5f7ba2e34fe8b1b214f1e022)
- HTLCCoordinator: [`0x57ef7025f9f6f135e8338e18eb3027acb9d4785c`](https://etherscan.io/address/0x57ef7025f9f6f135e8338e18eb3027acb9d4785c)

Tokens:

- tBTC: `0x18084fba666a33d37592fa2633fd49a74dd93a88`

### Arbitrum (Chain ID: 42161)

- HTLCErc20: [`0x5317dccd55dde04d5f7ba2e34fe8b1b214f1e022`](https://arbiscan.io/address/0x5317dccd55dde04d5f7ba2e34fe8b1b214f1e022)
- HTLCCoordinator: [`0x57ef7025f9f6f135e8338e18eb3027acb9d4785c`](https://arbiscan.io/address/0x57ef7025f9f6f135e8338e18eb3027acb9d4785c)

Tokens:

- tBTC: `0x6c84a8f1c29108F47a79964b5Fe888D4f4D0dE40`

## License

MIT
