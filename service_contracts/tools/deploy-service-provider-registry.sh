#!/bin/bash
# deploys the ServiceProviderRegistry proxy and its implementation
#
# Environmental parameters:
# RPC_URL
# KEYSTORE
# PASSWORD

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

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

if [ -z "$PASSWORD" ]; then
  echo "Error: PASSWORD is not set"
  exit 1
fi

if [ -z "$ADDR" ]; then
  ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
fi

NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

echo "Deploying ServiceProviderRegistry implementation..."
export REGISTRY_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID src/ServiceProviderRegistry.sol:ServiceProviderRegistry | grep "Deployed to" | awk '{print $3}')
if [ -z "$REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
  echo "Error: Failed to extract ServiceProviderRegistry implementation address"
  exit 1
fi
echo "ServiceProviderRegistry implementation deployed at: $REGISTRY_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

echo "Deploying ServiceProviderRegistry proxy..."
REGISTRY_INIT_DATA=$(cast calldata "initialize()")
export SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $REGISTRY_IMPLEMENTATION_ADDRESS $REGISTRY_INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
  echo "Error: Failed to extract ServiceProviderRegistry proxy address"
  exit 1
fi
echo "ServiceProviderRegistry proxy deployed at: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
