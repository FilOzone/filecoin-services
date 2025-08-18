#!/bin/bash

# env params:
# CHAIN_ID
# RPC_URL
# WARM_STORAGE_SERVICE_ADDRESS
# KEYSTORE
# PASSWORD

# Assumes
# - called from service_contracts directory
# - PATH has forge and cast

if [ -z "$CHAIN_ID" ]; then
  CHAIN_ID=314159
  echo "CHAIN_ID not set, assuming Calibnet ($CHAIN_ID)"
fi

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
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

if [ -z "$PASSWORD" ]; then
  echo "Error: PASSWORD is not set"
  exit 1
fi

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying contracts from address $ADDR"

NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

export WARM_STORAGE_VIEW_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID src/FilecoinWarmStorageServiceStateView.sol --constructor-args $WARM_STORAGE_SERVICE_ADDRESS | grep "Deployed to" | awk '{print $3}')

echo FilecoinWarmStorageServiceStateView deployed at $WARM_STORAGE_VIEW_ADDRESS
