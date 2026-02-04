#!/bin/bash
# service-provider-registry-deploy.sh deploys the Service Provider Registry contract to a target network
# Assumption: ETH_KEYSTORE, PASSWORD, ETH_RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid ETH_RPC_URL for the target network.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#

# Get script directory and source deployments.sh
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"

echo "Deploying Service Provider Registry Contract"

WITH_PROXY=false
for arg in "$@"; do
  case "$arg" in
    --with-proxy)
      WITH_PROXY=true
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--with-proxy]"
      echo ""
      echo "Default: deploy implementation only (upgrade)."
      echo "  --with-proxy  Also deploy a new proxy and initialize it."
      exit 0
      ;;
    *)
      echo "Error: Unknown option '$arg'"
      echo "Run with --help for usage."
      exit 1
      ;;
  esac
done

if [ "$WITH_PROXY" = "true" ]; then
  echo "Mode: implementation + proxy deployment"
else
  echo "Mode: implementation-only deployment with no new proxy and no proxy changes"
fi

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

# Optional: Check if PASSWORD is set (some users might use empty password)
if [ -z "$PASSWORD" ]; then
  echo "Warning: PASSWORD is not set, using empty password"
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Deploying contracts from address $ADDR"

# Get current balance and nonce (cast will use ETH_RPC_URL)
BALANCE=$(cast balance "$ADDR")
echo "Deployer balance: $BALANCE"

NONCE="$(cast nonce "$ADDR")"
echo "Starting nonce: $NONCE"

# Deploy ServiceProviderRegistry implementation
echo ""
echo "=== STEP 1: Deploying ServiceProviderRegistry Implementation ==="
SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE src/ServiceProviderRegistry.sol:ServiceProviderRegistry --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')
if [ -z "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
  echo "Error: Failed to extract ServiceProviderRegistry implementation address"
  exit 1
fi
echo "✓ ServiceProviderRegistry implementation deployed at: $SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

if [ "$WITH_PROXY" = "true" ]; then
  # Deploy ServiceProviderRegistry proxy
  echo ""
  echo "=== STEP 2: Deploying ServiceProviderRegistry Proxy ==="
  # Initialize with no parameters for basic initialization
  INIT_DATA=$(cast calldata "initialize()")
  echo "Initialization calldata: $INIT_DATA"

  REGISTRY_PROXY_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS $INIT_DATA --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')
  if [ -z "$REGISTRY_PROXY_ADDRESS" ]; then
    echo "Error: Failed to extract ServiceProviderRegistry proxy address"
    exit 1
  fi
  echo "✓ ServiceProviderRegistry proxy deployed at: $REGISTRY_PROXY_ADDRESS"

  # Verify deployment by calling version() on the proxy
  echo ""
  echo "=== STEP 3: Verifying Deployment ==="
  VERSION=$(cast call $REGISTRY_PROXY_ADDRESS "version()(string)")
  if [ -z "$VERSION" ]; then
    echo "Warning: Could not verify contract version"
  else
    echo "✓ Contract version: $VERSION"
  fi

  # Get registration fee
  FEE=$(cast call $REGISTRY_PROXY_ADDRESS "REGISTRATION_FEE()(uint256)")
  if [ -z "$FEE" ]; then
      echo "Warning: Could not retrieve registration fee"
      FEE_IN_FIL="unknown"
  else
      echo "✓ Registration fee: $FEE attoFIL"
      FEE_IN_FIL="$FEE attoFIL"
  fi

  # Get burn actor address
  BURN_ACTOR=$(cast call $REGISTRY_PROXY_ADDRESS "BURN_ACTOR()(address)")
  if [ -z "$BURN_ACTOR" ]; then
    echo "Warning: Could not retrieve burn actor address"
  else
    echo "✓ Burn actor address: $BURN_ACTOR"
  fi

  # Get contract version (this should be used instead of hardcoded version)
  CONTRACT_VERSION=$(cast call $REGISTRY_PROXY_ADDRESS "VERSION()(string)")
  if [ -z "$CONTRACT_VERSION" ]; then
      echo "Warning: Could not retrieve contract version"
      CONTRACT_VERSION="Unknown"
  fi
else
  echo ""
  echo "=== STEP 2: Skipping Proxy Deployment ==="
  echo "Use --with-proxy to deploy and initialize a new proxy."
  CONTRACT_VERSION="n/a"
  FEE_IN_FIL="n/a"
  BURN_ACTOR="n/a"
fi

# Summary of deployed contracts
echo ""
echo "=========================================="
echo "=== DEPLOYMENT SUMMARY ==="
echo "=========================================="
echo "ServiceProviderRegistry Implementation: $SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
if [ "$WITH_PROXY" = "true" ]; then
  echo "ServiceProviderRegistry Proxy: $REGISTRY_PROXY_ADDRESS"
fi
echo "=========================================="

# Update deployments.json
if [ -n "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
    update_deployment_address "$CHAIN" "SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
fi
if [ "$WITH_PROXY" = "true" ] && [ -n "$REGISTRY_PROXY_ADDRESS" ]; then
    update_deployment_address "$CHAIN" "SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "$REGISTRY_PROXY_ADDRESS"
fi
if [ -n "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" ] || [ -n "$REGISTRY_PROXY_ADDRESS" ]; then
    update_deployment_metadata "$CHAIN"
fi
echo ""
echo "Contract Details:"
echo "  - Version: $CONTRACT_VERSION"
echo "  - Registration Fee: $FEE_IN_FIL (burned)"
echo "  - Burn Actor: $BURN_ACTOR"
CHAIN_LABEL="unknown"
if [ "$CHAIN" = "314159" ]; then
  CHAIN_LABEL="Calibration testnet (314159)"
elif [ "$CHAIN" = "314" ]; then
  CHAIN_LABEL="Filecoin mainnet (314)"
else
  CHAIN_LABEL="Chain ID $CHAIN"
fi
echo "  - Chain: $CHAIN_LABEL"
echo ""
echo "Next steps:"
if [ "$WITH_PROXY" = "true" ]; then
  echo "1. Save the proxy address: export REGISTRY_ADDRESS=$REGISTRY_PROXY_ADDRESS"
  echo "2. Verify the deployment by calling getProviderCount() - should return 0"
  echo "3. Test registration with: cast send --value <registration_fee>attoFIL ..."
  echo "4. Transfer ownership if needed using transferOwnership()"
  echo "5. The registry is ready for provider registrations"
else
  echo "1. Save the implementation address for upgrade announcement"
  echo "2. Proceed with service-provider-registry-announce-upgrade.sh"
fi
echo ""
if [ "$WITH_PROXY" = "true" ]; then
  echo "To interact with the registry:"
  echo "  View functions:"
  echo "    cast call $REGISTRY_PROXY_ADDRESS \"getProviderCount()(uint256)\""
  echo "    cast call $REGISTRY_PROXY_ADDRESS \"getAllActiveProviders()(uint256[])\""
  echo "  State changes (requires registration fee):"
  echo "    Register as provider (requires proper encoding of PDPData)"
  echo ""
fi

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
  echo
  echo "🔍 Starting automatic contract verification..."

  pushd "$(dirname $0)/.." >/dev/null
  source tools/verify-contracts.sh
  verify_contracts_batch "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS,src/ServiceProviderRegistry.sol:ServiceProviderRegistry"
  popd >/dev/null
else
  echo
  echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
echo "=========================================="
