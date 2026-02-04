#!/bin/bash

# env params:
# ETH_RPC_URL
# ETH_KEYSTORE
# PASSWORD

# Assumes
# - called from service_contracts directory
# - PATH has forge and cast

# Get script directory and source deployments.sh
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"

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

# Load deployment addresses from deployments.json
load_deployment_addresses "$CHAIN"


if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Deploying SessionKeyRegistry from address $ADDR..."

# Check if NONCE is already set (when called from main deploy script)
# If not, get it from the network (when running standalone)
if [ -z "$NONCE" ]; then
  NONCE="$(cast nonce "$ADDR")"
fi

export SESSION_KEY_REGISTRY_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE lib/session-key-registry/src/SessionKeyRegistry.sol:SessionKeyRegistry | grep "Deployed to" | awk '{print $3}')

echo SessionKeyRegistry deployed at $SESSION_KEY_REGISTRY_ADDRESS

# Update deployments.json
if [ -n "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
    update_deployment_address "$CHAIN" "SESSION_KEY_REGISTRY_ADDRESS" "$SESSION_KEY_REGISTRY_ADDRESS"
    update_deployment_metadata "$CHAIN"
fi

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
  echo
  echo "🔍 Starting automatic contract verification..."

  pushd "$(dirname $0)/.." >/dev/null
  source tools/verify-contracts.sh
  verify_contracts_batch "$SESSION_KEY_REGISTRY_ADDRESS,lib/session-key-registry/src/SessionKeyRegistry.sol:SessionKeyRegistry"
  popd >/dev/null
else
  echo
  echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
