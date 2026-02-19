#!/usr/bin/env bash
# Print native token balances for the deployer address on all chains.
#
# Usage:
#   ./balances.sh          (reads from .env)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "Address: $DEPLOYER"
echo ""

for i in "${!CHAINS[@]}"; do
  name="${CHAIN_NAMES[$i]}"
  rpc="${CHAIN_RPCS[$i]}"
  token="${CHAIN_TOKENS[$i]}"

  printf "  %-14s " "$name:"

  if ! check_rpc "$i"; then
    echo "unreachable"
    continue
  fi

  balance=$(get_balance "$rpc" "$DEPLOYER")
  if [ -z "$balance" ]; then
    echo "error fetching balance"
    continue
  fi

  echo "$(format_ether "$balance") $token"
done
