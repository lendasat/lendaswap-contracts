//! E2E test: a settlement event identifies exactly one swap.
//!
//! `preimageHash` does not identify a swap. Any party may lock their own HTLC under
//! a `preimageHash` that is already in use, with entirely independent terms — the
//! storage key covers every parameter, so the two coexist as separate swaps. An
//! indexer that attributes a `SwapRedeemed` / `SwapRefunded` to a swap on the basis
//! of `preimageHash` alone therefore cannot tell which of them settled.
//!
//! `key` is the identifier that does discriminate: it is the commitment to the full
//! parameter set, so each swap's settlement event names that swap and no other.
//! These tests exercise the discrimination the way a log consumer sees it — filter
//! by `preimageHash` topic, then match on `key`.
//!
//! Run:
//!   cargo test --test e2e_swap_identity -- --nocapture

use alloy::network::EthereumWallet;
use alloy::node_bindings::Anvil;
use alloy::primitives::Address;
use alloy::primitives::FixedBytes;
use alloy::primitives::U256;
use alloy::providers::Provider;
use alloy::providers::ProviderBuilder;
use alloy::rpc::types::Filter;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use alloy::sol_types::SolEvent;
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

/// The swap under observation: 1 WBTC.
const TRACKED_AMOUNT: u128 = 100_000_000;
/// An unrelated swap sharing its `preimageHash`: 0.01 WBTC.
const UNRELATED_AMOUNT: u128 = 1_000_000;

fn sha256(bytes: &[u8]) -> FixedBytes<32> {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    FixedBytes::<32>::from_slice(&hasher.finalize())
}

/// Every `SwapRedeemed` carrying `preimage_hash`, as a log consumer filtering on that
/// topic alone would see them: `(key, preimage)` per event, in block order.
async fn redeemed_events<P: Provider>(
    provider: &P,
    htlc: Address,
    preimage_hash: FixedBytes<32>,
) -> Result<Vec<(FixedBytes<32>, FixedBytes<32>)>> {
    let filter = Filter::new()
        .address(htlc)
        .event_signature(HTLCErc20::SwapRedeemed::SIGNATURE_HASH)
        .topic1(preimage_hash)
        .from_block(0);

    provider
        .get_logs(&filter)
        .await?
        .iter()
        .map(|log| {
            let decoded = HTLCErc20::SwapRedeemed::decode_log(log.as_ref())?;
            Ok((decoded.key, decoded.preimage))
        })
        .collect()
}

/// Every `SwapRefunded` carrying `preimage_hash`, keyed the same way.
async fn refunded_events<P: Provider>(
    provider: &P,
    htlc: Address,
    preimage_hash: FixedBytes<32>,
) -> Result<Vec<FixedBytes<32>>> {
    let filter = Filter::new()
        .address(htlc)
        .event_signature(HTLCErc20::SwapRefunded::SIGNATURE_HASH)
        .topic1(preimage_hash)
        .from_block(0);

    provider
        .get_logs(&filter)
        .await?
        .iter()
        .map(|log| Ok(HTLCErc20::SwapRefunded::decode_log(log.as_ref())?.key))
        .collect()
}

struct Fixture {
    anvil: alloy::node_bindings::AnvilInstance,
    htlc_address: Address,
    wbtc_address: Address,
    alice: PrivateKeySigner,
    bob: PrivateKeySigner,
    carol: PrivateKeySigner,
    now: u64,
}

/// Deploy the HTLC and a mock WBTC, and fund Alice and Carol.
async fn setup() -> Result<Fixture> {
    let anvil = Anvil::new().block_time(1).try_spawn()?;
    let endpoint = anvil.endpoint_url();

    let deployer: PrivateKeySigner = anvil.keys()[0].clone().into();
    let alice: PrivateKeySigner = anvil.keys()[1].clone().into();
    let bob: PrivateKeySigner = anvil.keys()[2].clone().into();
    let carol: PrivateKeySigner = anvil.keys()[3].clone().into();

    let deployer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer))
        .connect_http(endpoint.clone());

    let htlc = HTLCErc20::deploy(&deployer_provider).await?;
    let wbtc = MockWBTC::deploy(&deployer_provider).await?;

    let token = IERC20::new(*wbtc.address(), &deployer_provider);
    for who in [alice.address(), carol.address()] {
        token
            .transfer(who, U256::from(10 * TRACKED_AMOUNT))
            .send()
            .await?
            .get_receipt()
            .await?;
    }

    let block_num = deployer_provider.get_block_number().await?;
    let now = deployer_provider
        .get_block_by_number(block_num.into())
        .await?
        .ok_or_else(|| anyhow!("no latest block"))?
        .header
        .timestamp;

    Ok(Fixture {
        htlc_address: *htlc.address(),
        wbtc_address: *wbtc.address(),
        alice,
        bob,
        carol,
        now,
        anvil,
    })
}

/// Lock `amount` under `preimage_hash` with `signer` as sender and `claim` as claimAddress.
async fn lock(
    fixture: &Fixture,
    signer: &PrivateKeySigner,
    preimage_hash: FixedBytes<32>,
    amount: u128,
    claim: Address,
    timelock: U256,
) -> Result<()> {
    let provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(signer.clone()))
        .connect_http(fixture.anvil.endpoint_url());

    IERC20::new(fixture.wbtc_address, &provider)
        .approve(fixture.htlc_address, U256::from(amount))
        .send()
        .await?
        .get_receipt()
        .await?;

    HTLCErc20::new(fixture.htlc_address, &provider)
        .create_1(
            preimage_hash,
            U256::from(amount),
            fixture.wbtc_address,
            claim,
            timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    Ok(())
}

#[tokio::test]
async fn test_redeem_event_names_only_its_own_swap() -> Result<()> {
    println!("\n=== test_redeem_event_names_only_its_own_swap ===\n");

    let fixture = setup().await?;
    let endpoint = fixture.anvil.endpoint_url();
    let raw = ProviderBuilder::new().connect_http(endpoint.clone());
    let htlc = HTLCErc20::new(fixture.htlc_address, &raw);

    let preimage = FixedBytes::<32>::from([0x42u8; 32]);
    let preimage_hash = sha256(preimage.as_slice());

    let tracked_timelock = U256::from(fixture.now + 3600);
    let unrelated_timelock = U256::from(fixture.now + 7200);

    println!("1. Alice locks the tracked swap (claimAddress = Bob) ...");
    lock(
        &fixture,
        &fixture.alice,
        preimage_hash,
        TRACKED_AMOUNT,
        fixture.bob.address(),
        tracked_timelock,
    )
    .await?;

    println!("2. Carol locks an unrelated swap under the same preimageHash ...");
    lock(
        &fixture,
        &fixture.carol,
        preimage_hash,
        UNRELATED_AMOUNT,
        fixture.carol.address(),
        unrelated_timelock,
    )
    .await?;

    let tracked_key = htlc
        .computeKey(
            preimage_hash,
            U256::from(TRACKED_AMOUNT),
            fixture.wbtc_address,
            fixture.alice.address(),
            fixture.bob.address(),
            tracked_timelock,
        )
        .call()
        .await?;
    let unrelated_key = htlc
        .computeKey(
            preimage_hash,
            U256::from(UNRELATED_AMOUNT),
            fixture.wbtc_address,
            fixture.carol.address(),
            fixture.carol.address(),
            unrelated_timelock,
        )
        .call()
        .await?;

    assert_ne!(
        tracked_key, unrelated_key,
        "swaps with different terms must have different keys"
    );

    println!("3. Carol redeems her own swap ...");
    let carol_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(fixture.carol.clone()))
        .connect_http(endpoint.clone());
    HTLCErc20::new(fixture.htlc_address, &carol_provider)
        .redeem(
            preimage,
            U256::from(UNRELATED_AMOUNT),
            fixture.wbtc_address,
            fixture.carol.address(),
            unrelated_timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    println!("4. Reading SwapRedeemed logs filtered by preimageHash ...");
    let events = redeemed_events(&raw, fixture.htlc_address, preimage_hash).await?;
    assert_eq!(events.len(), 1, "one settlement so far");

    // Filtering by preimageHash alone surfaces this event for the tracked swap too.
    // `key` is what shows it belongs to the other one.
    let (settled_key, revealed_preimage) = events[0];
    assert_eq!(settled_key, unrelated_key, "event names the settled swap");
    assert_ne!(settled_key, tracked_key, "event is not the tracked swap's");
    assert_eq!(
        revealed_preimage, preimage,
        "preimage is genuine for the hash"
    );

    let tracked_still_active = htlc
        .isActive(
            preimage_hash,
            U256::from(TRACKED_AMOUNT),
            fixture.wbtc_address,
            fixture.alice.address(),
            fixture.bob.address(),
            tracked_timelock,
        )
        .call()
        .await?;
    assert!(
        tracked_still_active,
        "the tracked swap must be untouched by another swap's settlement"
    );

    println!("5. Bob redeems the tracked swap ...");
    let bob_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(fixture.bob.clone()))
        .connect_http(endpoint.clone());
    HTLCErc20::new(fixture.htlc_address, &bob_provider)
        .redeem(
            preimage,
            U256::from(TRACKED_AMOUNT),
            fixture.wbtc_address,
            fixture.alice.address(),
            tracked_timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    let events = redeemed_events(&raw, fixture.htlc_address, preimage_hash).await?;
    assert_eq!(events.len(), 2, "both swaps have now settled");
    assert_eq!(
        events[1].0, tracked_key,
        "the second event names the tracked swap"
    );

    let tracked_active = htlc
        .isActive(
            preimage_hash,
            U256::from(TRACKED_AMOUNT),
            fixture.wbtc_address,
            fixture.alice.address(),
            fixture.bob.address(),
            tracked_timelock,
        )
        .call()
        .await?;
    assert!(!tracked_active, "the tracked swap is settled");

    println!("\n✅ each settlement event named exactly one swap\n");
    Ok(())
}

#[tokio::test]
async fn test_refund_event_names_only_its_own_swap() -> Result<()> {
    println!("\n=== test_refund_event_names_only_its_own_swap ===\n");

    let fixture = setup().await?;
    let endpoint = fixture.anvil.endpoint_url();
    let raw = ProviderBuilder::new().connect_http(endpoint.clone());
    let htlc = HTLCErc20::new(fixture.htlc_address, &raw);

    let preimage = FixedBytes::<32>::from([0x7fu8; 32]);
    let preimage_hash = sha256(preimage.as_slice());

    // The unrelated swap expires first, so it can settle while the tracked one is live.
    let unrelated_timelock_ts = fixture.now + 60;
    let unrelated_timelock = U256::from(unrelated_timelock_ts);
    let tracked_timelock = U256::from(fixture.now + 86_400);

    println!("1. Alice locks the tracked swap (claimAddress = Bob) ...");
    lock(
        &fixture,
        &fixture.alice,
        preimage_hash,
        TRACKED_AMOUNT,
        fixture.bob.address(),
        tracked_timelock,
    )
    .await?;

    println!("2. Carol locks an unrelated swap under the same preimageHash ...");
    lock(
        &fixture,
        &fixture.carol,
        preimage_hash,
        UNRELATED_AMOUNT,
        fixture.carol.address(),
        unrelated_timelock,
    )
    .await?;

    let tracked_key = htlc
        .computeKey(
            preimage_hash,
            U256::from(TRACKED_AMOUNT),
            fixture.wbtc_address,
            fixture.alice.address(),
            fixture.bob.address(),
            tracked_timelock,
        )
        .call()
        .await?;
    let unrelated_key = htlc
        .computeKey(
            preimage_hash,
            U256::from(UNRELATED_AMOUNT),
            fixture.wbtc_address,
            fixture.carol.address(),
            fixture.carol.address(),
            unrelated_timelock,
        )
        .call()
        .await?;

    println!("3. Advancing past the unrelated swap's timelock ...");
    raw.raw_request::<_, serde_json::Value>(
        "evm_setNextBlockTimestamp".into(),
        vec![unrelated_timelock_ts + 1],
    )
    .await?;
    raw.raw_request::<_, serde_json::Value>("evm_mine".into(), Vec::<u64>::new())
        .await?;

    println!("4. Carol refunds her own swap ...");
    let carol_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(fixture.carol.clone()))
        .connect_http(endpoint.clone());
    HTLCErc20::new(fixture.htlc_address, &carol_provider)
        .refund_0(
            preimage_hash,
            U256::from(UNRELATED_AMOUNT),
            fixture.wbtc_address,
            fixture.carol.address(),
            unrelated_timelock,
        )
        .send()
        .await?
        .get_receipt()
        .await?;

    println!("5. Reading SwapRefunded logs filtered by preimageHash ...");
    let keys = refunded_events(&raw, fixture.htlc_address, preimage_hash).await?;
    assert_eq!(keys.len(), 1, "one refund so far");
    assert_eq!(keys[0], unrelated_key, "event names the refunded swap");
    assert_ne!(keys[0], tracked_key, "event is not the tracked swap's");

    // A refund reveals no preimage, so this event is producible by any party holding
    // an HTLC under the hash — `key` remains the only thing that attributes it.
    let tracked_still_active = htlc
        .isActive(
            preimage_hash,
            U256::from(TRACKED_AMOUNT),
            fixture.wbtc_address,
            fixture.alice.address(),
            fixture.bob.address(),
            tracked_timelock,
        )
        .call()
        .await?;
    assert!(
        tracked_still_active,
        "the tracked swap must be untouched by another swap's refund"
    );

    println!("\n✅ the refund event named exactly one swap\n");
    Ok(())
}
