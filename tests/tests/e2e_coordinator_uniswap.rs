#![allow(clippy::too_many_arguments)]

//! E2E test: Fork Polygon, deploy HTLCErc20 + HTLCCoordinator, and execute a
//! real Uniswap V3 swap through the `HTLCCoordinator.executeAndCreate` flow.
//!
//! Requires `POLYGON_RPC_URL` env var and network access.
//! Run:
//!   POLYGON_RPC_URL="..." cargo test --test e2e_coordinator_uniswap -- --ignored --nocapture

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::{Address, Bytes, FixedBytes, U160, U256, address};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::SolCall;
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
/// 100 USDC (6 decimals)
const USDC_TEST_AMOUNT: u128 = 100_000_000; // 100e6
/// 0.001 WBTC (8 decimals)
const WBTC_TEST_AMOUNT: u128 = 100_000; // 0.001e8
/// Fork block — chosen so the whales have sufficient balance
const FORK_BLOCK: u64 = 82_488_076;
/// Known USDC whale on Polygon
const USDC_WHALE: Address = address!("0x852f57dd17edbb0bedae8c55dd4b20feb3133089");
/// Known WBTC whale on Polygon (verify balance at fork block)
const WBTC_WHALE: Address = address!("0xc7797a4b3243a56b5bf1e3a8c3a0e2b1e8d3347c");

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore] // requires POLYGON_RPC_URL and network access
async fn test_e2e_swap_then_lock_then_redeem() -> Result<()> {
    // -----------------------------------------------------------------------
    // 0. Setup: fork Polygon at pinned block
    // -----------------------------------------------------------------------
    let rpc_url =
        std::env::var("POLYGON_RPC_URL").expect("Set POLYGON_RPC_URL to a Polygon RPC endpoint");

    println!("\n=== E2E: Swap → Lock → Redeem (Polygon Fork) ===\n");
    println!("Forking Polygon at block {FORK_BLOCK} ...");

    let anvil = Anvil::new()
        .fork(&rpc_url)
        .fork_block_number(FORK_BLOCK)
        .try_spawn()?;

    let endpoint = anvil.endpoint_url();

    // Alice (uses a wallet-backed provider for sending txs)
    let alice_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_address = alice_key.address();
    let alice_wallet = EthereumWallet::from(alice_key);
    let alice_provider = ProviderBuilder::new()
        .wallet(alice_wallet)
        .connect_http(endpoint.clone());

    // Bob (claims the HTLC by revealing the preimage)
    let bob_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_address = bob_key.address();
    let bob_wallet = EthereumWallet::from(bob_key);
    let bob_provider = ProviderBuilder::new()
        .wallet(bob_wallet)
        .connect_http(endpoint.clone());

    // Hub — independent deployer of the contracts
    let hub_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let hub_address = hub_key.address();
    let hub_wallet = EthereumWallet::from(hub_key);
    let hub_provider = ProviderBuilder::new()
        .wallet(hub_wallet)
        .connect_http(endpoint.clone());

    // Non-wallet provider for raw RPC calls (impersonation)
    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());

    println!("  Alice: {alice_address}");
    println!("  Bob:   {bob_address}");
    println!("  Hub:   {hub_address}");

    // -----------------------------------------------------------------------
    // 1. Deploy HTLCErc20 + HTLCCoordinator
    // -----------------------------------------------------------------------
    println!("\n1. Deploying contracts ...");

    let htlc = HTLCErc20::deploy(&hub_provider).await?;
    let htlc_address = *htlc.address();
    println!("   HTLCErc20 at {htlc_address} (deployed by hub)");

    let coordinator = HTLCCoordinator::deploy(&hub_provider, htlc_address).await?;
    let coordinator_address = *coordinator.address();
    println!("   HTLCCoordinator at {coordinator_address} (deployed by hub)");

    // -----------------------------------------------------------------------
    // 2. Impersonate USDC whale → fund Alice with USDC
    // -----------------------------------------------------------------------
    println!("\n2. Funding Alice with USDC from whale ...");

    let usdc_on_raw = IERC20::new(USDC, &raw_provider);

    // Check whale balance first
    let whale_balance = usdc_on_raw.balanceOf(USDC_WHALE).call().await?;
    println!("   Whale USDC balance: {whale_balance}");
    assert!(
        whale_balance >= U256::from(USDC_TEST_AMOUNT),
        "Whale has insufficient USDC at block {FORK_BLOCK}"
    );

    // Impersonate
    raw_provider
        .raw_request::<_, ()>(
            "anvil_impersonateAccount".into(),
            &[format!("{USDC_WHALE:?}")],
        )
        .await?;

    // Transfer USDC from whale to Alice
    let usdc_on_whale = IERC20::new(USDC, &raw_provider);
    let _tx = usdc_on_whale
        .transfer(alice_address, U256::from(USDC_TEST_AMOUNT))
        .from(USDC_WHALE)
        .send()
        .await?
        .get_receipt()
        .await?;

    // Stop impersonating
    raw_provider
        .raw_request::<_, ()>(
            "anvil_stopImpersonatingAccount".into(),
            &[format!("{USDC_WHALE:?}")],
        )
        .await?;

    let alice_usdc_before = IERC20::new(USDC, &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    println!("   Alice USDC balance: {alice_usdc_before}");
    assert_eq!(alice_usdc_before, U256::from(USDC_TEST_AMOUNT));

    // -----------------------------------------------------------------------
    // 3. Alice approves USDC to the coordinator
    // -----------------------------------------------------------------------
    println!("\n3. Alice approving USDC to coordinator ...");

    let usdc_as_alice = IERC20::new(USDC, &alice_provider);
    usdc_as_alice
        .approve(coordinator_address, U256::from(USDC_TEST_AMOUNT))
        .send()
        .await?
        .get_receipt()
        .await?;
    println!("   Approved {USDC_TEST_AMOUNT} USDC");

    // -----------------------------------------------------------------------
    // 4. Build Call[] structs for executeAndCreate
    // -----------------------------------------------------------------------
    println!("\n4. Building calls for executeAndCreate ...");

    let block = alice_provider.get_block_number().await?;
    let deadline = U256::from(
        raw_provider
            .get_block_by_number(block.into())
            .await?
            .expect("block exists")
            .header
            .timestamp
            + 600, // 10 minutes
    );

    // Preimage / hash
    let preimage = FixedBytes::<32>::from([0xABu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));

    // Timelock — far in the future relative to the fork block
    let timelock_ts = raw_provider
        .get_block_by_number(block.into())
        .await?
        .expect("block exists")
        .header
        .timestamp
        + 3600; // 1 hour from current block
    let timelock = U256::from(timelock_ts);

    // Call 0: USDC.transferFrom(alice, coordinator, amount)
    let call0_data = IERC20::transferFromCall {
        from: alice_address,
        to: coordinator_address,
        amount: U256::from(USDC_TEST_AMOUNT),
    }
    .abi_encode();

    // Call 1: USDC.approve(uniswapRouter, amount)
    let call1_data = IERC20::approveCall {
        spender: UNISWAP_ROUTER,
        amount: U256::from(USDC_TEST_AMOUNT),
    }
    .abi_encode();

    // Call 2: router.exactInputSingle(...)
    let swap_params = ISwapRouter::ExactInputSingleParams {
        tokenIn: USDC,
        tokenOut: WBTC,
        fee: POOL_FEE.try_into().unwrap(),
        recipient: coordinator_address,
        deadline,
        amountIn: U256::from(USDC_TEST_AMOUNT),
        amountOutMinimum: U256::ZERO, // no slippage protection for test
        sqrtPriceLimitX96: U160::ZERO,
    };
    let call2_data = ISwapRouter::exactInputSingleCall {
        params: swap_params,
    }
    .abi_encode();

    let calls = vec![
        HTLCCoordinator::Call {
            target: USDC,
            value: U256::ZERO,
            callData: Bytes::from(call0_data),
        },
        HTLCCoordinator::Call {
            target: USDC,
            value: U256::ZERO,
            callData: Bytes::from(call1_data),
        },
        HTLCCoordinator::Call {
            target: UNISWAP_ROUTER,
            value: U256::ZERO,
            callData: Bytes::from(call2_data),
        },
    ];

    println!("   3 calls prepared (transferFrom, approve, exactInputSingle)");

    // -----------------------------------------------------------------------
    // 5. Call coordinator.executeAndCreate(...)
    //    First overload: (Call[], preimageHash, token, recipient, timelock, refundCallsHash)
    // -----------------------------------------------------------------------
    println!("\n5. Calling coordinator.executeAndCreate ...");

    let coordinator_as_alice = HTLCCoordinator::new(coordinator_address, &alice_provider);

    // Alloy disambiguates overloaded functions with _0 / _1 suffixes.
    // The first overload (with refundCallsHash) is executeAndCreate_0.
    let receipt = coordinator_as_alice
        .executeAndCreate_0(
            calls,
            preimage_hash,
            WBTC,
            bob_address,
            timelock,
            FixedBytes::<32>::ZERO, // no committed refund calls
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
    assert!(receipt.status(), "executeAndCreate tx should succeed");

    // -----------------------------------------------------------------------
    // 6. Assertions
    // -----------------------------------------------------------------------
    println!("\n6. Verifying ...");

    // a) WBTC locked in HTLC
    let wbtc_in_htlc = IERC20::new(WBTC, &alice_provider)
        .balanceOf(htlc_address)
        .call()
        .await?;
    println!("   WBTC locked in HTLC: {wbtc_in_htlc}");
    assert!(wbtc_in_htlc > U256::ZERO, "HTLC should hold WBTC");

    // b) isActive — sender is the coordinator, not Alice
    let htlc_reader = HTLCErc20::new(htlc_address, &alice_provider);
    let is_active = htlc_reader
        .isActive(
            preimage_hash,
            wbtc_in_htlc,
            WBTC,
            coordinator_address, // sender = coordinator (it called HTLC.create)
            bob_address,
            timelock,
        )
        .call()
        .await?;
    println!("   isActive (sender=coordinator): {is_active}");
    assert!(is_active, "HTLC swap should be active");

    // c) Alice USDC decreased
    let alice_usdc_after = IERC20::new(USDC, &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    println!("   Alice USDC after: {alice_usdc_after}");
    assert_eq!(
        alice_usdc_after,
        U256::ZERO,
        "Alice should have spent all her USDC"
    );

    // -----------------------------------------------------------------------
    // 7. Bob claims the HTLC by revealing the preimage
    // -----------------------------------------------------------------------
    println!("\n7. Bob claiming HTLC with preimage ...");

    let bob_wbtc_before = IERC20::new(WBTC, &bob_provider)
        .balanceOf(bob_address)
        .call()
        .await?;

    let htlc_as_bob = HTLCErc20::new(htlc_address, &bob_provider);
    let redeem_receipt = htlc_as_bob
        .redeem(
            preimage,
            wbtc_in_htlc,
            WBTC,
            coordinator_address, // sender = coordinator
            bob_address,
            timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    println!(
        "   tx: {:?}  status: {:?}",
        redeem_receipt.transaction_hash,
        redeem_receipt.status()
    );
    assert!(redeem_receipt.status(), "redeem tx should succeed");

    // -----------------------------------------------------------------------
    // 8. Post-claim assertions
    // -----------------------------------------------------------------------
    println!("\n8. Verifying post-claim state ...");

    // a) Bob received the WBTC
    let bob_wbtc_after = IERC20::new(WBTC, &bob_provider)
        .balanceOf(bob_address)
        .call()
        .await?;
    println!("   Bob WBTC: {bob_wbtc_before} -> {bob_wbtc_after}");
    assert_eq!(
        bob_wbtc_after,
        bob_wbtc_before + wbtc_in_htlc,
        "Bob should have received the locked WBTC"
    );

    // b) HTLC no longer holds WBTC
    let htlc_wbtc_after = IERC20::new(WBTC, &alice_provider)
        .balanceOf(htlc_address)
        .call()
        .await?;
    println!("   HTLC WBTC balance: {htlc_wbtc_after}");
    assert_eq!(htlc_wbtc_after, U256::ZERO, "HTLC should be empty");

    // c) Swap is no longer active
    let still_active = htlc_reader
        .isActive(
            preimage_hash,
            wbtc_in_htlc,
            WBTC,
            coordinator_address,
            bob_address,
            timelock,
        )
        .call()
        .await?;
    println!("   isActive after redeem: {still_active}");
    assert!(!still_active, "HTLC swap should no longer be active");

    println!("\n=== Test passed — {wbtc_in_htlc} WBTC swapped and claimed by Bob ===\n");

    Ok(())
}

// ---------------------------------------------------------------------------
// Reverse direction: Lock → Redeem-and-Swap
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
    let hub_wallet = EthereumWallet::from(hub_key);
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

    // Alice creates the HTLC: sender=Alice, recipient=coordinator
    // Uses the 5-param create (sender = msg.sender = Alice)
    let htlc_as_alice = HTLCErc20::new(htlc_address, &alice_provider);
    htlc_as_alice
        .create_1(
            preimage_hash,
            U256::from(WBTC_TEST_AMOUNT),
            WBTC,
            coordinator_address, // recipient = coordinator (so it can redeem)
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
            alice_address,           // sender = Alice
            coordinator_address,     // recipient = coordinator
            timelock,
        )
        .call()
        .await?;
    println!("   isActive (sender=Alice, recipient=coordinator): {is_active}");
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

    // Hub calls redeemAndExecute
    let coordinator_as_hub = HTLCCoordinator::new(coordinator_address, &hub_provider);
    let receipt = coordinator_as_hub
        .redeemAndExecute(
            preimage,
            U256::from(WBTC_TEST_AMOUNT),
            WBTC,
            alice_address,  // htlcSender = Alice (she created the lock)
            timelock,
            calls,
            USDC,
            U256::ZERO,     // minAmountOut = 0 (USDC went directly to Bob, not coordinator)
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
    assert!(bob_usdc_received > U256::ZERO, "Bob should have received USDC");

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
    assert_eq!(coord_wbtc, U256::ZERO, "Coordinator should have no leftover WBTC");

    // d) Swap is no longer active
    let still_active = htlc_reader
        .isActive(
            preimage_hash,
            U256::from(WBTC_TEST_AMOUNT),
            WBTC,
            alice_address,
            coordinator_address,
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
    assert_eq!(alice_wbtc_after, U256::ZERO, "Alice should have no WBTC left");

    println!("\n=== Test passed — Hub redeemed and swapped, Bob received {bob_usdc_received} USDC ===\n");

    Ok(())
}
