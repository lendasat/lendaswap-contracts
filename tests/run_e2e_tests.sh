#!/bin/bash
set -e

echo "=== Lendaswap E2E Test Runner ==="
echo

# Check if forge is installed
if ! command -v forge &> /dev/null; then
    echo "Error: forge not found. Please install Foundry first."
    echo "Visit: https://getfoundry.sh/"
    exit 1
fi

# Build contracts
echo "1. Building contracts..."
cd ..
forge build
echo "   ✓ Contracts built"

# Run E2E tests
echo
echo "2. Running E2E tests..."
cd tests
cargo test --test e2e_integration -- --nocapture

echo
echo "=== All E2E tests passed! ==="
