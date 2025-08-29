#!/bin/bash

# env params:
# CHAIN_ID
# RPC_URL
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
