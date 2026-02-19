#!/usr/bin/env bash
# Multi-chain HTLCCoordinator deployment using CREATE2 for deterministic addresses.
#
# Additional optional env vars (beyond those in common.sh):
#   MIN_BALANCE_WEI       - Minimum deployer balance in wei (default: 0.01 ETH)
#   DEPLOY_SALT           - CREATE2 salt for deterministic addresses (default: 0x0)
#                           Same salt + same bytecode + same deployer = same address on every chain.
#                           Bump the salt if redeploying new versions to a fresh address.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"

DEPLOY_SALT="${DEPLOY_SALT:-0x0000000000000000000000000000000000000000000000000000000000000000}"
# 0.01 ETH / MATIC in wei
MIN_BALANCE_WEI="${MIN_BALANCE_WEI:-10000000000000000}"

# Check for forge
if ! command -v forge &>/dev/null; then
  echo "Error: 'forge' not found. Install Foundry: https://getfoundry.sh"
  exit 1
fi

# ─── Pre-flight checks ───────────────────────────────────────────────────────

echo "============================================"
echo "  Multi-chain HTLCCoordinator Deployment"
echo "============================================"
echo ""
echo "Deployer address: $DEPLOYER"
echo "Derivation index: $DERIVATION_INDEX"
echo ""

# Build contracts first
echo "Building contracts..."
(cd "$CONTRACTS_DIR" && forge build --silent)
echo "Build successful."
echo ""

# ─── Predict CREATE2 addresses ─────────────────────────────────────────────
echo "CREATE2 salt: $DEPLOY_SALT"

# CREATE2 address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:]
compute_create2_address() {
  local deployer="$1" salt="$2" initcode_hash="$3"
  local packed="0xff${deployer#0x}${salt#0x}${initcode_hash#0x}"
  local hash
  hash=$(cast keccak "$packed")
  # Last 20 bytes of the hash = last 40 hex chars
  echo "0x${hash:26}"
}

# HTLCErc20 has no constructor args — init code is just the creation bytecode
HTLC_INITCODE=$(jq -r '.bytecode.object' "$CONTRACTS_DIR/out/HTLCErc20.sol/HTLCErc20.json")
HTLC_INITCODE_HASH=$(cast keccak "$HTLC_INITCODE")
HTLC_ADDRESS=$(compute_create2_address "$DEPLOYER" "$DEPLOY_SALT" "$HTLC_INITCODE_HASH")

echo "Predicted HTLCErc20 address:       $HTLC_ADDRESS"

# HTLCCoordinator constructor arg is the HTLC address — ABI-encoded and appended to creation bytecode
COORDINATOR_BYTECODE=$(jq -r '.bytecode.object' "$CONTRACTS_DIR/out/HTLCCoordinator.sol/HTLCCoordinator.json")
ENCODED_ARG=$(cast abi-encode "constructor(address)" "$HTLC_ADDRESS")
COORDINATOR_INITCODE="${COORDINATOR_BYTECODE}${ENCODED_ARG#0x}"
COORDINATOR_INITCODE_HASH=$(cast keccak "$COORDINATOR_INITCODE")
COORDINATOR_ADDRESS=$(compute_create2_address "$DEPLOYER" "$DEPLOY_SALT" "$COORDINATOR_INITCODE_HASH")

echo "Predicted HTLCCoordinator address: $COORDINATOR_ADDRESS"
echo ""

# ─── Balance checks ──────────────────────────────────────────────────────────

echo "Checking balances on target chains..."
echo "Minimum required: $(format_ether "$MIN_BALANCE_WEI") native tokens"
echo ""

DEPLOYABLE=()
SKIPPED=()

for i in "${!CHAINS[@]}"; do
  name="${CHAIN_NAMES[$i]}"
  rpc="${CHAIN_RPCS[$i]}"
  token="${CHAIN_TOKENS[$i]}"

  printf "  %-14s " "$name:"

  # Check RPC connectivity
  if ! check_rpc "$i"; then
    echo "SKIP (RPC unreachable or wrong chain ID)"
    SKIPPED+=("$i")
    continue
  fi

  # Check balance
  balance=$(get_balance "$rpc" "$DEPLOYER")
  if [ -z "$balance" ]; then
    echo "SKIP (could not fetch balance)"
    SKIPPED+=("$i")
    continue
  fi

  balance_formatted=$(format_ether "$balance")

  if [ "$(echo "$balance >= $MIN_BALANCE_WEI" | bc 2>/dev/null || python3 -c "print(1 if $balance >= $MIN_BALANCE_WEI else 0)")" = "1" ]; then
    echo "${balance_formatted} $token - OK"
    DEPLOYABLE+=("$i")
  else
    echo "${balance_formatted} $token - INSUFFICIENT"
    SKIPPED+=("$i")
  fi
done

echo ""

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "Skipping chains with insufficient balance or connectivity issues:"
  for i in "${SKIPPED[@]}"; do
    echo "  - ${CHAIN_NAMES[$i]}"
  done
  echo ""
fi

if [ ${#DEPLOYABLE[@]} -eq 0 ]; then
  echo "Error: No chains have sufficient balance for deployment."
  exit 1
fi

echo -n "Will deploy to:"
for i in "${DEPLOYABLE[@]}"; do echo -n " ${CHAINS[$i]}"; done
echo ""
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

for i in "${DEPLOYABLE[@]}"; do
  name="${CHAIN_NAMES[$i]}"
  rpc="${CHAIN_RPCS[$i]}"

  echo "────────────────────────────────────────────"
  echo "Deploying to $name..."
  echo "────────────────────────────────────────────"

  if (cd "$CONTRACTS_DIR" && \
      MNEMONIC="$MNEMONIC" DERIVATION_INDEX="$DERIVATION_INDEX" DEPLOY_SALT="$DEPLOY_SALT" \
      forge script script/DeployHTLCCoordinator.s.sol \
        --rpc-url "$rpc" \
        --broadcast \
        --verify \
        -vvv); then
    echo ""
    echo "$name deployment: SUCCESS"
    RESULTS+=("$i")
  else
    echo ""
    echo "$name deployment: FAILED"
    FAILURES+=("$i")
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
  for i in "${RESULTS[@]}"; do
    echo "  - ${CHAIN_NAMES[$i]}"
  done
fi

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo ""
  echo "Failed:"
  for i in "${FAILURES[@]}"; do
    echo "  - ${CHAIN_NAMES[$i]}"
  done
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo ""
  echo "Skipped (insufficient balance/connectivity):"
  for i in "${SKIPPED[@]}"; do
    echo "  - ${CHAIN_NAMES[$i]}"
  done
fi

echo ""

if [ ${#FAILURES[@]} -gt 0 ]; then
  exit 1
fi
