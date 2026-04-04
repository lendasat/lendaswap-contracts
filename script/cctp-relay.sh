#!/usr/bin/env bash
# Manually relay a CCTP V2 message on the destination chain.
#
# When Circle's Forwarding Service fails (e.g. INSUFFICIENT_FEE), this script
# calls receiveMessage() on the destination MessageTransmitter to mint the
# tokens and complete the forward.
#
# Usage:
#   ./cctp-relay.sh <source_tx_hash> [--rpc-url <dest_rpc>] [--dry-run]
#
# Examples:
#   ./cctp-relay.sh 0x6e3304...01fe7b                         # relay to dest chain (auto-detected)
#   ./cctp-relay.sh 0x6e3304...01fe7b --rpc-url https://...   # override dest RPC
#   ./cctp-relay.sh 0x6e3304...01fe7b --dry-run               # simulate only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ─── CCTP constants ───────────────────────────────────────────────────────────

MESSAGE_TRANSMITTER="0x81D40F21F12A8F0E3252Bccb954D722d4c464B64"
IRIS_API="https://iris-api.circle.com"

# ─── Domain lookups (bash 3.2 compatible — no associative arrays) ─────────────

domain_to_chain() {
  case "$1" in
    0) echo "Ethereum"  ;;
    1) echo "Avalanche" ;;
    2) echo "Optimism"  ;;
    3) echo "Arbitrum"  ;;
    5) echo "Solana"    ;;
    6) echo "Base"      ;;
    7) echo "Polygon"   ;;
    *) echo "domain-$1" ;;
  esac
}

domain_to_rpc() {
  case "$1" in
    0) echo "${ETH_RPC_URL:-}"                      ;;
    3) echo "${ARBITRUM_RPC_URL:-}"                  ;;
    6) echo "${BASE_RPC_URL:-https://mainnet.base.org}" ;;
    7) echo "${POLYGON_RPC_URL:-}"                   ;;
    *) echo ""                                       ;;
  esac
}

# ─── Parse args ───────────────────────────────────────────────────────────────

SOURCE_TX=""
DEST_RPC_OVERRIDE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc-url)  DEST_RPC_OVERRIDE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -*)         echo "Unknown flag: $1"; exit 1 ;;
    *)          SOURCE_TX="$1"; shift ;;
  esac
done

if [ -z "$SOURCE_TX" ]; then
  echo "Usage: $0 <source_tx_hash> [--rpc-url <dest_rpc>] [--dry-run]"
  exit 1
fi

# ─── Fetch message + attestation from IRIS API ────────────────────────────────

echo "Fetching CCTP message for tx: $SOURCE_TX"

# Source is always Arbitrum (only chain with a deployed CCTPBridgeAdapter)
SOURCE_DOMAIN="3"

echo "Source domain: $SOURCE_DOMAIN ($(domain_to_chain "$SOURCE_DOMAIN"))"

IRIS_RESPONSE=$(curl -sf "${IRIS_API}/v2/messages/${SOURCE_DOMAIN}?transactionHash=${SOURCE_TX}" 2>&1) || {
  echo "Error: Failed to fetch from IRIS API"
  echo "$IRIS_RESPONSE"
  exit 1
}

# Parse response (requires jq)
if ! command -v jq &>/dev/null; then
  echo "Error: 'jq' not found. Install it: brew install jq"
  exit 1
fi

MESSAGE_COUNT=$(echo "$IRIS_RESPONSE" | jq '.messages | length')
if [ "$MESSAGE_COUNT" -eq 0 ]; then
  echo "Error: No CCTP messages found for this transaction"
  exit 1
fi

MESSAGE=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].message')
ATTESTATION=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].attestation')
STATUS=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].status')
FORWARD_STATE=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].forwardState // "N/A"')
DEST_DOMAIN=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].decodedMessage.destinationDomain')
AMOUNT=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].decodedMessage.decodedMessageBody.amount')
RECIPIENT=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].decodedMessage.decodedMessageBody.mintRecipient')
MAX_FEE=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].decodedMessage.decodedMessageBody.maxFee')
FEE_EXECUTED=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].decodedMessage.decodedMessageBody.feeExecuted // "N/A"')
FORWARD_ERROR=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].forwardErrorCode // "none"')

DEST_CHAIN=$(domain_to_chain "$DEST_DOMAIN")
AMOUNT_USDC=$(echo "scale=6; $AMOUNT / 1000000" | bc)

echo ""
echo "=== CCTP Message Details ==="
echo "  Status:         $STATUS"
echo "  Forward state:  $FORWARD_STATE"
echo "  Forward error:  $FORWARD_ERROR"
echo "  Destination:    $DEST_CHAIN (domain $DEST_DOMAIN)"
echo "  Recipient:      $RECIPIENT"
echo "  Amount:         $AMOUNT_USDC USDC ($AMOUNT raw)"
echo "  Max fee:        $MAX_FEE raw"
echo "  Fee executed:   $FEE_EXECUTED raw"

if [ "$STATUS" != "complete" ]; then
  echo ""
  echo "Error: Message status is '$STATUS', not 'complete'. Attestation may not be ready."
  exit 1
fi

if [ -z "$ATTESTATION" ] || [ "$ATTESTATION" = "null" ]; then
  echo ""
  echo "Error: No attestation available"
  exit 1
fi

# ─── Determine destination RPC ────────────────────────────────────────────────

if [ -n "$DEST_RPC_OVERRIDE" ]; then
  DEST_RPC="$DEST_RPC_OVERRIDE"
else
  DEST_RPC=$(domain_to_rpc "$DEST_DOMAIN")
fi

if [ -z "$DEST_RPC" ]; then
  echo ""
  echo "Error: No RPC URL for $DEST_CHAIN. Pass --rpc-url <url>"
  exit 1
fi

echo "  Dest RPC:       $DEST_RPC"

# ─── Check if already received ────────────────────────────────────────────────

NONCE=$(echo "$IRIS_RESPONSE" | jq -r '.messages[0].eventNonce')
NONCE_USED=$(cast call "$MESSAGE_TRANSMITTER" "usedNonces(bytes32)(uint256)" "$NONCE" --rpc-url "$DEST_RPC" 2>/dev/null || echo "error")

if [ "$NONCE_USED" = "1" ]; then
  echo ""
  echo "Message already received on $DEST_CHAIN (nonce used). Nothing to do."
  exit 0
fi

# ─── Simulate ─────────────────────────────────────────────────────────────────

echo ""
echo "Simulating receiveMessage on $DEST_CHAIN..."

SIM_RESULT=$(cast call "$MESSAGE_TRANSMITTER" "receiveMessage(bytes,bytes)(bool)" "$MESSAGE" "$ATTESTATION" --rpc-url "$DEST_RPC" 2>&1) || {
  echo "Simulation FAILED:"
  echo "$SIM_RESULT"
  exit 1
}

GAS_ESTIMATE=$(cast estimate "$MESSAGE_TRANSMITTER" "receiveMessage(bytes,bytes)" "$MESSAGE" "$ATTESTATION" --rpc-url "$DEST_RPC" 2>/dev/null || echo "unknown")

echo "Simulation: OK (returned $SIM_RESULT)"
echo "Gas estimate: $GAS_ESTIMATE"

if $DRY_RUN; then
  echo ""
  echo "Dry run — not sending transaction."
  exit 0
fi

# ─── Send ─────────────────────────────────────────────────────────────────────

echo ""
echo "Sending receiveMessage on $DEST_CHAIN..."

TX_HASH=$(cast send "$MESSAGE_TRANSMITTER" \
  "receiveMessage(bytes,bytes)" \
  "$MESSAGE" "$ATTESTATION" \
  --rpc-url "$DEST_RPC" \
  --mnemonic "$MNEMONIC" \
  --mnemonic-index "$DERIVATION_INDEX" \
  --json 2>&1) || {
  echo "Transaction FAILED:"
  echo "$TX_HASH"
  exit 1
}

HASH=$(echo "$TX_HASH" | jq -r '.transactionHash')
echo "Transaction sent: $HASH"
echo ""
echo "Waiting for confirmation..."
cast receipt "$HASH" --rpc-url "$DEST_RPC" --confirmations 1 2>/dev/null | grep -E "status|gasUsed|transactionHash"

echo ""
echo "Done. $AMOUNT_USDC USDC should now be delivered to $RECIPIENT on $DEST_CHAIN."
