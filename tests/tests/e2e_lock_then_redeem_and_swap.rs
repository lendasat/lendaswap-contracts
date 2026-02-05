#![allow(clippy::too_many_arguments)]

//! E2E test: Lock → Redeem-and-Swap (Polygon fork + real Uniswap V3)
//!
//! Tests `redeemAndExecute` against a **Polygon fork** with real on-chain
//! liquidity (Uniswap V3 WBTC/USDC pool).
//!
//! Flow: Alice locks WBTC directly in the HTLC (claimAddress = Bob). The hub
//! calls `coordinator.redeemAndExecute` with Bob's EIP-712 signature, which
//! redeems the WBTC, swaps WBTC→USDC via Uniswap V3, and sweeps USDC to Bob.
//! Bob receives USDC even though the hub submitted the transaction.
//!
//! This flow (`redeemAndExecute`) is only tested here — `e2e_coordinator.rs`
//! does not cover it.
//!
//! Requires `POLYGON_RPC_URL` env var and network access.
//! Run:
//!   POLYGON_RPC_URL="..." cargo test --test e2e_lock_then_redeem_and_swap -- --ignored --nocapture

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::{Address, Bytes, FixedBytes, U160, U256, address, keccak256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::signers::Signer;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::{SolCall, SolValue};
use anyhow::Result;
use sha2::{Digest, Sha256};

// ---------------------------------------------------------------------------
// Contract bindings from forge build artifacts
// ---------------------------------------------------------------------------

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    HTLCErc20,
    "../out/HTLCErc20.sol/HTLCErc20.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    HTLCCoordinator,
    "../out/HTLCCoordinator.sol/HTLCCoordinator.json"
);

// ---------------------------------------------------------------------------
// Inline ABI fragments for on-chain contracts (IERC20, Uniswap V3 Router)
// ---------------------------------------------------------------------------

sol! {
    #[sol(rpc)]
    interface IERC20 {
        function balanceOf(address account) external view returns (uint256);
        function approve(address spender, uint256 amount) external returns (bool);
        function transfer(address to, uint256 amount) external returns (bool);
        function transferFrom(address from, address to, uint256 amount) external returns (bool);
    }
}

sol! {
    #[sol(rpc)]
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

        function exactInputSingle(ExactInputSingleParams calldata params)
            external
            payable
            returns (uint256 amountOut);
    }
}

// ---------------------------------------------------------------------------
// Polygon mainnet constants
// ---------------------------------------------------------------------------

/// USDC (native, 6 decimals) on Polygon
const USDC: Address = address!("3c499c542cEF5E3811e1192ce70d8cC03d5c3359");
/// WBTC (8 decimals) on Polygon
const WBTC: Address = address!("1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6");
/// Uniswap V3 SwapRouter on Polygon
const UNISWAP_ROUTER: Address = address!("E592427A0AEce92De3Edee1F18E0157C05861564");
/// 0.05% fee tier
const POOL_FEE: u32 = 500;
/// 0.001 WBTC (8 decimals)
const WBTC_TEST_AMOUNT: u128 = 100_000; // 0.001e8
/// Fork block — chosen so the whale has sufficient balance
const FORK_BLOCK: u64 = 82_488_076;
/// Known WBTC whale on Polygon
const WBTC_WHALE: Address = address!("0x0AFF6665bB45bF349489B20E225A6c5D78E2280F");

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore] // requires POLYGON_RPC_URL and network access
async fn test_e2e_lock_then_redeem_and_swap() -> Result<()> {
    // -----------------------------------------------------------------------
    // 0. Setup: fork Polygon at pinned block
    // -----------------------------------------------------------------------
    let rpc_url =
        std::env::var("POLYGON_RPC_URL").expect("Set POLYGON_RPC_URL to a Polygon RPC endpoint");

    println!("\n=== E2E: Lock → Redeem-and-Swap (Polygon Fork) ===\n");
    println!("Forking Polygon at block {FORK_BLOCK} ...");

    let anvil = Anvil::new()
        .fork(&rpc_url)
        .fork_block_number(FORK_BLOCK)
        .try_spawn()?;

    let endpoint = anvil.endpoint_url();

    // Alice — locks WBTC in the HTLC
    let alice_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_address = alice_key.address();
    let alice_wallet = EthereumWallet::from(alice_key);
    let alice_provider = ProviderBuilder::new()
        .wallet(alice_wallet)
        .connect_http(endpoint.clone());

    // Bob — the intended recipient of the swapped USDC
    let bob_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_address = bob_key.address();

    // Hub — deploys contracts and calls redeemAndExecute on behalf of Bob
    let hub_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let hub_address = hub_key.address();
    let hub_wallet = EthereumWallet::from(hub_key.clone());
    let hub_provider = ProviderBuilder::new()
        .wallet(hub_wallet)
        .connect_http(endpoint.clone());

    // Non-wallet provider for raw RPC calls (impersonation)
    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());

    println!("  Alice: {alice_address}");
    println!("  Bob:   {bob_address}");
    println!("  Hub:   {hub_address}");

    // -----------------------------------------------------------------------
    // 1. Deploy HTLCErc20 + HTLCCoordinator (by hub)
    // -----------------------------------------------------------------------
    println!("\n1. Deploying contracts ...");

    let htlc = HTLCErc20::deploy(&hub_provider).await?;
    let htlc_address = *htlc.address();
    println!("   HTLCErc20 at {htlc_address} (deployed by hub)");

    let coordinator = HTLCCoordinator::deploy(&hub_provider, htlc_address).await?;
    let coordinator_address = *coordinator.address();
    println!("   HTLCCoordinator at {coordinator_address} (deployed by hub)");

    // -----------------------------------------------------------------------
    // 2. Impersonate WBTC whale → fund Alice with WBTC
    // -----------------------------------------------------------------------
    println!("\n2. Funding Alice with WBTC from whale ...");

    let wbtc_on_raw = IERC20::new(WBTC, &raw_provider);

    // Check whale balance first
    let whale_balance = wbtc_on_raw.balanceOf(WBTC_WHALE).call().await?;
    println!("   Whale WBTC balance: {whale_balance}");
    assert!(
        whale_balance >= U256::from(WBTC_TEST_AMOUNT),
        "Whale has insufficient WBTC at block {FORK_BLOCK}"
    );

    // Impersonate
    raw_provider
        .raw_request::<_, ()>(
            "anvil_impersonateAccount".into(),
            &[format!("{WBTC_WHALE:?}")],
        )
        .await?;

    // Transfer WBTC from whale to Alice
    IERC20::new(WBTC, &raw_provider)
        .transfer(alice_address, U256::from(WBTC_TEST_AMOUNT))
        .from(WBTC_WHALE)
        .send()
        .await?
        .get_receipt()
        .await?;

    // Stop impersonating
    raw_provider
        .raw_request::<_, ()>(
            "anvil_stopImpersonatingAccount".into(),
            &[format!("{WBTC_WHALE:?}")],
        )
        .await?;

    let alice_wbtc_before = IERC20::new(WBTC, &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    println!("   Alice WBTC balance: {alice_wbtc_before}");
    assert_eq!(alice_wbtc_before, U256::from(WBTC_TEST_AMOUNT));

    // -----------------------------------------------------------------------
    // 3. Alice locks WBTC in the HTLC (recipient = coordinator)
    // -----------------------------------------------------------------------
    println!("\n3. Alice locking WBTC in HTLC ...");

    let block = alice_provider.get_block_number().await?;
    let block_ts = raw_provider
        .get_block_by_number(block.into())
        .await?
        .expect("block exists")
        .header
        .timestamp;

    // Preimage / hash
    let preimage = FixedBytes::<32>::from([0xCDu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));
    let timelock = U256::from(block_ts + 3600); // 1 hour

    // Alice approves HTLC to pull her WBTC
    IERC20::new(WBTC, &alice_provider)
        .approve(htlc_address, U256::from(WBTC_TEST_AMOUNT))
        .send()
        .await?
        .get_receipt()
        .await?;

    // Alice creates the HTLC: sender=Alice, claimAddress=hub
    // In V2, hub is the claimAddress (coordinator verifies claimAddress == msg.sender)
    let htlc_as_alice = HTLCErc20::new(htlc_address, &alice_provider);
    htlc_as_alice
        .create_1(
            preimage_hash,
            U256::from(WBTC_TEST_AMOUNT),
            WBTC,
            hub_address, // claimAddress = hub (hub calls redeemAndExecute)
            timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    // Verify lock
    let htlc_reader = HTLCErc20::new(htlc_address, &alice_provider);
    let is_active = htlc_reader
        .isActive(
            preimage_hash,
            U256::from(WBTC_TEST_AMOUNT),
            WBTC,
            alice_address, // sender = Alice
            hub_address,   // claimAddress = hub
            timelock,
        )
        .call()
        .await?;
    println!("   isActive (sender=Alice, claimAddress=hub): {is_active}");
    assert!(is_active, "HTLC should be active");

    let htlc_wbtc = IERC20::new(WBTC, &alice_provider)
        .balanceOf(htlc_address)
        .call()
        .await?;
    println!("   WBTC locked in HTLC: {htlc_wbtc}");

    // -----------------------------------------------------------------------
    // 4. Hub calls coordinator.redeemAndExecute on behalf of Bob
    //    Coordinator redeems WBTC → swaps WBTC→USDC on Uniswap → USDC to Bob
    // -----------------------------------------------------------------------
    println!("\n4. Hub calling redeemAndExecute (funds → Bob) ...");

    let bob_usdc_before = IERC20::new(USDC, &raw_provider)
        .balanceOf(bob_address)
        .call()
        .await?;

    let deadline = U256::from(block_ts + 600);

    // Call 0: WBTC.approve(uniswapRouter, amount)
    let call0_data = IERC20::approveCall {
        spender: UNISWAP_ROUTER,
        amount: U256::from(WBTC_TEST_AMOUNT),
    }
    .abi_encode();

    // Call 1: router.exactInputSingle(WBTC → USDC, recipient = Bob)
    //         Funds go directly to Bob, not the coordinator
    let swap_params = ISwapRouter::ExactInputSingleParams {
        tokenIn: WBTC,
        tokenOut: USDC,
        fee: POOL_FEE.try_into().unwrap(),
        recipient: bob_address, // ← funds go directly to Bob
        deadline,
        amountIn: U256::from(WBTC_TEST_AMOUNT),
        amountOutMinimum: U256::ZERO,
        sqrtPriceLimitX96: U160::ZERO,
    };
    let call1_data = ISwapRouter::exactInputSingleCall {
        params: swap_params,
    }
    .abi_encode();

    let calls = vec![
        HTLCCoordinator::Call {
            target: WBTC,
            value: U256::ZERO,
            callData: Bytes::from(call0_data),
        },
        HTLCCoordinator::Call {
            target: UNISWAP_ROUTER,
            value: U256::ZERO,
            callData: Bytes::from(call1_data),
        },
    ];

    // EIP-712 signature: hub (claimAddress) authorizes coordinator (caller) to redeem
    let chain_id = alice_provider.get_chain_id().await?;

    let domain_separator = keccak256(
        (
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("HTLCErc20"),
            keccak256("2"),
            U256::from(chain_id),
            htlc_address,
        )
            .abi_encode(),
    );

    let type_hash = keccak256(
        "Redeem(bytes32 preimage,uint256 amount,address token,address sender,uint256 timelock,address caller,address destination,address sweepToken,uint256 minAmountOut)",
    );
    let struct_hash = keccak256(
        (
            type_hash,
            preimage,
            U256::from(WBTC_TEST_AMOUNT),
            WBTC,
            alice_address, // sender = Alice (created the lock)
            timelock,
            coordinator_address, // caller = coordinator (will call HTLC.redeemBySig)
            hub_address,         // destination = hub (sweep target)
            USDC,                // sweepToken
            U256::ZERO,          // minAmountOut (USDC went directly to Bob, not coordinator)
        )
            .abi_encode(),
    );

    let digest = keccak256(
        [
            b"\x19\x01",
            domain_separator.as_slice(),
            struct_hash.as_slice(),
        ]
        .concat(),
    );

    let sig = hub_key.sign_hash(&digest).await?;
    let sig_bytes = sig.as_bytes();
    let sig_v = sig_bytes[64];
    let sig_r = FixedBytes::<32>::from_slice(&sig_bytes[0..32]);
    let sig_s = FixedBytes::<32>::from_slice(&sig_bytes[32..64]);

    // Hub calls redeemAndExecute with EIP-712 signature
    let coordinator_as_hub = HTLCCoordinator::new(coordinator_address, &hub_provider);
    let receipt = coordinator_as_hub
        .redeemAndExecute(
            preimage,
            U256::from(WBTC_TEST_AMOUNT),
            WBTC,
            alice_address, // htlcSender = Alice (she created the lock)
            timelock,
            calls,
            USDC,
            U256::ZERO,  // minAmountOut = 0 (USDC went directly to Bob, not coordinator)
            hub_address, // destination = hub (sweep target)
            sig_v,
            sig_r,
            sig_s,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    println!(
        "   tx: {:?}  status: {:?}",
        receipt.transaction_hash,
        receipt.status()
    );
    assert!(receipt.status(), "redeemAndExecute tx should succeed");

    // -----------------------------------------------------------------------
    // 5. Assertions
    // -----------------------------------------------------------------------
    println!("\n5. Verifying ...");

    // a) Bob received USDC (even though the hub called the tx)
    let bob_usdc_after = IERC20::new(USDC, &raw_provider)
        .balanceOf(bob_address)
        .call()
        .await?;
    let bob_usdc_received = bob_usdc_after - bob_usdc_before;
    println!("   Bob USDC: {bob_usdc_before} → {bob_usdc_after} (+{bob_usdc_received})");
    assert!(
        bob_usdc_received > U256::ZERO,
        "Bob should have received USDC"
    );

    // b) HTLC is empty
    let htlc_wbtc_after = IERC20::new(WBTC, &alice_provider)
        .balanceOf(htlc_address)
        .call()
        .await?;
    println!("   HTLC WBTC balance: {htlc_wbtc_after}");
    assert_eq!(htlc_wbtc_after, U256::ZERO, "HTLC should be empty");

    // c) Coordinator has no leftover WBTC
    let coord_wbtc = IERC20::new(WBTC, &alice_provider)
        .balanceOf(coordinator_address)
        .call()
        .await?;
    println!("   Coordinator leftover WBTC: {coord_wbtc}");
    assert_eq!(
        coord_wbtc,
        U256::ZERO,
        "Coordinator should have no leftover WBTC"
    );

    // d) Swap is no longer active
    let still_active = htlc_reader
        .isActive(
            preimage_hash,
            U256::from(WBTC_TEST_AMOUNT),
            WBTC,
            alice_address,
            hub_address, // claimAddress = hub
            timelock,
        )
        .call()
        .await?;
    println!("   isActive after redeem: {still_active}");
    assert!(!still_active, "HTLC should no longer be active");

    // e) Alice WBTC is gone (locked and redeemed)
    let alice_wbtc_after = IERC20::new(WBTC, &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    println!("   Alice WBTC after: {alice_wbtc_after}");
    assert_eq!(
        alice_wbtc_after,
        U256::ZERO,
        "Alice should have no WBTC left"
    );

    println!(
        "\n=== Test passed — Hub redeemed and swapped, Bob received {bob_usdc_received} USDC ===\n"
    );

    Ok(())
}
