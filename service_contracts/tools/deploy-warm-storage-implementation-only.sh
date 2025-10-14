#!/bin/bash
# deploy-warm-storage-implementation-only.sh - Deploy only FilecoinWarmStorageService implementation (no proxy)
# This allows updating an existing proxy to point to the new implementation
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set
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

# Get deployer address and nonce (cast will read ETH_KEYSTORE/PASSWORD/ETH_RPC_URL)
ADDR=$(cast wallet address --password "$PASSWORD" )
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

# Deploy SignatureVerificationLib first so we can link it into the implementation
echo "Deploying SignatureVerificationLib..."
SIGNATURE_VERIFICATION_LIB_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE src/lib/SignatureVerificationLib.sol:SignatureVerificationLib | grep "Deployed to" | awk '{print $3}')

if [ -z "$SIGNATURE_VERIFICATION_LIB_ADDRESS" ]; then
  echo "Error: Failed to deploy SignatureVerificationLib"
  exit 1
fi

echo "SignatureVerificationLib deployed at: $SIGNATURE_VERIFICATION_LIB_ADDRESS"

# Increment nonce for the next deployment
NONCE=$((NONCE + 1))

echo ""
echo "Deploying FilecoinWarmStorageService implementation..."
echo "Constructor arguments:"
echo "  PDPVerifier: $PDP_VERIFIER_ADDRESS"
echo "  Payments: $PAYMENTS_CONTRACT_ADDRESS"
echo "  USDFC Token: $USDFC_TOKEN_ADDRESS"
echo "  FilBeam Controller Address: $FILBEAM_CONTROLLER_ADDRESS"
echo "  FilBeam Beneficiary Address: $FILBEAM_BENEFICIARY_ADDRESS"
echo "  ServiceProviderRegistry: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "  SessionKeyRegistry: $SESSION_KEY_REGISTRY_ADDRESS"

WARM_STORAGE_IMPLEMENTATION_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE --libraries "SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS" src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILBEAM_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS | grep "Deployed to" | awk '{print $3}')

if [ -z "$WARM_STORAGE_IMPLEMENTATION_ADDRESS" ]; then
  echo "Error: Failed to deploy FilecoinWarmStorageService implementation"
  exit 1
fi

echo ""
echo "# DEPLOYMENT COMPLETE"
echo "SignatureVerificationLib deployed at: $SIGNATURE_VERIFICATION_LIB_ADDRESS"
echo "FilecoinWarmStorageService Implementation deployed at: $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
echo ""

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

