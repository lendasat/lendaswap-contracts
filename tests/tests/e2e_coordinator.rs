//! E2E tests for the 4 core HTLCCoordinator flows using **local Anvil + mock
//! contracts** (MockUSDC, MockWBTC, MockDEX). No network access required.
//!
//! Tests 1 and 2 overlap with `e2e_swap_then_lock_then_redeem` (which uses a
//! real Polygon fork + Uniswap V3). They are kept here so the full coordinator
//! lifecycle can be validated locally without RPC credentials.
//! Tests 3 and 4 (refund paths) are unique to this file.
//!
//! 1. `test_lock_and_execute`    — `executeAndCreate`: swap USDC→WBTC via DEX, lock WBTC in HTLC
//! 2. `test_claim`               — Bob redeems the HTLC with the preimage
//! 3. `test_refund_and_execute`  — `refundAndExecute`: after timelock, depositor swaps WBTC back to
//!    USDC
//! 4. `test_refund_to`           — `refundTo`: after timelock, anyone sends WBTC directly to
//!    depositor
//!
//! Run:
//!   cargo test --test e2e_coordinator -- --nocapture

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::Address;
use alloy::primitives::Bytes;
use alloy::primitives::FixedBytes;
use alloy::primitives::U256;
use alloy::providers::Provider;
use alloy::providers::ProviderBuilder;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::SolCall;
use anyhow::Result;
use sha2::Digest;
use sha2::Sha256;

// ---------------------------------------------------------------------------
// Contract bindings
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

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockUSDC,
    "../out/HTLCCoordinatorSwapAndLock.t.sol/MockUSDC.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockWBTC,
    "../out/HTLCCoordinatorSwapAndLock.t.sol/MockWBTC.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockDEX,
    "../out/HTLCCoordinatorSwapAndLock.t.sol/MockDEX.json"
);

sol! {
    #[sol(rpc)]
    interface IERC20 {
        function balanceOf(address account) external view returns (uint256);
        function approve(address spender, uint256 amount) external returns (bool);
        function transfer(address to, uint256 amount) external returns (bool);
        function transferFrom(address from, address to, uint256 amount) external returns (bool);
    }
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const USDC_AMOUNT: u128 = 60_000_000_000; // 60,000 USDC (6 decimals)
const EXPECTED_WBTC: u128 = 100_000_000; // 1 WBTC (8 decimals)

// ---------------------------------------------------------------------------
// Call builders
// ---------------------------------------------------------------------------

/// Build the forward calls for executeAndCreate:
///   1. transferFrom(alice → coordinator, USDC)
///   2. approve(dex, USDC)
///   3. dex.swap(USDC → WBTC)
fn build_forward_calls(
    usdc: Address,
    wbtc: Address,
    dex: Address,
    coordinator: Address,
    alice: Address,
) -> Vec<HTLCCoordinator::Call> {
    vec![
        HTLCCoordinator::Call {
            target: usdc,
            value: U256::ZERO,
            callData: Bytes::from(
                IERC20::transferFromCall {
                    from: alice,
                    to: coordinator,
                    amount: U256::from(USDC_AMOUNT),
                }
                .abi_encode(),
            ),
        },
        HTLCCoordinator::Call {
            target: usdc,
            value: U256::ZERO,
            callData: Bytes::from(
                IERC20::approveCall {
                    spender: dex,
                    amount: U256::from(USDC_AMOUNT),
                }
                .abi_encode(),
            ),
        },
        HTLCCoordinator::Call {
            target: dex,
            value: U256::ZERO,
            callData: Bytes::from(
                MockDEX::swapCall {
                    tokenIn: usdc,
                    tokenOut: wbtc,
                    amountIn: U256::from(USDC_AMOUNT),
                    minAmountOut: U256::from(EXPECTED_WBTC),
                }
                .abi_encode(),
            ),
        },
    ]
}

/// Build the refund calls for refundAndExecute:
///   1. approve(dex, WBTC)
///   2. dex.swap(WBTC → USDC)
fn build_refund_calls(wbtc: Address, usdc: Address, dex: Address) -> Vec<HTLCCoordinator::Call> {
    vec![
        HTLCCoordinator::Call {
            target: wbtc,
            value: U256::ZERO,
            callData: Bytes::from(
                IERC20::approveCall {
                    spender: dex,
                    amount: U256::from(EXPECTED_WBTC),
                }
                .abi_encode(),
            ),
        },
        HTLCCoordinator::Call {
            target: dex,
            value: U256::ZERO,
            callData: Bytes::from(
                MockDEX::swapCall {
                    tokenIn: wbtc,
                    tokenOut: usdc,
                    amountIn: U256::from(EXPECTED_WBTC),
                    minAmountOut: U256::from(USDC_AMOUNT),
                }
                .abi_encode(),
            ),
        },
    ]
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// 1. Lock and execute: swap USDC → WBTC via DEX and lock WBTC in HTLC
#[tokio::test]
async fn test_lock_and_execute() -> Result<()> {
    println!("\n=== test_lock_and_execute ===\n");

    // -- 1. Setup: spawn Anvil and create wallets --
    println!("1. Spawning Anvil and creating wallets ...");
    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let deployer_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let alice_address = alice_key.address();
    let bob_address = bob_key.address();

    let deployer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer_key))
        .connect_http(endpoint.clone());

    let alice_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(alice_key))
        .connect_http(endpoint.clone());

    println!("   Alice: {alice_address}");
    println!("   Bob:   {bob_address}");

    // -- 2. Deploy contracts --
    println!("\n2. Deploying contracts ...");
    let htlc = HTLCErc20::deploy(&deployer_provider).await?;
    let coordinator = HTLCCoordinator::deploy(&deployer_provider, *htlc.address()).await?;
    let usdc = MockUSDC::deploy(&deployer_provider).await?;
    let wbtc = MockWBTC::deploy(&deployer_provider).await?;
    let dex = MockDEX::deploy(&deployer_provider).await?;
    println!("   HTLCErc20:       {}", htlc.address());
    println!("   HTLCCoordinator: {}", coordinator.address());
    println!("   MockUSDC:        {}", usdc.address());
    println!("   MockWBTC:        {}", wbtc.address());
    println!("   MockDEX:         {}", dex.address());

    // -- 3. Fund Alice and DEX --
    println!("\n3. Funding Alice with 100k USDC, DEX with 50 WBTC + 500k USDC ...");
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(alice_address, U256::from(100_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*wbtc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(5_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(500_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;

    // Set DEX rates: 60,000 USDC = 1 WBTC
    dex.setRate(
        *usdc.address(),
        *wbtc.address(),
        U256::from(EXPECTED_WBTC),
        U256::from(USDC_AMOUNT),
    )
    .send()
    .await?
    .get_receipt()
    .await?;
    dex.setRate(
        *wbtc.address(),
        *usdc.address(),
        U256::from(USDC_AMOUNT),
        U256::from(EXPECTED_WBTC),
    )
    .send()
    .await?
    .get_receipt()
    .await?;
    println!("   DEX rate: 60,000 USDC = 1 WBTC");

    // -- 4. Prepare preimage and timelock --
    println!("\n4. Preparing preimage and timelock ...");
    let preimage = FixedBytes::<32>::from([0xABu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));
    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());
    let block_num = raw_provider.get_block_number().await?;
    let block = raw_provider
        .get_block_by_number(block_num.into())
        .await?
        .unwrap();
    let timelock = U256::from(block.header.timestamp + 3600);
    println!("   Preimage hash: {preimage_hash}");
    println!("   Timelock:      {timelock} (current + 1h)");

    // -- 5. Alice approves coordinator to pull USDC --
    println!("\n5. Alice approving 60,000 USDC to coordinator ...");
    IERC20::new(*usdc.address(), &alice_provider)
        .approve(*coordinator.address(), U256::from(USDC_AMOUNT))
        .send()
        .await?
        .get_receipt()
        .await?;

    // -- 6. Build calls and executeAndCreate --
    println!("\n6. Calling executeAndCreate (transferFrom + approve DEX + swap) ...");
    let calls = build_forward_calls(
        *usdc.address(),
        *wbtc.address(),
        *dex.address(),
        *coordinator.address(),
        alice_address,
    );

    let coordinator_alice = HTLCCoordinator::new(*coordinator.address(), &alice_provider);
    let receipt = coordinator_alice
        .executeAndCreate_1(calls, preimage_hash, *wbtc.address(), bob_address, timelock)
        .send()
        .await?
        .get_receipt()
        .await?;
    println!(
        "   tx: {:?}  status: {:?}",
        receipt.transaction_hash,
        receipt.status()
    );
    assert!(receipt.status(), "executeAndCreate should succeed");

    // -- 7. Verify --
    println!("\n7. Verifying ...");

    let wbtc_in_htlc = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    println!("   WBTC locked in HTLC: {wbtc_in_htlc}");
    assert_eq!(
        wbtc_in_htlc,
        U256::from(EXPECTED_WBTC),
        "HTLC should hold 1 WBTC"
    );

    let htlc_reader = HTLCErc20::new(*htlc.address(), &alice_provider);
    let is_active = htlc_reader
        .isActive(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            *coordinator.address(),
            bob_address,
            timelock,
        )
        .call()
        .await?;
    println!("   Swap active: {is_active}");
    assert!(is_active, "swap should be active");

    let alice_usdc = IERC20::new(*usdc.address(), &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    println!("   Alice USDC remaining: {alice_usdc}");
    assert_eq!(
        alice_usdc,
        U256::from(40_000_000_000u128),
        "alice should have 40k USDC left"
    );

    println!("\n=== test_lock_and_execute PASSED ===\n");
    Ok(())
}

/// 2. Claim: after lock and execute, Bob redeems the HTLC with the preimage
#[tokio::test]
async fn test_claim() -> Result<()> {
    println!("\n=== test_claim ===\n");

    // -- 1. Setup --
    println!("1. Spawning Anvil and creating wallets ...");
    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let deployer_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let alice_address = alice_key.address();
    let bob_address = bob_key.address();

    let deployer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer_key))
        .connect_http(endpoint.clone());
    let alice_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(alice_key))
        .connect_http(endpoint.clone());
    let bob_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(bob_key))
        .connect_http(endpoint.clone());

    println!("   Alice: {alice_address}");
    println!("   Bob:   {bob_address}");

    // -- 2. Deploy contracts --
    println!("\n2. Deploying contracts ...");
    let htlc = HTLCErc20::deploy(&deployer_provider).await?;
    let coordinator = HTLCCoordinator::deploy(&deployer_provider, *htlc.address()).await?;
    let usdc = MockUSDC::deploy(&deployer_provider).await?;
    let wbtc = MockWBTC::deploy(&deployer_provider).await?;
    let dex = MockDEX::deploy(&deployer_provider).await?;
    println!("   HTLCErc20:       {}", htlc.address());
    println!("   HTLCCoordinator: {}", coordinator.address());

    // -- 3. Fund Alice and DEX --
    println!("\n3. Funding Alice with 100k USDC, DEX with 50 WBTC + 500k USDC ...");
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(alice_address, U256::from(100_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*wbtc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(5_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(500_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    dex.setRate(
        *usdc.address(),
        *wbtc.address(),
        U256::from(EXPECTED_WBTC),
        U256::from(USDC_AMOUNT),
    )
    .send()
    .await?
    .get_receipt()
    .await?;

    // -- 4. Alice creates swap via executeAndCreate --
    println!("\n4. Alice creating swap via executeAndCreate ...");
    let preimage = FixedBytes::<32>::from([0xABu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));
    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());
    let block_num = raw_provider.get_block_number().await?;
    let block = raw_provider
        .get_block_by_number(block_num.into())
        .await?
        .unwrap();
    let timelock = U256::from(block.header.timestamp + 3600);
    println!("   Preimage hash: {preimage_hash}");
    println!("   Timelock:      {timelock}");

    IERC20::new(*usdc.address(), &alice_provider)
        .approve(*coordinator.address(), U256::from(USDC_AMOUNT))
        .send()
        .await?
        .get_receipt()
        .await?;

    let calls = build_forward_calls(
        *usdc.address(),
        *wbtc.address(),
        *dex.address(),
        *coordinator.address(),
        alice_address,
    );
    let create_receipt = HTLCCoordinator::new(*coordinator.address(), &alice_provider)
        .executeAndCreate_1(calls, preimage_hash, *wbtc.address(), bob_address, timelock)
        .send()
        .await?
        .get_receipt()
        .await?;
    println!(
        "   tx: {:?}  status: {:?}",
        create_receipt.transaction_hash,
        create_receipt.status()
    );

    let wbtc_locked = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    println!("   WBTC locked in HTLC: {wbtc_locked}");

    // -- 5. Bob redeems with preimage --
    println!("\n5. Bob claiming HTLC with preimage ...");
    let bob_wbtc_before = IERC20::new(*wbtc.address(), &bob_provider)
        .balanceOf(bob_address)
        .call()
        .await?;
    println!("   Bob WBTC before: {bob_wbtc_before}");

    let htlc_bob = HTLCErc20::new(*htlc.address(), &bob_provider);
    let redeem_receipt = htlc_bob
        .redeem(
            preimage,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            *coordinator.address(),
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
    assert!(redeem_receipt.status(), "redeem should succeed");

    // -- 6. Verify post-claim state --
    println!("\n6. Verifying post-claim state ...");

    let bob_wbtc_after = IERC20::new(*wbtc.address(), &bob_provider)
        .balanceOf(bob_address)
        .call()
        .await?;
    println!("   Bob WBTC after:  {bob_wbtc_after}");
    assert_eq!(
        bob_wbtc_after - bob_wbtc_before,
        U256::from(EXPECTED_WBTC),
        "Bob should have received 1 WBTC"
    );

    let htlc_balance = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    println!("   HTLC WBTC balance: {htlc_balance}");
    assert_eq!(htlc_balance, U256::ZERO, "HTLC should be empty");

    let is_active = HTLCErc20::new(*htlc.address(), &alice_provider)
        .isActive(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            *coordinator.address(),
            bob_address,
            timelock,
        )
        .call()
        .await?;
    println!("   Swap active: {is_active}");
    assert!(!is_active, "swap should no longer be active");

    println!("\n=== test_claim PASSED ===\n");
    Ok(())
}

/// 3. Refund and execute: after timelock, swap WBTC back to USDC for Alice
#[tokio::test]
async fn test_refund_and_execute() -> Result<()> {
    println!("\n=== test_refund_and_execute ===\n");

    // -- 1. Setup --
    println!("1. Spawning Anvil and creating wallets ...");
    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let deployer_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let alice_address = alice_key.address();
    let bob_address = bob_key.address();

    let deployer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer_key))
        .connect_http(endpoint.clone());
    let alice_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(alice_key))
        .connect_http(endpoint.clone());

    println!("   Alice: {alice_address}");
    println!("   Bob:   {bob_address}");

    // -- 2. Deploy contracts --
    println!("\n2. Deploying contracts ...");
    let htlc = HTLCErc20::deploy(&deployer_provider).await?;
    let coordinator = HTLCCoordinator::deploy(&deployer_provider, *htlc.address()).await?;
    let usdc = MockUSDC::deploy(&deployer_provider).await?;
    let wbtc = MockWBTC::deploy(&deployer_provider).await?;
    let dex = MockDEX::deploy(&deployer_provider).await?;
    println!("   HTLCErc20:       {}", htlc.address());
    println!("   HTLCCoordinator: {}", coordinator.address());

    // -- 3. Fund Alice and DEX --
    println!("\n3. Funding Alice with 100k USDC, DEX with 50 WBTC + 500k USDC ...");
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(alice_address, U256::from(100_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*wbtc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(5_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(500_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    dex.setRate(
        *usdc.address(),
        *wbtc.address(),
        U256::from(EXPECTED_WBTC),
        U256::from(USDC_AMOUNT),
    )
    .send()
    .await?
    .get_receipt()
    .await?;
    dex.setRate(
        *wbtc.address(),
        *usdc.address(),
        U256::from(USDC_AMOUNT),
        U256::from(EXPECTED_WBTC),
    )
    .send()
    .await?
    .get_receipt()
    .await?;
    println!("   DEX rate: 60,000 USDC = 1 WBTC (both directions)");

    // -- 4. Alice creates swap via executeAndCreate --
    println!("\n4. Alice creating swap via executeAndCreate ...");
    let preimage = FixedBytes::<32>::from([0xABu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));
    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());
    let block_num = raw_provider.get_block_number().await?;
    let block = raw_provider
        .get_block_by_number(block_num.into())
        .await?
        .unwrap();
    let timelock_ts = block.header.timestamp + 3600;
    let timelock = U256::from(timelock_ts);
    println!("   Preimage hash: {preimage_hash}");
    println!("   Timelock:      {timelock}");

    IERC20::new(*usdc.address(), &alice_provider)
        .approve(*coordinator.address(), U256::from(USDC_AMOUNT))
        .send()
        .await?
        .get_receipt()
        .await?;

    let forward_calls = build_forward_calls(
        *usdc.address(),
        *wbtc.address(),
        *dex.address(),
        *coordinator.address(),
        alice_address,
    );
    let create_receipt = HTLCCoordinator::new(*coordinator.address(), &alice_provider)
        .executeAndCreate_1(
            forward_calls,
            preimage_hash,
            *wbtc.address(),
            bob_address,
            timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;
    println!(
        "   tx: {:?}  status: {:?}",
        create_receipt.transaction_hash,
        create_receipt.status()
    );

    let alice_usdc_before = IERC20::new(*usdc.address(), &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    let wbtc_locked = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    println!("   WBTC locked in HTLC: {wbtc_locked}");
    println!("   Alice USDC remaining: {alice_usdc_before}");

    // -- 5. Advance time past timelock (Bob never claims) --
    println!("\n5. Advancing time past timelock (Bob never claims) ...");
    raw_provider
        .raw_request::<_, serde_json::Value>(
            "evm_setNextBlockTimestamp".into(),
            vec![timelock_ts + 1],
        )
        .await?;
    raw_provider
        .raw_request::<_, serde_json::Value>("evm_mine".into(), Vec::<u64>::new())
        .await?;
    println!(
        "   Block timestamp set to {} (timelock + 1)",
        timelock_ts + 1
    );

    // -- 6. Alice triggers refundAndExecute (swap WBTC back to USDC) --
    println!("\n6. Alice calling refundAndExecute (approve DEX + swap WBTC→USDC) ...");
    let refund_calls = build_refund_calls(*wbtc.address(), *usdc.address(), *dex.address());

    let coordinator_alice = HTLCCoordinator::new(*coordinator.address(), &alice_provider);
    let receipt = coordinator_alice
        .refundAndExecute(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            bob_address,
            timelock,
            refund_calls,
            *usdc.address(),
            U256::from(USDC_AMOUNT),
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
    assert!(receipt.status(), "refundAndExecute should succeed");

    // -- 7. Verify --
    println!("\n7. Verifying ...");

    let htlc_balance = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    println!("   HTLC WBTC balance: {htlc_balance}");
    assert_eq!(htlc_balance, U256::ZERO, "HTLC should be empty");

    let alice_usdc_after = IERC20::new(*usdc.address(), &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    println!(
        "   Alice USDC: {alice_usdc_before} -> {alice_usdc_after} (+{})",
        alice_usdc_after - alice_usdc_before
    );
    assert_eq!(
        alice_usdc_after - alice_usdc_before,
        U256::from(USDC_AMOUNT),
        "Alice should have her USDC back"
    );

    println!("\n=== test_refund_and_execute PASSED ===\n");
    Ok(())
}

/// 4. Refund the WBTC: after timelock, send WBTC directly to Alice
#[tokio::test]
async fn test_refund_to() -> Result<()> {
    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let deployer_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let charlie_key: PrivateKeySigner = anvil.keys()[3].clone().into();
    let alice_address = alice_key.address();
    let bob_address = bob_key.address();

    let deployer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer_key))
        .connect_http(endpoint.clone());
    let alice_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(alice_key))
        .connect_http(endpoint.clone());
    let charlie_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(charlie_key))
        .connect_http(endpoint.clone());

    // Deploy
    let htlc = HTLCErc20::deploy(&deployer_provider).await?;
    let coordinator = HTLCCoordinator::deploy(&deployer_provider, *htlc.address()).await?;
    let usdc = MockUSDC::deploy(&deployer_provider).await?;
    let wbtc = MockWBTC::deploy(&deployer_provider).await?;
    let dex = MockDEX::deploy(&deployer_provider).await?;

    // Fund
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(alice_address, U256::from(100_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*wbtc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(5_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    IERC20::new(*usdc.address(), &deployer_provider)
        .transfer(*dex.address(), U256::from(500_000_000_000u128))
        .send()
        .await?
        .get_receipt()
        .await?;
    dex.setRate(
        *usdc.address(),
        *wbtc.address(),
        U256::from(EXPECTED_WBTC),
        U256::from(USDC_AMOUNT),
    )
    .send()
    .await?
    .get_receipt()
    .await?;

    // Create swap (no refund calls hash — we'll use refundTo)
    let preimage = FixedBytes::<32>::from([0xABu8; 32]);
    let preimage_hash = FixedBytes::<32>::from_slice(&Sha256::digest(preimage.as_slice()));
    let raw_provider = ProviderBuilder::new().connect_http(endpoint.clone());
    let block_num = raw_provider.get_block_number().await?;
    let block = raw_provider
        .get_block_by_number(block_num.into())
        .await?
        .unwrap();
    let timelock_ts = block.header.timestamp + 3600;
    let timelock = U256::from(timelock_ts);

    IERC20::new(*usdc.address(), &alice_provider)
        .approve(*coordinator.address(), U256::from(USDC_AMOUNT))
        .send()
        .await?
        .get_receipt()
        .await?;

    let calls = build_forward_calls(
        *usdc.address(),
        *wbtc.address(),
        *dex.address(),
        *coordinator.address(),
        alice_address,
    );
    HTLCCoordinator::new(*coordinator.address(), &alice_provider)
        .executeAndCreate_1(calls, preimage_hash, *wbtc.address(), bob_address, timelock)
        .send()
        .await?
        .get_receipt()
        .await?;

    // Alice should have 0 WBTC before refund
    let alice_wbtc_before = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    assert_eq!(
        alice_wbtc_before,
        U256::ZERO,
        "alice should have 0 WBTC before refund"
    );

    // Advance time past timelock
    raw_provider
        .raw_request::<_, serde_json::Value>(
            "evm_setNextBlockTimestamp".into(),
            vec![timelock_ts + 1],
        )
        .await?;
    raw_provider
        .raw_request::<_, serde_json::Value>("evm_mine".into(), Vec::<u64>::new())
        .await?;

    // Charlie triggers refundTo (permissionless)
    let coordinator_charlie = HTLCCoordinator::new(*coordinator.address(), &charlie_provider);
    let receipt = coordinator_charlie
        .refundTo(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            bob_address,
            timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;
    assert!(receipt.status(), "refundTo should succeed");

    // Verify: HTLC empty
    let htlc_balance = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(*htlc.address())
        .call()
        .await?;
    assert_eq!(htlc_balance, U256::ZERO, "HTLC should be empty");

    // Verify: Alice got WBTC directly
    let alice_wbtc_after = IERC20::new(*wbtc.address(), &alice_provider)
        .balanceOf(alice_address)
        .call()
        .await?;
    assert_eq!(
        alice_wbtc_after,
        U256::from(EXPECTED_WBTC),
        "alice should have 1 WBTC"
    );

    // Verify: swap no longer active
    let is_active = HTLCErc20::new(*htlc.address(), &alice_provider)
        .isActive(
            preimage_hash,
            U256::from(EXPECTED_WBTC),
            *wbtc.address(),
            *coordinator.address(),
            bob_address,
            timelock,
        )
        .call()
        .await?;
    assert!(!is_active, "swap should no longer be active");

    println!("test_refund_to passed");
    Ok(())
}
