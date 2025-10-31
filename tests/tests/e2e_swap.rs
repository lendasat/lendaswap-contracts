#![allow(clippy::too_many_arguments)]

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::FixedBytes;
use alloy::primitives::U256;
use alloy::providers::ProviderBuilder;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use anyhow::Result;
use sha2::Digest;
use sha2::Sha256;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

// Generate contract bindings using sol! macro
sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    AtomicSwapHTLC,
    "../out/AtomicSwapHTLC.sol/AtomicSwapHTLC.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    ERC2771Forwarder,
    "../out/ERC2771Forwarder.sol/ERC2771Forwarder.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockERC20,
    "../out/AtomicSwapHTLC.t.sol/MockERC20.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockSwapRouter,
    "../out/AtomicSwapHTLC.t.sol/MockSwapRouter.json"
);

#[tokio::test]
async fn test_e2e_atomic_swap_happy_path() -> Result<()> {
    println!("\n=== Starting E2E Atomic Swap Test ===\n");

    // Step 1: Setup local regtest environment (Anvil)
    println!("1. Setting up local blockchain (Anvil)...");
    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let rpc_url = anvil.endpoint_url();
    println!("   ✓ Anvil running at: {}", rpc_url);

    // Setup wallets
    let alice_key = anvil.keys()[0].clone();
    let bob_key = anvil.keys()[1].clone();
    let alice_signer = PrivateKeySigner::from(alice_key);
    let bob_signer = PrivateKeySigner::from(bob_key);
    let alice_address = alice_signer.address();
    let bob_address = bob_signer.address();

    println!("   ✓ Alice address: {}", alice_address);
    println!("   ✓ Bob address: {}", bob_address);

    // Create providers
    let alice_wallet = EthereumWallet::from(alice_signer.clone());
    let alice_provider = ProviderBuilder::new()
        .wallet(alice_wallet)
        .connect_http(rpc_url.clone());

    let bob_wallet = EthereumWallet::from(bob_signer);
    let bob_provider = ProviderBuilder::new()
        .wallet(bob_wallet)
        .connect_http(rpc_url);

    // Step 2: Deploy smart contracts
    println!("\n2. Deploying smart contracts...");

    // Deploy mock tokens
    println!("   - Deploying WBTC...");
    let wbtc = MockERC20::deploy(
        &alice_provider,
        "Wrapped Bitcoin".to_string(),
        "WBTC".to_string(),
    )
    .await?;
    let wbtc_address = *wbtc.address();
    println!("     ✓ WBTC deployed at: {}", wbtc_address);

    println!("   - Deploying USDC...");
    let usdc =
        MockERC20::deploy(&alice_provider, "USD Coin".to_string(), "USDC".to_string()).await?;
    let usdc_address = *usdc.address();
    println!("     ✓ USDC deployed at: {}", usdc_address);

    // Deploy mock Uniswap router
    println!("   - Deploying Mock Uniswap Router...");
    let router = MockSwapRouter::deploy(&alice_provider).await?;
    let router_address = *router.address();
    println!("     ✓ Router deployed at: {}", router_address);

    // Deploy ERC2771 Forwarder
    println!("   - Deploying ERC2771Forwarder...");
    let forwarder = ERC2771Forwarder::deploy(&alice_provider, "TestForwarder".to_string()).await?;
    let forwarder_address = *forwarder.address();
    println!("     ✓ Forwarder deployed at: {}", forwarder_address);

    // Deploy HTLC contract
    println!("   - Deploying AtomicSwapHTLC...");
    let htlc = AtomicSwapHTLC::deploy(&alice_provider, router_address, forwarder_address).await?;
    let htlc_address = *htlc.address();
    println!("     ✓ HTLC deployed at: {}", htlc_address);

    // Step 3: Setup test data
    println!("\n3. Setting up swap parameters...");

    // Generate secret and hash lock (simulating Bitcoin side)
    let secret = FixedBytes::<32>::from([42u8; 32]);
    let mut hasher = Sha256::new();
    hasher.update(secret.as_slice());
    let hash_lock = FixedBytes::<32>::from_slice(&hasher.finalize());
    println!("   ✓ Secret generated");
    println!("   ✓ Hash lock: 0x{}", hex::encode(hash_lock));

    // Swap parameters
    let swap_id = FixedBytes::<32>::from([1u8; 32]); // Using fixed ID for testing
    let amount = U256::from(1_000_000_000_000_000_000u128); // 1 WBTC (18 decimals)
    let timelock = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() + 3600; // 1 hour from now
    let pool_fee = alloy::primitives::Uint::<24, 1>::from(3000u32); // 0.3%

    println!("   ✓ Swap ID: 0x{}", hex::encode(swap_id));
    println!("   ✓ Amount: {} WBTC", amount);
    println!("   ✓ Timelock: {} (1 hour from now)", timelock);

    // Mint tokens to Alice
    println!("\n   - Minting tokens to Alice...");
    let mint_tx = wbtc
        .mint(alice_address, amount * U256::from(10))
        .send()
        .await?
        .get_receipt()
        .await?;
    println!(
        "     ✓ Minted WBTC to Alice (tx: {})",
        mint_tx.transaction_hash
    );

    // Check Alice's balance
    let alice_wbtc_balance = wbtc.balanceOf(alice_address).call().await?;
    println!("     ✓ Alice's WBTC balance: {}", alice_wbtc_balance);

    // Step 4: Create swap
    println!("\n4. Creating atomic swap...");

    // Alice approves HTLC to spend her WBTC
    println!("   - Alice approving HTLC to spend WBTC...");
    let approve_tx = wbtc
        .approve(htlc_address, amount)
        .send()
        .await?
        .get_receipt()
        .await?;
    println!("     ✓ Approved (tx: {})", approve_tx.transaction_hash);

    // todo: wait for it being mined

    // Alice creates the swap
    println!("   - Alice creating swap...");
    let min_amount_out = U256::ZERO; // No slippage protection for this test
    let create_tx = htlc
        .createSwap(
            swap_id,
            bob_address,
            wbtc_address,
            usdc_address,
            amount,
            hash_lock,
            U256::from(timelock),
            pool_fee,
            min_amount_out,
        )
        .send()
        .await?
        .get_receipt()
        .await?;
    println!("     ✓ Swap created (tx: {})", create_tx.transaction_hash);

    // Verify swap was created
    let swap = htlc.getSwap(swap_id).call().await?;
    println!("     ✓ Swap verified on-chain:");
    println!("       - Sender: {}", swap.sender);
    println!("       - Recipient: {}", swap.recipient);
    println!("       - Amount: {}", swap.amountIn);
    println!("       - State: {:?}", swap.state);

    // Verify HTLC has the tokens
    let htlc_wbtc_balance = wbtc.balanceOf(htlc_address).call().await?;
    println!("     ✓ HTLC WBTC balance: {}", htlc_wbtc_balance);
    assert_eq!(htlc_wbtc_balance, amount, "HTLC should hold the WBTC");

    // Step 5: Execute swap (claim with secret)
    println!("\n5. Executing swap (Bob claims with secret)...");

    // Check Bob's USDC balance before
    let bob_usdc_before = usdc.balanceOf(bob_address).call().await?;
    println!("   - Bob's USDC balance before: {}", bob_usdc_before);

    // Bob claims the swap by revealing the secret
    println!("   - Bob revealing secret and claiming swap...");

    // Create bob's instance of the HTLC contract
    let htlc_bob = AtomicSwapHTLC::new(htlc_address, &bob_provider);

    let claim_tx = htlc_bob
        .claimSwap(swap_id, secret)
        .send()
        .await?
        .get_receipt()
        .await?;
    println!("     ✓ Swap claimed (tx: {})", claim_tx.transaction_hash);

    // Verify swap state changed
    let swap_after = htlc.getSwap(swap_id).call().await?;
    println!("     ✓ Swap state after claim: {:?}", swap_after.state);
    assert_eq!(swap_after.state, 2, "Swap should be in CLAIMED state");

    // Check Bob's USDC balance after
    let bob_usdc_after = usdc.balanceOf(bob_address).call().await?;
    println!("   - Bob's USDC balance after: {}", bob_usdc_after);
    println!(
        "     ✓ Bob received: {} USDC",
        bob_usdc_after - bob_usdc_before
    );

    // Verify Bob received tokens
    assert!(
        bob_usdc_after > bob_usdc_before,
        "Bob should have received USDC"
    );

    // Verify HTLC no longer has WBTC
    let htlc_wbtc_after = wbtc.balanceOf(htlc_address).call().await?;
    println!("   - HTLC WBTC balance after: {}", htlc_wbtc_after);
    assert_eq!(htlc_wbtc_after, U256::ZERO, "HTLC should have no WBTC left");

    println!("\n=== E2E Test Completed Successfully ===\n");
    println!("Summary:");
    println!("  ✓ Local blockchain setup");
    println!("  ✓ Contracts deployed");
    println!("  ✓ Swap created with hash lock");
    println!("  ✓ Swap claimed with secret reveal");
    println!("  ✓ Uniswap swap executed automatically");
    println!("  ✓ Tokens transferred to recipient");
    println!("\nAtomic swap completed successfully! 🎉\n");

    Ok(())
}
