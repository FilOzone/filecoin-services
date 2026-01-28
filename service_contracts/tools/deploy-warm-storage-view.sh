#!/bin/bash

# env params:
# ETH_RPC_URL
# FWSS_PROXY_ADDRESS
# ETH_KEYSTORE
# PASSWORD

# Assumes
# - called from service_contracts directory
# - PATH has forge and cast

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

# Auto-detect chain ID from RPC
if [ -z "$CHAIN" ]; then
  export CHAIN=$(cast chain-id)
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

# Load deployments.json helpers and populate defaults if available
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"
load_deployment_addresses "$CHAIN"

if [ -z "$FWSS_PROXY_ADDRESS" ]; then
  echo "Error: FWSS_PROXY_ADDRESS is not set"
  exit 1
fi

if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Deploying FilecoinWarmStorageServiceStateView from address $ADDR..."

# Check if NONCE is already set (when called from main deploy script)
# If not, get it from the network (when running standalone)
if [ -z "$NONCE" ]; then
  NONCE="$(cast nonce "$ADDR")"
fi

export FWSS_VIEW_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView --constructor-args $FWSS_PROXY_ADDRESS | grep "Deployed to" | awk '{print $3}')

echo FilecoinWarmStorageServiceStateView deployed at $FWSS_VIEW_ADDRESS

# Persist deployment address + metadata
update_deployment_address "$CHAIN" "FWSS_VIEW_ADDRESS" "$FWSS_VIEW_ADDRESS"
update_deployment_metadata "$CHAIN"

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
  echo
  echo "🔍 Starting automatic contract verification..."

  pushd "$(dirname $0)/.." >/dev/null
  source tools/verify-contracts.sh
  verify_contracts_batch "$FWSS_VIEW_ADDRESS,src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView"
  popd >/dev/null
else
  echo
  echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
