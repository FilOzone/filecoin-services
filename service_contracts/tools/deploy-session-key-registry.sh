#!/bin/bash

# env params:
# RPC_URL
# KEYSTORE
# PASSWORD

# Assumes
# - called from service_contracts directory
# - PATH has forge and cast

FILFOX_VERIFIER_VERSION="v1.4.4"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

# Auto-detect chain ID from RPC
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
if [ -z "$CHAIN_ID" ]; then
  echo "Error: Failed to detect chain ID from RPC"
  exit 1
fi

# Auto-detect chain ID from RPC if not already set
if [ -z "$CHAIN_ID" ]; then
  CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
  if [ -z "$CHAIN_ID" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying SessionKeyRegistry from address $ADDR..."

# Check if NONCE is already set (when called from main deploy script)
# If not, get it from the network (when running standalone)
if [ -z "$NONCE" ]; then
  NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"
fi

export SESSION_KEY_REGISTRY_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/session-key-registry/src/SessionKeyRegistry.sol:SessionKeyRegistry | grep "Deployed to" | awk '{print $3}')

echo SessionKeyRegistry deployed at $SESSION_KEY_REGISTRY_ADDRESS

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
    echo
    echo "🔍 Starting automatic contract verification..."
    
    pushd "$(dirname $0)/.." > /dev/null
    source tools/verify-contracts.sh
    verify_contracts_batch "$SESSION_KEY_REGISTRY_ADDRESS" "lib/session-key-registry/src/SessionKeyRegistry.sol:SessionKeyRegistry" "SessionKeyRegistry" "$CHAIN_ID"
    popd > /dev/null
else
    echo
    echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
