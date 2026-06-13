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

SIGNATURE_LIB_DEPLOYED=false
if needs_deployment "$CHAIN" "SIGNATURE_VERIFICATION_LIB" \
        "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib" ""; then
  echo "Deploying SignatureVerificationLib..."
  export SIGNATURE_VERIFICATION_LIB_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE src/lib/SignatureVerificationLib.sol:SignatureVerificationLib | grep "Deployed to" | awk '{print $3}')

  if [ -z "$SIGNATURE_VERIFICATION_LIB_ADDRESS" ]; then
    echo "Error: Failed to deploy SignatureVerificationLib"
    exit 1
  fi
  echo "SignatureVerificationLib deployed at: $SIGNATURE_VERIFICATION_LIB_ADDRESS"
  SIGNATURE_LIB_DEPLOYED=true
  NONCE=$((NONCE + 1))
else
  echo "Using SignatureVerificationLib at: $SIGNATURE_VERIFICATION_LIB_ADDRESS"
fi

RAILS_LIB_DEPLOYED=false
if needs_deployment "$CHAIN" "RAILS_LIB" \
        "src/lib/Rails.sol:Rails" ""; then
  echo "Deploying Rails..."
  export RAILS_LIB_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE src/lib/Rails.sol:Rails | grep "Deployed to" | awk '{print $3}')

  if [ -z "$RAILS_LIB_ADDRESS" ]; then
    echo "Error: Failed to deploy Rails"
    exit 1
  fi
  echo "Rails deployed at: $RAILS_LIB_ADDRESS"
  RAILS_LIB_DEPLOYED=true
  NONCE=$((NONCE + 1))
else
  echo "Using Rails at: $RAILS_LIB_ADDRESS"
fi

FWSS_LIBS="src/lib/SignatureVerificationLib.sol:SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS,src/lib/Rails.sol:Rails:$RAILS_LIB_ADDRESS"
# Use the stored counter for the needs_deployment check.  The counter always increments
# on deployment, so passing the current (stored+1) value would produce a false "args
# changed" result when nothing else has changed.
STORED_FWSS_COUNTER=$(jq -r ".[\"$CHAIN\"].contracts.FWSS_IMPLEMENTATION.constructor_args[-1] // empty" \
    "$DEPLOYMENTS_JSON_PATH" 2>/dev/null)

FWSS_IMPL_DEPLOYED=false
if needs_deployment "$CHAIN" "FWSS_IMPLEMENTATION" \
        "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService" "$FWSS_LIBS" \
        "$PDP_VERIFIER_PROXY_ADDRESS" "$FILECOIN_PAY_ADDRESS" "$USDFC_TOKEN_ADDRESS" \
        "$FILBEAM_BENEFICIARY_ADDRESS" "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
        "$SESSION_KEY_REGISTRY_ADDRESS" "${STORED_FWSS_COUNTER:-1}"; then

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
        FWSS_INIT_COUNTER=$(expr $($SCRIPT_DIR/get-initialized-counter.sh $FWSS_PROXY_ADDRESS) + "1")
    else
        FWSS_INIT_COUNTER=1
    fi

    FWSS_IMPLEMENTATION_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE \
      --libraries "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS" \
      --libraries "src/lib/Rails.sol:Rails:$RAILS_LIB_ADDRESS" \
      src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService \
      --constructor-args $PDP_VERIFIER_PROXY_ADDRESS $FILECOIN_PAY_ADDRESS $USDFC_TOKEN_ADDRESS $FILBEAM_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS $FWSS_INIT_COUNTER | grep "Deployed to" | awk '{print $3}')

    if [ -z "$FWSS_IMPLEMENTATION_ADDRESS" ]; then
      echo "Error: Failed to deploy FilecoinWarmStorageService implementation"
      exit 1
    fi
    FWSS_IMPL_DEPLOYED=true
else
    echo "FilecoinWarmStorageService implementation unchanged, skipping deployment"
fi

echo ""
echo "# DEPLOYMENT COMPLETE"
echo "SignatureVerificationLib: $SIGNATURE_VERIFICATION_LIB_ADDRESS"
echo "Rails: $RAILS_LIB_ADDRESS"
echo "FilecoinWarmStorageService Implementation: $FWSS_IMPLEMENTATION_ADDRESS"
echo ""

# Persist deployment addresses + bytecode metadata
if [ "$SIGNATURE_LIB_DEPLOYED" = "true" ]; then
  update_deployment_address "$CHAIN" "SIGNATURE_VERIFICATION_LIB_ADDRESS" "$SIGNATURE_VERIFICATION_LIB_ADDRESS"
  update_deployment_bytecode "$CHAIN" "SIGNATURE_VERIFICATION_LIB" \
      "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib" ""
fi
if [ "$RAILS_LIB_DEPLOYED" = "true" ]; then
  update_deployment_address "$CHAIN" "RAILS_LIB_ADDRESS" "$RAILS_LIB_ADDRESS"
  update_deployment_bytecode "$CHAIN" "RAILS_LIB" \
      "src/lib/Rails.sol:Rails" ""
fi
if [ "$FWSS_IMPL_DEPLOYED" = "true" ]; then
  update_deployment_address "$CHAIN" "FWSS_IMPLEMENTATION_ADDRESS" "$FWSS_IMPLEMENTATION_ADDRESS"
  update_deployment_bytecode "$CHAIN" "FWSS_IMPLEMENTATION" \
      "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService" "$FWSS_LIBS" \
      "$PDP_VERIFIER_PROXY_ADDRESS" "$FILECOIN_PAY_ADDRESS" "$USDFC_TOKEN_ADDRESS" \
      "$FILBEAM_BENEFICIARY_ADDRESS" "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
      "$SESSION_KEY_REGISTRY_ADDRESS" "$FWSS_INIT_COUNTER"
fi
if [ "$FWSS_IMPL_DEPLOYED" = "true" ] || [ "$SIGNATURE_LIB_DEPLOYED" = "true" ] || [ "$RAILS_LIB_DEPLOYED" = "true" ]; then
  update_deployment_metadata "$CHAIN"
fi

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

