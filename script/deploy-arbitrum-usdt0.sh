#!/usr/bin/env bash
# Deploy HTLCCoordinator (payable redeemAndExecute) + USDT0BridgeAdapter on Arbitrum.
#
# Usage:
#   ./deploy-arbitrum-usdt0.sh              # deploy for real
#   ./deploy-arbitrum-usdt0.sh --dry-run    # simulate only (no broadcast)
#
# Required env vars (set in .env or export):
#   MNEMONIC              - HD wallet mnemonic
#   ARBITRUM_RPC_URL      - Arbitrum RPC endpoint
#
# Optional:
#   DERIVATION_INDEX      - HD derivation index (default: 0)
#   DEPLOY_SALT           - CREATE2 salt (default: 0x0)
#   ETHERSCAN_API_KEY     - For contract verification

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
elif [ -f "$CONTRACTS_DIR/.env" ]; then
  set -a; source "$CONTRACTS_DIR/.env"; set +a
fi

# Validate
MISSING=()
[ -z "${MNEMONIC:-}" ] && MISSING+=("MNEMONIC")
[ -z "${ARBITRUM_RPC_URL:-}" ] && MISSING+=("ARBITRUM_RPC_URL")
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: Missing required environment variables:"
  for var in "${MISSING[@]}"; do echo "  - $var"; done
  exit 1
fi

DERIVATION_INDEX="${DERIVATION_INDEX:-0}"
DEPLOY_SALT="${DEPLOY_SALT:-0x0000000000000000000000000000000000000000000000000000000000000000}"

if ! command -v forge &>/dev/null; then
  echo "Error: 'forge' not found. Install Foundry: https://getfoundry.sh"
  exit 1
fi

DEPLOYER=$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$DERIVATION_INDEX" 2>/dev/null)

echo "============================================"
if $DRY_RUN; then
  echo "  Arbitrum USDT0 Deployment (DRY RUN)"
else
  echo "  Arbitrum USDT0 Deployment"
fi
echo "============================================"
echo ""
echo "Deployer:  $DEPLOYER"
echo "Chain:     Arbitrum One"
echo "Salt:      $DEPLOY_SALT"
echo ""

# Check balance
BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$ARBITRUM_RPC_URL" 2>/dev/null)
echo "Balance:   $(cast from-wei "$BALANCE") ETH"
echo ""

# Build
echo "Building contracts..."
(cd "$CONTRACTS_DIR" && forge build --silent)
echo "Build successful."
echo ""

if ! $DRY_RUN; then
  read -r -p "Deploy HTLCCoordinator + USDT0BridgeAdapter to Arbitrum? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
  echo ""
fi

# ─── Step 1: Deploy HTLCCoordinator ──────────────────────────────────────────

echo "────────────────────────────────────────────"
echo "Step 1: Deploying HTLCCoordinator..."
echo "────────────────────────────────────────────"

FORGE_ARGS=(script/DeployHTLCCoordinator.s.sol --rpc-url "$ARBITRUM_RPC_URL" -vvv)
if ! $DRY_RUN; then
  FORGE_ARGS+=(--broadcast)
  [ -n "${ETHERSCAN_API_KEY:-}" ] && FORGE_ARGS+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
fi

if ! (cd "$CONTRACTS_DIR" && \
    MNEMONIC="$MNEMONIC" DERIVATION_INDEX="$DERIVATION_INDEX" DEPLOY_SALT="$DEPLOY_SALT" \
    forge script "${FORGE_ARGS[@]}"); then
  echo "HTLCCoordinator deployment FAILED"
  exit 1
fi
echo ""

# ─── Step 2: Deploy USDT0BridgeAdapter ───────────────────────────────────────

echo "────────────────────────────────────────────"
echo "Step 2: Deploying USDT0BridgeAdapter..."
echo "────────────────────────────────────────────"

FORGE_ARGS=(script/DeployUSDT0BridgeAdapter.s.sol --rpc-url "$ARBITRUM_RPC_URL" -vvv)
if ! $DRY_RUN; then
  FORGE_ARGS+=(--broadcast)
  [ -n "${ETHERSCAN_API_KEY:-}" ] && FORGE_ARGS+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
fi

if ! (cd "$CONTRACTS_DIR" && \
    MNEMONIC="$MNEMONIC" DERIVATION_INDEX="$DERIVATION_INDEX" DEPLOY_SALT="$DEPLOY_SALT" \
    forge script "${FORGE_ARGS[@]}"); then
  echo "USDT0BridgeAdapter deployment FAILED"
  exit 1
fi
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────

echo "============================================"
echo "  Deployment Complete"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Update coordinator address in config (config.mainnet.yaml)"
echo "  2. Update adapter address in swap/src/usdt0_bridge.rs"
echo "  3. Rebuild and restart the backend"
echo ""
