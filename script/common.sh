#!/usr/bin/env bash
# Shared chain definitions and helpers for multi-chain scripts.
#
# Required env vars:
#   MNEMONIC              - HD wallet mnemonic
#   ETH_RPC_URL           - Ethereum RPC endpoint
#   ARBITRUM_RPC_URL      - Arbitrum RPC endpoint
#   POLYGON_RPC_URL       - Polygon RPC endpoint
#
# Optional env vars:
#   DERIVATION_INDEX      - HD derivation index (default: 0)

set -euo pipefail

# Load .env if found (check script dir, then contracts dir)
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$COMMON_DIR/.env" ]; then
  set -a
  source "$COMMON_DIR/.env"
  set +a
elif [ -f "$(dirname "$COMMON_DIR")/.env" ]; then
  set -a
  source "$(dirname "$COMMON_DIR")/.env"
  set +a
fi

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

# ─── Chain definitions (parallel arrays, bash 3.2 compatible) ────────────────
#           index:   0            1              2
CHAINS=(       "ethereum"    "arbitrum"      "polygon"  )
CHAIN_NAMES=(  "Ethereum"    "Arbitrum One"  "Polygon"  )
CHAIN_RPCS=(   "$ETH_RPC_URL" "$ARBITRUM_RPC_URL" "$POLYGON_RPC_URL" )
CHAIN_TOKENS=( "ETH"         "ETH"           "MATIC"    )
CHAIN_IDS=(    "1"           "42161"         "137"      )

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
  local idx="$1"
  local rpc_url="${CHAIN_RPCS[$idx]}"
  local chain_id
  chain_id=$(cast chain-id --rpc-url "$rpc_url" 2>/dev/null) || return 1

  if [ "$chain_id" != "${CHAIN_IDS[$idx]}" ]; then
    echo "Warning: ${CHAIN_NAMES[$idx]} RPC returned chain ID $chain_id, expected ${CHAIN_IDS[$idx]}"
    return 1
  fi
  return 0
}

# Check dependencies
if ! command -v cast &>/dev/null; then
  echo "Error: 'cast' not found. Install Foundry: https://getfoundry.sh"
  exit 1
fi

# Derive deployer address
DEPLOYER=$(get_deployer_address)
if [ -z "$DEPLOYER" ]; then
  echo "Error: Failed to derive address from mnemonic"
  exit 1
fi
