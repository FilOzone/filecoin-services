#!/bin/bash
# provider-id-set-deploy.sh deploys a ProviderIdSet contract
# Assumption: ETH_KEYSTORE, PASSWORD, ETH_RPC_URL env vars are set to an appropriate eth keystore path and password
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#

# Get script directory and source deployments.sh
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"

echo "Deploying ProviderIdSet Contract"

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

export CHAIN=$(cast chain-id)

if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

# Optional: Check if PASSWORD is set (some users might use empty password)
if [ -z "$PASSWORD" ]; then
  echo "Warning: PASSWORD is not set, using empty password"
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Deploying contracts from address $ADDR"

# Get current balance and nonce (cast will use ETH_RPC_URL)
BALANCE=$(cast balance "$ADDR")
echo "Deployer balance: $BALANCE"

if [ -z "$NONCE" ]; then
    NONCE="$(cast nonce "$ADDR")"
fi
echo "Using nonce: $NONCE"

# Deploy ProviderIdSet
ENDORSEMENT_SET_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE src/ProviderIdSet.sol:ProviderIdSet | grep "Deployed to" | awk '{print $3}')
if [ -z "$ENDORSEMENT_SET_ADDRESS" ]; then
  echo "Error: Failed to extract ProviderIdSet address"
  exit 1
fi
echo "✓ ProviderIdSet deployed at: $ENDORSEMENT_SET_ADDRESS"

# Update deployments.json
if [ -n "$ENDORSEMENT_SET_ADDRESS" ]; then
    update_deployment_address "$CHAIN" "ENDORSEMENT_SET_ADDRESS" "$ENDORSEMENT_SET_ADDRESS"
fi

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
  echo
  echo "🔍 Starting automatic contract verification..."

  pushd "$(dirname $0)/.." >/dev/null
  source tools/verify-contracts.sh
  verify_contracts_batch "$ENDORSEMENT_SET_ADDRESS,src/ProviderIdSet.sol:ProviderIdSet"
  popd >/dev/null
else
  echo
  echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
echo "=========================================="

