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

# Auto-detect chain ID from RPC
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
if [ -z "$CHAIN_ID" ]; then
  echo "Error: Failed to detect chain ID from RPC"
  exit 1
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
echo "Deploying FilecoinWarmStorageServiceStateView from address $ADDR..."

# Check if NONCE is already set (when called from main deploy script)
# If not, get it from the network (when running standalone)
if [ -z "$NONCE" ]; then
  NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"
fi

export WARM_STORAGE_VIEW_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView --constructor-args $WARM_STORAGE_SERVICE_ADDRESS | grep "Deployed to" | awk '{print $3}')

echo FilecoinWarmStorageServiceStateView deployed at $WARM_STORAGE_VIEW_ADDRESS

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
    echo
    echo "🔍 Starting automatic contract verification..."
    
    # Install filfox-verifier if needed
    if [ ! -d "$(dirname $0)/node_modules" ]; then
        cd "$(dirname $0)" && npm install
    fi
    
    # Detect chain ID for verification
    FILECOIN_NETWORK=${FILECOIN_NETWORK:-calibnet}
    if [ "$FILECOIN_NETWORK" = "mainnet" ]; then
        VERIFY_CHAIN_ID=314
    else
        VERIFY_CHAIN_ID=314159
    fi
    
    pushd "$(dirname $0)/.." > /dev/null
    npx filfox-verifier forge "$WARM_STORAGE_VIEW_ADDRESS" "src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView" --chain "$VERIFY_CHAIN_ID"
    popd > /dev/null
else
    echo
    echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
