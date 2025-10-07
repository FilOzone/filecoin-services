#!/bin/bash
# deploy-warm-storage-implementation-only.sh - Deploy only FilecoinWarmStorageService implementation (no proxy)
# This allows updating an existing proxy to point to the new implementation
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set
# Assumption: forge, cast are in the PATH
# Assumption: called from service_contracts directory so forge paths work out

echo "Deploying FilecoinWarmStorageService Implementation Only (no proxy)"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
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

# Get deployer address
ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying from address: $ADDR"

# Get current nonce
NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

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

USDFC_TOKEN_ADDRESS="0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"    # USDFC token address on calibnet

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

WARM_STORAGE_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILBEAM_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS | grep "Deployed to" | awk '{print $3}')

if [ -z "$WARM_STORAGE_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to deploy FilecoinWarmStorageService implementation"
    exit 1
fi

echo ""
echo "# DEPLOYMENT COMPLETE"
echo "FilecoinWarmStorageService Implementation deployed at: $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
echo ""
