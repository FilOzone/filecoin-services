#!/bin/bash

# env params:
# RPC_URL
# WARM_STORAGE_SERVICE_ADDRESS
# KEYSTORE
# PASSWORD

# Assumes
# - called from service_contracts directory
# - PATH has forge and cast

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
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

if [ -z "$WARM_STORAGE_SERVICE_ADDRESS" ]; then
  echo "Error: WARM_STORAGE_SERVICE_ADDRESS is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")

# Get the current git commit hash
GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
echo "Git commit: $GIT_COMMIT"
echo "Deploying FilecoinWarmStorageServiceStateView from address $ADDR..."

# Check if NONCE is already set (when called from main deploy script)
# If not, get it from the network (when running standalone)
if [ -z "$NONCE" ]; then
  NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"
fi

export WARM_STORAGE_VIEW_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView --constructor-args $WARM_STORAGE_SERVICE_ADDRESS | grep "Deployed to" | awk '{print $3}')

echo "FilecoinWarmStorageServiceStateView deployed at $WARM_STORAGE_VIEW_ADDRESS"
echo "Git commit: $GIT_COMMIT"
