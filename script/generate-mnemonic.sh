#!/usr/bin/env bash
# Generate a new HD wallet mnemonic and print it in .env format.
set -euo pipefail

if ! command -v cast &>/dev/null; then
  echo "Error: 'cast' not found. Install Foundry: https://getfoundry.sh"
  exit 1
fi

OUTPUT=$(cast wallet new-mnemonic)

MNEMONIC=$(echo "$OUTPUT" | sed -n '/^Phrase:$/{ n; p; }')
ADDRESS=$(echo "$OUTPUT" | grep 'Address:' | awk '{ print $2 }')

echo "# Deployer address: $ADDRESS"
echo "MNEMONIC=\"$MNEMONIC\""
echo ""
echo "# RPC endpoints"
echo "ETH_RPC_URL="
echo "ARBITRUM_RPC_URL="
echo "POLYGON_RPC_URL="
