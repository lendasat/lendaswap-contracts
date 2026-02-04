#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
# Required env vars:
#   MNEMONIC              - HD wallet mnemonic
#   ETH_RPC_URL           - Ethereum RPC endpoint
#   ARBITRUM_RPC_URL      - Arbitrum RPC endpoint
#   POLYGON_RPC_URL       - Polygon RPC endpoint
#
# Optional env vars:
#   DERIVATION_INDEX      - HD derivation index (default: 0)
#   MIN_BALANCE_WEI       - Minimum deployer balance in wei (default: 0.01 ETH)

MISSING=()
[ -z "${MNEMONIC:-}" ] && MISSING+=("MNEMONIC")
[ -z "${ETH_RPC_URL:-}" ] && MISSING+=("ETH_RPC_URL")
[ -z "${ARBITRUM_RPC_URL:-}" ] && MISSING+=("ARBITRUM_RPC_URL")
[ -z "${POLYGON_RPC_URL:-}" ] && MISSING+=("POLYGON_RPC_URL")

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: Missing required environment variables:"
  for var in "${MISSING[@]}"; do
    echo "  - $var"
  done
  exit 1
fi

DERIVATION_INDEX="${DERIVATION_INDEX:-0}"
# 0.01 ETH / MATIC in wei
MIN_BALANCE_WEI="${MIN_BALANCE_WEI:-10000000000000000}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Chain definitions ───────────────────────────────────────────────────────
declare -A RPC_URLS
declare -A CHAIN_NAMES
declare -A NATIVE_TOKENS
declare -A CHAIN_IDS

CHAINS=("ethereum" "arbitrum" "polygon")

CHAIN_NAMES[ethereum]="Ethereum"
CHAIN_NAMES[arbitrum]="Arbitrum One"
CHAIN_NAMES[polygon]="Polygon"

RPC_URLS[ethereum]="$ETH_RPC_URL"
RPC_URLS[arbitrum]="$ARBITRUM_RPC_URL"
RPC_URLS[polygon]="$POLYGON_RPC_URL"

NATIVE_TOKENS[ethereum]="ETH"
NATIVE_TOKENS[arbitrum]="ETH"
NATIVE_TOKENS[polygon]="MATIC"

CHAIN_IDS[ethereum]="1"
CHAIN_IDS[arbitrum]="42161"
CHAIN_IDS[polygon]="137"

# ─── Helpers ──────────────────────────────────────────────────────────────────

get_deployer_address() {
  cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$DERIVATION_INDEX" 2>/dev/null
}

get_balance() {
  local rpc_url="$1"
  local address="$2"
  cast balance "$address" --rpc-url "$rpc_url" 2>/dev/null
}

format_ether() {
  cast from-wei "$1" 2>/dev/null
}

check_rpc() {
  local chain="$1"
  local rpc_url="${RPC_URLS[$chain]}"
  local chain_id
  chain_id=$(cast chain-id --rpc-url "$rpc_url" 2>/dev/null) || return 1

  if [ "$chain_id" != "${CHAIN_IDS[$chain]}" ]; then
    echo "Warning: ${CHAIN_NAMES[$chain]} RPC returned chain ID $chain_id, expected ${CHAIN_IDS[$chain]}"
    return 1
  fi
  return 0
}

# ─── Pre-flight checks ───────────────────────────────────────────────────────

echo "============================================"
echo "  Multi-chain HTLCCoordinator Deployment"
echo "============================================"
echo ""

# Check dependencies
for cmd in forge cast; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' not found. Install Foundry: https://getfoundry.sh"
    exit 1
  fi
done

# Derive deployer address
DEPLOYER=$(get_deployer_address)
if [ -z "$DEPLOYER" ]; then
  echo "Error: Failed to derive address from mnemonic"
  exit 1
fi
echo "Deployer address: $DEPLOYER"
echo "Derivation index: $DERIVATION_INDEX"
echo ""

# Build contracts first
echo "Building contracts..."
(cd "$CONTRACTS_DIR" && forge build --silent)
echo "Build successful."
echo ""

# ─── Balance checks ──────────────────────────────────────────────────────────

echo "Checking balances on target chains..."
echo "Minimum required: $(format_ether "$MIN_BALANCE_WEI") native tokens"
echo ""

DEPLOYABLE_CHAINS=()
SKIPPED_CHAINS=()

for chain in "${CHAINS[@]}"; do
  name="${CHAIN_NAMES[$chain]}"
  rpc="${RPC_URLS[$chain]}"
  token="${NATIVE_TOKENS[$chain]}"

  printf "  %-14s " "$name:"

  # Check RPC connectivity
  if ! check_rpc "$chain"; then
    echo "SKIP (RPC unreachable or wrong chain ID)"
    SKIPPED_CHAINS+=("$chain")
    continue
  fi

  # Check balance
  balance=$(get_balance "$rpc" "$DEPLOYER")
  if [ -z "$balance" ]; then
    echo "SKIP (could not fetch balance)"
    SKIPPED_CHAINS+=("$chain")
    continue
  fi

  balance_formatted=$(format_ether "$balance")

  if [ "$(echo "$balance >= $MIN_BALANCE_WEI" | bc 2>/dev/null || python3 -c "print(1 if $balance >= $MIN_BALANCE_WEI else 0)")" = "1" ]; then
    echo "${balance_formatted} $token - OK"
    DEPLOYABLE_CHAINS+=("$chain")
  else
    echo "${balance_formatted} $token - INSUFFICIENT"
    SKIPPED_CHAINS+=("$chain")
  fi
done

echo ""

if [ ${#SKIPPED_CHAINS[@]} -gt 0 ]; then
  echo "Skipping chains with insufficient balance or connectivity issues:"
  for chain in "${SKIPPED_CHAINS[@]}"; do
    echo "  - ${CHAIN_NAMES[$chain]}"
  done
  echo ""
fi

if [ ${#DEPLOYABLE_CHAINS[@]} -eq 0 ]; then
  echo "Error: No chains have sufficient balance for deployment."
  exit 1
fi

echo "Will deploy to: ${DEPLOYABLE_CHAINS[*]}"
echo ""
read -r -p "Proceed with deployment? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled."
  exit 0
fi
echo ""

# ─── Deploy ───────────────────────────────────────────────────────────────────

RESULTS=()
FAILURES=()

for chain in "${DEPLOYABLE_CHAINS[@]}"; do
  name="${CHAIN_NAMES[$chain]}"
  rpc="${RPC_URLS[$chain]}"

  echo "────────────────────────────────────────────"
  echo "Deploying to $name..."
  echo "────────────────────────────────────────────"

  if (cd "$CONTRACTS_DIR" && \
      MNEMONIC="$MNEMONIC" DERIVATION_INDEX="$DERIVATION_INDEX" \
      forge script script/DeployHTLCCoordinator.s.sol \
        --rpc-url "$rpc" \
        --broadcast \
        --verify \
        -vvv); then
    echo ""
    echo "$name deployment: SUCCESS"
    RESULTS+=("$chain")
  else
    echo ""
    echo "$name deployment: FAILED"
    FAILURES+=("$chain")
  fi
  echo ""
done

# ─── Summary ──────────────────────────────────────────────────────────────────

echo "============================================"
echo "  Deployment Summary"
echo "============================================"

if [ ${#RESULTS[@]} -gt 0 ]; then
  echo ""
  echo "Successful:"
  for chain in "${RESULTS[@]}"; do
    echo "  - ${CHAIN_NAMES[$chain]}"
  done
fi

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo ""
  echo "Failed:"
  for chain in "${FAILURES[@]}"; do
    echo "  - ${CHAIN_NAMES[$chain]}"
  done
fi

if [ ${#SKIPPED_CHAINS[@]} -gt 0 ]; then
  echo ""
  echo "Skipped (insufficient balance/connectivity):"
  for chain in "${SKIPPED_CHAINS[@]}"; do
    echo "  - ${CHAIN_NAMES[$chain]}"
  done
fi

echo ""

if [ ${#FAILURES[@]} -gt 0 ]; then
  exit 1
fi
