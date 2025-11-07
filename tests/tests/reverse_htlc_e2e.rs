//! End-to-end integration test for ReverseAtomicSwapHTLC contract
//!
//! This test requires:
//! 1. Forge contracts to be compiled: `cd ../../ && forge build`
//! 2. Anvil to be installed (part of Foundry)
//!
//! Run with: `cargo test --test reverse_htlc_e2e -- --ignored --nocapture`

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::{Address, FixedBytes};
use alloy::providers::ProviderBuilder;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use std::str::FromStr;

// Generate contract bindings from compiled artifacts
sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    ReverseAtomicSwapHTLC,
    "../out/ReverseAtomicSwapHTLC.sol/ReverseAtomicSwapHTLC.json"
);

#[tokio::test]
#[ignore] // Mark as ignore since it requires Anvil to be installed and contracts to be compiled
async fn test_reverse_htlc_deployment_and_basic_operations() {
    // Note: This test requires contracts to be compiled first with:
    // cd ../../ && forge build

    // Start local Anvil node
    let anvil = Anvil::new()
        .try_spawn()
        .expect("Failed to spawn Anvil. Install with: foundryup");

    // Setup provider with signer
    let signer: PrivateKeySigner = anvil.keys()[0].clone().into();
    let wallet = EthereumWallet::from(signer);
    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .connect_http(anvil.endpoint_url());

    let alice = anvil.addresses()[0];
    let bob = anvil.addresses()[1];

    println!("=== Test Setup ===");
    println!("Alice address: {}", alice);
    println!("Bob address: {}", bob);
    println!("Anvil endpoint: {}", anvil.endpoint_url());

    // Deploy ReverseAtomicSwapHTLC contract
    println!("\n=== Deploying ReverseAtomicSwapHTLC ===");
    let router_address = Address::from_str("0x0000000000000000000000000000000000000002").unwrap();
    let forwarder_address =
        Address::from_str("0x0000000000000000000000000000000000000001").unwrap();

    let htlc = ReverseAtomicSwapHTLC::deploy(&provider, router_address, forwarder_address)
        .await
        .expect("Failed to deploy ReverseAtomicSwapHTLC. Run 'cd ../../ && forge build' first.");

    println!("✓ ReverseAtomicSwapHTLC deployed at: {}", htlc.address());

    // Verify contract deployment and basic properties
    println!("\n=== Verifying Contract Properties ===");

    let swap_router = htlc.swapRouter().call().await.unwrap();
    assert_eq!(swap_router, router_address);
    println!("✓ Swap router address verified: {}", swap_router);

    let is_trusted_forwarder = htlc
        .isTrustedForwarder(forwarder_address)
        .call()
        .await
        .unwrap();
    assert!(is_trusted_forwarder);
    println!("✓ Trusted forwarder verified: {}", forwarder_address);

    // Test getSwap with non-existent swap
    let non_existent_swap_id = FixedBytes::<32>::from([0u8; 32]);
    let swap = htlc.getSwap(non_existent_swap_id).call().await.unwrap();
    assert_eq!(swap.state, 0); // INVALID state
    println!("✓ Non-existent swap returns INVALID state");

    // Test isSwapOpen with non-existent swap
    let is_open = htlc.isSwapOpen(non_existent_swap_id).call().await.unwrap();
    assert!(!is_open);
    println!("✓ Non-existent swap is not open");

    // Test with a different swap ID
    let another_swap_id = FixedBytes::<32>::from([1u8; 32]);
    let swap2 = htlc.getSwap(another_swap_id).call().await.unwrap();
    assert_eq!(swap2.state, 0);
    println!("✓ Another non-existent swap also returns INVALID state");

    println!("\n=== All Basic Tests Passed! ===");
    println!("✓ Contract deployment successful");
    println!("✓ Contract configuration verified");
    println!("✓ Read operations working correctly");
    println!("\nNote: Full swap lifecycle tests (create, claim, refund) are covered in the");
    println!("Solidity test suite. Run with: cd ../../ && forge test --match-contract ReverseAtomicSwapHTLC");
}
