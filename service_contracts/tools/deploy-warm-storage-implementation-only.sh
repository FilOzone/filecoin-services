#!/bin/bash
# deploy-warm-storage-implementation-only.sh - Deploy only FilecoinWarmStorageService implementation (no proxy)
# This allows updating an existing proxy to point to the new implementation
# Assumption: ETH_KEYSTORE, PASSWORD, ETH_RPC_URL env vars are set
# Assumption: forge, cast are in the PATH
# Assumption: called from service_contracts directory so forge paths work out

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source $SCRIPT_DIR/deployments.sh

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

load_deployment_addresses $CHAIN

# Get required addresses from environment or use defaults
if [ -z "$PDP_VERIFIER_PROXY_ADDRESS" ]; then
  echo "Error: PDP_VERIFIER_PROXY_ADDRESS is not set"
  exit 1
fi

if [ -z "$FILECOIN_PAY_ADDRESS" ]; then
  echo "Error: FILECOIN_PAY_ADDRESS is not set"
  exit 1
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

if [ -z "$SIGNATURE_VERIFICATION_LIB_ADDRESS" ]; then
  # Deploy SignatureVerificationLib first so we can link it into the implementation
  echo "Deploying SignatureVerificationLib..."
  export SIGNATURE_VERIFICATION_LIB_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE src/lib/SignatureVerificationLib.sol:SignatureVerificationLib | grep "Deployed to" | awk '{print $3}')

  if [ -z "$SIGNATURE_VERIFICATION_LIB_ADDRESS" ]; then
    echo "Error: Failed to deploy SignatureVerificationLib"
    exit 1
  fi
  echo "SignatureVerificationLib deployed at: $SIGNATURE_VERIFICATION_LIB_ADDRESS"
  # Increment nonce for the next deployment
  NONCE=$((NONCE + 1))
else
  echo "Using SignatureVerificationLib at: $SIGNATURE_VERIFICATION_LIB_ADDRESS"
fi

echo ""
echo "Deploying FilecoinWarmStorageService implementation..."
echo "Constructor arguments:"
echo "  PDPVerifier: $PDP_VERIFIER_PROXY_ADDRESS"
echo "  FilecoinPayV1: $FILECOIN_PAY_ADDRESS"
echo "  USDFC Token: $USDFC_TOKEN_ADDRESS"
echo "  FilBeam Beneficiary Address: $FILBEAM_BENEFICIARY_ADDRESS"
echo "  ServiceProviderRegistry: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "  SessionKeyRegistry: $SESSION_KEY_REGISTRY_ADDRESS"

if [ -n "$FWSS_PROXY_ADDRESS" ]; then
    FWSS_INIT_COUNTER=$(expr $(tools/get-initialized-counter $FWSS_PROXY_ADDRESS) + "1")
else
    FWSS_INIT_COUNTER=1
fi

FWSS_IMPLEMENTATION_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE --libraries "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS" src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --constructor-args $PDP_VERIFIER_PROXY_ADDRESS $FILECOIN_PAY_ADDRESS $USDFC_TOKEN_ADDRESS $FILBEAM_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS $FWSS_INIT_COUNTER | grep "Deployed to" | awk '{print $3}')

if [ -z "$FWSS_IMPLEMENTATION_ADDRESS" ]; then
  echo "Error: Failed to deploy FilecoinWarmStorageService implementation"
  exit 1
fi

echo ""
echo "# DEPLOYMENT COMPLETE"
echo "SignatureVerificationLib deployed at: $SIGNATURE_VERIFICATION_LIB_ADDRESS"
echo "FilecoinWarmStorageService Implementation deployed at: $FWSS_IMPLEMENTATION_ADDRESS"
echo ""

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
  echo
  echo "🔍 Starting automatic contract verification..."

  pushd "$(dirname $0)/.." >/dev/null
  source tools/verify-contracts.sh
  verify_contracts_batch "$FWSS_IMPLEMENTATION_ADDRESS,src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService"
  popd >/dev/null
else
  echo
  echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi

