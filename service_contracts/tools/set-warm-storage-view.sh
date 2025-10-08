#!/bin/bash

# Helper script to set the view contract address on FilecoinWarmStorageService
# with clean output (suppresses verbose transaction details)
#
# Environment variables required:
# - RPC_URL: RPC endpoint URL
# - WARM_STORAGE_SERVICE_ADDRESS: Address of the deployed FilecoinWarmStorageService proxy
# - WARM_STORAGE_VIEW_ADDRESS: Address of the deployed FilecoinWarmStorageServiceStateView
# - KEYSTORE: Path to keystore file
# - PASSWORD: Keystore password
# - NONCE: Transaction nonce (optional, will fetch if not provided)


if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

# Auto-detect chain ID from RPC if not already set
if [ -z "$CHAIN" ]; then
  export CHAIN=$(cast chain-id)
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

if [ -z "$WARM_STORAGE_SERVICE_ADDRESS" ]; then
  echo "Error: WARM_STORAGE_SERVICE_ADDRESS is not set"
  exit 1
fi

if [ -z "$WARM_STORAGE_VIEW_ADDRESS" ]; then
  echo "Error: WARM_STORAGE_VIEW_ADDRESS is not set"
  exit 1
fi

if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

# Get sender address (cast will read ETH_KEYSTORE/ETH_PASSWORD)
ADDR=$(cast wallet address --password "$ETH_PASSWORD")

# Get nonce if not provided
# Get nonce if not provided
if [ -z "$NONCE" ]; then
  NONCE="$(cast nonce "$ADDR")"
fi

echo "Setting view contract address on FilecoinWarmStorageService..."

TX_OUTPUT=$(cast send --nonce $NONCE $WARM_STORAGE_SERVICE_ADDRESS "setViewContract(address)" $WARM_STORAGE_VIEW_ADDRESS 2>&1)

if [ $? -eq 0 ]; then
  echo "View contract address set successfully"
else
  echo "Error: Failed to set view contract address"
  echo "$TX_OUTPUT"
  exit 1
fi
