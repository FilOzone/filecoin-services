#!/bin/bash
# warm-storage-deploy-implementation.sh - Deploy only FilecoinWarmStorageService implementation (no proxy)
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

# Load deployments.json helpers and populate defaults if available
source "$(dirname "$0")/deployments.sh"
load_deployment_addresses "$CHAIN"


if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

# Get deployer address and nonce (cast will read ETH_KEYSTORE/PASSWORD/ETH_RPC_URL)
ADDR=$(cast wallet address --password "$PASSWORD" )
echo "Deploying from address: $ADDR"

# Get current nonce
NONCE="$(cast nonce "$ADDR")"
BROADCAST_FLAG="--broadcast"

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

# Set network-specific USDFC token address based on chain ID
case "$CHAIN" in
  "31415926")
    # Devnet requires explicit USDFC_TOKEN_ADDRESS (mock token)
    if [ -z "$USDFC_TOKEN_ADDRESS" ]; then
      echo "Error: USDFC_TOKEN_ADDRESS is not set (required for devnet)"
      echo "Please set USDFC_TOKEN_ADDRESS to your deployed MockUSDFC address"
      exit 1
    fi
    ;;
  "314159")
    USDFC_TOKEN_ADDRESS="${USDFC_TOKEN_ADDRESS:-0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0}" # calibnet
    ;;
  "314")
    USDFC_TOKEN_ADDRESS="${USDFC_TOKEN_ADDRESS:-0x80B98d3aa09ffff255c3ba4A241111Ff1262F045}" # mainnet
    ;;
  *)
    echo "Error: Unsupported network"
    echo "  Supported networks:"
    echo "    31415926 - Filecoin local development network"
    echo "    314159   - Filecoin Calibration testnet"
    echo "    314      - Filecoin mainnet"
    echo "  Detected chain ID: $CHAIN"
    exit 1
    ;;
esac

deploy_implementation_if_needed \
    "SIGNATURE_VERIFICATION_LIB_ADDRESS" \
    "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib" \
    "SignatureVerificationLib"

deploy_implementation_if_needed \
    "RAILS_LIB_ADDRESS" \
    "src/lib/Rails.sol:Rails" \
    "Rails"

if [ -n "$FWSS_PROXY_ADDRESS" ]; then
    FWSS_INIT_COUNTER=$($SCRIPT_DIR/get-initialized-counter.sh $FWSS_PROXY_ADDRESS)
else
    FWSS_INIT_COUNTER=0
fi
LIBRARIES="src/lib/SignatureVerificationLib.sol:SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS,src/lib/Rails.sol:Rails:$RAILS_LIB_ADDRESS"
deploy_implementation_if_needed \
    "FWSS_IMPLEMENTATION_ADDRESS" \
    "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService" \
    "FilecoinWarmStorageService implementation" \
    "pdp_verifier=$PDP_VERIFIER_PROXY_ADDRESS" \
    "filecoin_pay=$FILECOIN_PAY_ADDRESS" \
    "usdfc_token=$USDFC_TOKEN_ADDRESS" \
    "filbeam_beneficiary=$FILBEAM_BENEFICIARY_ADDRESS" \
    "service_provider_registry=$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    "session_key_registry=$SESSION_KEY_REGISTRY_ADDRESS" \
    "reinitializer=$FWSS_INIT_COUNTER"
unset LIBRARIES

echo ""
echo "# DEPLOYMENT COMPLETE"
echo "SignatureVerificationLib: $SIGNATURE_VERIFICATION_LIB_ADDRESS"
echo "Rails: $RAILS_LIB_ADDRESS"
echo "FilecoinWarmStorageService Implementation: $FWSS_IMPLEMENTATION_ADDRESS"
echo ""

update_deployment_metadata "$CHAIN"

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
  echo
  echo "🔍 Starting automatic contract verification..."

  pushd "$(dirname $0)/.." >/dev/null
  source $SCRIPT_DIR/verify-contracts.sh
  verify_contracts_batch \
    "$SIGNATURE_VERIFICATION_LIB_ADDRESS,src/lib/SignatureVerificationLib.sol:SignatureVerificationLib" \
    "$RAILS_LIB_ADDRESS,src/lib/Rails.sol:Rails" \
    "$FWSS_IMPLEMENTATION_ADDRESS,src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService"
  popd >/dev/null
else
  echo
  echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi

