#!/usr/bin/env bash

# Script to run E2E tests with proper environment setup

set -e

# Source environment to get anvil in PATH
if [ -f "$HOME/.zshenv" ]; then
    source "$HOME/.zshenv"
fi

# Ensure contracts are compiled
echo "Ensuring contracts are compiled..."
cd ..
forge build > /dev/null 2>&1
cd tests

# Run tests
echo "Running E2E tests..."
cargo test "$@"
