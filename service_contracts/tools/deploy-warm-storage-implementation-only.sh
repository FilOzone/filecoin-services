#!/bin/bash
# deploy-warm-storage-implementation-only.sh - Deploy only FilecoinWarmStorageService implementation (no proxy)
# This allows updating an existing proxy to point to the new implementation
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set
# Optional: WARM_STORAGE_PROXY_ADDRESS to automatically upgrade the proxy
# Optional: DEPLOY_VIEW_CONTRACT=true to deploy a new view contract during upgrade
# Optional: VIEW_CONTRACT_ADDRESS=0x... to use an existing view contract during upgrade
# Assumption: forge, cast are in the PATH
# Assumption: called from service_contracts directory so forge paths work out

echo "Deploying FilecoinWarmStorageService Implementation Only (no proxy)"

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


if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

# Get deployer address and nonce (cast will read ETH_KEYSTORE/ETH_PASSWORD/ETH_RPC_URL)
ADDR=$(cast wallet address)
echo "Deploying from address: $ADDR"

# Get current nonce
NONCE="$(cast nonce "$ADDR")"

# Get required addresses from environment or use defaults
if [ -z "$PDP_VERIFIER_ADDRESS" ]; then
  echo "Error: PDP_VERIFIER_ADDRESS is not set"
  exit 1
fi

if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
  echo "Error: PAYMENTS_CONTRACT_ADDRESS is not set"
  exit 1
fi

if [ -z "$FILBEAM_CONTROLLER_ADDRESS" ]; then
  echo "Warning: FILBEAM_CONTROLLER_ADDRESS not set, using default"
  FILBEAM_CONTROLLER_ADDRESS="0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A"
fi

if [ -z "$FILBEAM_BENEFICIARY_ADDRESS" ]; then
  echo "Warning: FILBEAM_BENEFICIARY_ADDRESS not set, using default"
  FILBEAM_BENEFICIARY_ADDRESS="0x1D60d2F5960Af6341e842C539985FA297E10d6eA"
fi

if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
  echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not set"
  exit 1
fi

if [ -z "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
  echo "Error: SESSION_KEY_REGISTRY_ADDRESS is not set"
  exit 1
fi

USDFC_TOKEN_ADDRESS="0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0" # USDFC token address on calibnet

# Deploy FilecoinWarmStorageService implementation
echo "Deploying FilecoinWarmStorageService implementation..."
echo "Constructor arguments:"
echo "  PDPVerifier: $PDP_VERIFIER_ADDRESS"
echo "  Payments: $PAYMENTS_CONTRACT_ADDRESS"
echo "  USDFC Token: $USDFC_TOKEN_ADDRESS"
echo "  FilBeam Controller Address: $FILBEAM_CONTROLLER_ADDRESS"
echo "  FilBeam Beneficiary Address: $FILBEAM_BENEFICIARY_ADDRESS"
echo "  ServiceProviderRegistry: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "  SessionKeyRegistry: $SESSION_KEY_REGISTRY_ADDRESS"

WARM_STORAGE_IMPLEMENTATION_ADDRESS=$(forge create --broadcast --nonce $NONCE src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILBEAM_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS | grep "Deployed to" | awk '{print $3}')

if [ -z "$WARM_STORAGE_IMPLEMENTATION_ADDRESS" ]; then
  echo "Error: Failed to deploy FilecoinWarmStorageService implementation"
  exit 1
fi

echo ""
echo "# DEPLOYMENT COMPLETE"
echo "FilecoinWarmStorageService Implementation deployed at: $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
echo ""

# If proxy address is provided, perform the upgrade
if [ -n "$WARM_STORAGE_PROXY_ADDRESS" ]; then
  echo "Proxy address provided: $WARM_STORAGE_PROXY_ADDRESS"

  # First check if we're the owner
  echo "Checking proxy ownership..."
  PROXY_OWNER=$(cast call "$WARM_STORAGE_PROXY_ADDRESS" "owner()(address)" 2>/dev/null || echo "")

  if [ -z "$PROXY_OWNER" ]; then
    echo "Warning: Could not determine proxy owner. Attempting upgrade anyway..."
  else
    echo "Proxy owner: $PROXY_OWNER"
    echo "Your address: $ADDR"

    if [ "$PROXY_OWNER" != "$ADDR" ]; then
      echo
      echo "⚠️  WARNING: You are not the owner of this proxy!"
      echo "Only the owner ($PROXY_OWNER) can upgrade this proxy."
      echo
      echo "If you need to upgrade, you have these options:"
      echo "1. Have the owner run this script"
      echo "2. Have the owner transfer ownership to you first"
      echo "3. If the owner is a multisig, create a proposal"
      echo
      echo "To manually upgrade (as owner):"
    echo "cast send $WARM_STORAGE_PROXY_ADDRESS \"upgradeTo(address)\" $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
      exit 1
    fi
  fi

  echo "Performing proxy upgrade..."

  # Check if we should deploy and set a new view contract
  if [ -n "$DEPLOY_VIEW_CONTRACT" ] && [ "$DEPLOY_VIEW_CONTRACT" = "true" ]; then
    echo "Deploying new view contract for upgraded proxy..."
    NONCE=$(expr $NONCE + "1")
    export WARM_STORAGE_SERVICE_ADDRESS=$WARM_STORAGE_PROXY_ADDRESS
    source tools/deploy-warm-storage-view.sh
    echo "New view contract deployed at: $WARM_STORAGE_VIEW_ADDRESS"

    # Prepare migrate call with view contract address
    MIGRATE_DATA=$(cast calldata "migrate(address)" "$WARM_STORAGE_VIEW_ADDRESS")
  else
    # Check if a view contract address was provided
    if [ -n "$VIEW_CONTRACT_ADDRESS" ]; then
      echo "Using provided view contract address: $VIEW_CONTRACT_ADDRESS"
      MIGRATE_DATA=$(cast calldata "migrate(address)" "$VIEW_CONTRACT_ADDRESS")
    else
      echo "No view contract address provided, using address(0) in migrate"
      MIGRATE_DATA=$(cast calldata "migrate(address)" "0x0000000000000000000000000000000000000000")
    fi
  fi

  # Increment nonce for next transaction
  NONCE=$(expr $NONCE + "1")

  # Call upgradeToAndCall on the proxy with migrate function
  echo "Upgrading proxy and calling migrate..."
  TX_HASH=$(cast send "$WARM_STORAGE_PROXY_ADDRESS" "upgradeToAndCall(address,bytes)" "$WARM_STORAGE_IMPLEMENTATION_ADDRESS" "$MIGRATE_DATA" \
  --nonce "$NONCE" \
    --json | jq -r '.transactionHash')

  if [ -z "$TX_HASH" ]; then
    echo "Error: Failed to send upgrade transaction"
    echo "The transaction may have failed due to:"
    echo "- Insufficient permissions (not owner)"
    echo "- Proxy is paused or locked"
    echo "- Implementation address is invalid"
    exit 1
  fi

  echo "Upgrade transaction sent: $TX_HASH"
  echo "Waiting for confirmation..."

  # Wait for transaction receipt
  cast receipt "$TX_HASH" --confirmations 1 >/dev/null

  NEW_IMPL=$(cast rpc eth_getStorageAt "$WARM_STORAGE_PROXY_ADDRESS" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc latest | sed 's/"//g' | sed 's/0x000000000000000000000000/0x/')

  if [ "$NEW_IMPL" = "$WARM_STORAGE_IMPLEMENTATION_ADDRESS" ]; then
    echo "✅ Upgrade successful! Proxy now points to: $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
  else
    echo "⚠️  Warning: Could not verify upgrade. Please check manually."
    echo "Expected: $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
    echo "Got: $NEW_IMPL"
  fi
else
  echo "No WARM_STORAGE_PROXY_ADDRESS provided. Skipping automatic upgrade."
  echo ""
  echo "To upgrade an existing proxy manually:"
  echo "1. Export the proxy address: export WARM_STORAGE_PROXY_ADDRESS=<your_proxy_address>"
  echo "2. Run this script again, or"
  echo "3. Run manually:"
  echo "   cast send <PROXY_ADDRESS> \"upgradeTo(address)\" $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
fi

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
  echo
  echo "🔍 Starting automatic contract verification..."

  pushd "$(dirname $0)/.." >/dev/null
  source tools/verify-contracts.sh
  verify_contracts_batch "$WARM_STORAGE_IMPLEMENTATION_ADDRESS,src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService"
  popd >/dev/null
else
  echo
  echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
