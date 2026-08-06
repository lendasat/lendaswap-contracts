//! E2E test: recovering balances that no swap is owed.
//!
//! Tokens can be transferred into the HTLC without going through `create`, and ether can
//! be force-sent to it, so its balance can exceed what active swaps are owed. `lockedAmounts`
//! records that obligation and `recoverExcessToken` is floored at it, so the owner can move
//! the surplus and nothing else. Ether is never owed to a swap — no function here is
//! payable — so all of it is recoverable.
//!
//! Run:
//!   cargo test --test e2e_fund_recovery -- --nocapture

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::Address;
use alloy::primitives::FixedBytes;
use alloy::primitives::U256;
use alloy::providers::Provider;
use alloy::providers::ProviderBuilder;
use alloy::providers::WalletProvider;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use anyhow::Result;
use anyhow::anyhow;
use sha2::Digest;
use sha2::Sha256;

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    HTLCErc20,
    "../out/HTLCErc20.sol/HTLCErc20.json"
);

sol!(
    #[sol(rpc)]
    #[derive(Debug)]
    MockWBTC,
    "../out/HTLCCoordinatorSwapAndLock.t.sol/MockWBTC.json"
);

sol! {
    #[sol(rpc)]
    interface IERC20 {
        function balanceOf(address account) external view returns (uint256);
        function approve(address spender, uint256 amount) external returns (bool);
        function transfer(address to, uint256 amount) external returns (bool);
    }
}

/// The swap that must stay backed: 1 WBTC.
const SWAP_AMOUNT: u128 = 100_000_000;
/// Sent straight to the contract, bypassing `create`: 3 WBTC.
const STRAY_AMOUNT: u128 = 300_000_000;

fn sha256(bytes: &[u8]) -> FixedBytes<32> {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    FixedBytes::<32>::from_slice(&hasher.finalize())
}

#[tokio::test]
async fn test_recovers_stray_tokens_and_leaves_swap_funds() -> Result<()> {
    println!("\n=== test_recovers_stray_tokens_and_leaves_swap_funds ===\n");

    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let owner_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice_key: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob_key: PrivateKeySigner = anvil.keys()[2].clone().into();
    let treasury = anvil.addresses()[4];

    let owner_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(owner_key))
        .connect_http(endpoint.clone());
    let alice_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(alice_key))
        .connect_http(endpoint.clone());
    let bob_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(bob_key))
        .connect_http(endpoint.clone());

    let owner = owner_provider.default_signer_address();
    let alice = alice_provider.default_signer_address();
    let bob = bob_provider.default_signer_address();

    println!("1. Deploying HTLCErc20 owned by {owner} ...");
    let htlc = HTLCErc20::deploy(&owner_provider, owner).await?;
    let wbtc = MockWBTC::deploy(&owner_provider).await?;
    let htlc_address = *htlc.address();
    let wbtc_address = *wbtc.address();
    assert_eq!(
        htlc.owner().call().await?,
        owner,
        "constructor set the owner"
    );

    IERC20::new(wbtc_address, &owner_provider)
        .transfer(alice, U256::from(10 * SWAP_AMOUNT))
        .send()
        .await?
        .get_receipt()
        .await?;

    println!("2. Alice locks a swap with Bob as claimAddress ...");
    let preimage = FixedBytes::<32>::from([0x11u8; 32]);
    let preimage_hash = sha256(preimage.as_slice());

    let block_num = owner_provider.get_block_number().await?;
    let now = owner_provider
        .get_block_by_number(block_num.into())
        .await?
        .ok_or_else(|| anyhow!("no latest block"))?
        .header
        .timestamp;
    let timelock = U256::from(now + 3600);

    IERC20::new(wbtc_address, &alice_provider)
        .approve(htlc_address, U256::from(SWAP_AMOUNT))
        .send()
        .await?
        .get_receipt()
        .await?;
    HTLCErc20::new(htlc_address, &alice_provider)
        .create_1(
            preimage_hash,
            U256::from(SWAP_AMOUNT),
            wbtc_address,
            bob,
            timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    assert_eq!(
        htlc.lockedAmounts(wbtc_address).call().await?,
        U256::from(SWAP_AMOUNT),
        "obligation recorded"
    );

    println!("3. Alice mis-sends tokens straight to the contract ...");
    IERC20::new(wbtc_address, &alice_provider)
        .transfer(htlc_address, U256::from(STRAY_AMOUNT))
        .send()
        .await?
        .get_receipt()
        .await?;

    let held = IERC20::new(wbtc_address, &owner_provider)
        .balanceOf(htlc_address)
        .call()
        .await?;
    assert_eq!(
        held,
        U256::from(SWAP_AMOUNT + STRAY_AMOUNT),
        "contract holds swap funds plus the stray transfer"
    );

    println!("4. A non-owner cannot recover ...");
    let denied = HTLCErc20::new(htlc_address, &alice_provider)
        .recoverExcessToken(wbtc_address, alice)
        .call()
        .await;
    assert!(denied.is_err(), "recovery must be owner-only");

    println!("5. Owner recovers the surplus to the treasury ...");
    HTLCErc20::new(htlc_address, &owner_provider)
        .recoverExcessToken(wbtc_address, treasury)
        .send()
        .await?
        .get_receipt()
        .await?;

    let token = IERC20::new(wbtc_address, &owner_provider);
    assert_eq!(
        token.balanceOf(treasury).call().await?,
        U256::from(STRAY_AMOUNT),
        "treasury received exactly the stray amount"
    );
    assert_eq!(
        token.balanceOf(htlc_address).call().await?,
        U256::from(SWAP_AMOUNT),
        "the swap's backing stayed put"
    );

    println!("6. A second recovery finds nothing to take ...");
    let nothing_left = HTLCErc20::new(htlc_address, &owner_provider)
        .recoverExcessToken(wbtc_address, treasury)
        .call()
        .await;
    assert!(nothing_left.is_err(), "no excess remains");

    println!("7. Bob redeems the swap, which is still fully backed ...");
    HTLCErc20::new(htlc_address, &bob_provider)
        .redeem(
            preimage,
            U256::from(SWAP_AMOUNT),
            wbtc_address,
            alice,
            timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    assert_eq!(
        token.balanceOf(bob).call().await?,
        U256::from(SWAP_AMOUNT),
        "swap paid out in full"
    );
    assert_eq!(
        htlc.lockedAmounts(wbtc_address).call().await?,
        U256::ZERO,
        "obligation cleared"
    );

    println!("\n✅ surplus recovered, swap unaffected\n");
    Ok(())
}

#[tokio::test]
async fn test_recovers_force_sent_ether() -> Result<()> {
    println!("\n=== test_recovers_force_sent_ether ===\n");

    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let owner_key: PrivateKeySigner = anvil.keys()[0].clone().into();
    let owner_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(owner_key))
        .connect_http(endpoint.clone());
    let raw = ProviderBuilder::new().connect_http(endpoint.clone());

    let owner = owner_provider.default_signer_address();
    let treasury: Address = anvil.addresses()[4];

    let htlc = HTLCErc20::deploy(&owner_provider, owner).await?;
    let htlc_address = *htlc.address();

    println!("1. No ether to recover yet ...");
    let empty = HTLCErc20::new(htlc_address, &owner_provider)
        .recoverEther(treasury)
        .call()
        .await;
    assert!(empty.is_err(), "nothing to recover");

    // The contract has no payable function, so a balance can only be forced onto it.
    println!("2. Forcing ether onto the contract ...");
    let forced = U256::from(5_000_000_000_000_000_000u128); // 5 ether
    raw.raw_request::<_, serde_json::Value>(
        "anvil_setBalance".into(),
        (htlc_address, format!("0x{forced:x}")),
    )
    .await?;
    assert_eq!(
        raw.get_balance(htlc_address).await?,
        forced,
        "contract holds forced ether"
    );

    println!("3. Owner recovers it ...");
    let treasury_before = raw.get_balance(treasury).await?;
    HTLCErc20::new(htlc_address, &owner_provider)
        .recoverEther(treasury)
        .send()
        .await?
        .get_receipt()
        .await?;

    assert_eq!(
        raw.get_balance(htlc_address).await?,
        U256::ZERO,
        "contract drained"
    );
    assert_eq!(
        raw.get_balance(treasury).await? - treasury_before,
        forced,
        "treasury received all of it"
    );

    println!("\n✅ force-sent ether recovered\n");
    Ok(())
}
