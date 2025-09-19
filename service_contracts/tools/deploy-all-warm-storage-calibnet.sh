#! /bin/bash
# deploy-all-warm-storage-calibnet deploys the PDP verifier, Payments contract, and Warm Storage service to calibration net
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the calibnet.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#


FILFOX_VERIFIER_VERSION="v1.4.4"
# Get this script's directory so we can reliably source other scripts
# in the same directory, regardless of where this script is executed from
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"


echo "Deploying all Warm Storage contracts to calibnet"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

# Auto-detect chain ID from RPC
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
if [ -z "$CHAIN_ID" ]; then
  echo "Error: Failed to detect chain ID from RPC"
  exit 1
fi

# Verify we're on calibnet
if [ "$CHAIN_ID" != "314159" ]; then
  echo "Error: This script is for Filecoin Calibration testnet only"
  echo "  Expected chain ID: 314159 (calibnet)"
  echo "  Detected chain ID: $CHAIN_ID"
  exit 1
fi

echo "Detected Chain ID: $CHAIN_ID (calibnet)"

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

if [ -z "$CHALLENGE_FINALITY" ]; then
  echo "Error: CHALLENGE_FINALITY is not set"
  exit 1
fi

# Service name and description - mandatory environment variables
if [ -z "$SERVICE_NAME" ]; then
  echo "Error: SERVICE_NAME is not set. Please set SERVICE_NAME environment variable (max 256 characters)"
  exit 1
fi

if [ -z "$SERVICE_DESCRIPTION" ]; then
  echo "Error: SERVICE_DESCRIPTION is not set. Please set SERVICE_DESCRIPTION environment variable (max 256 characters)"
  exit 1
fi

# Validate name and description lengths
NAME_LENGTH=${#SERVICE_NAME}
DESC_LENGTH=${#SERVICE_DESCRIPTION}

if [ $NAME_LENGTH -eq 0 ] || [ $NAME_LENGTH -gt 256 ]; then
  echo "Error: SERVICE_NAME must be between 1 and 256 characters (current: $NAME_LENGTH)"
  exit 1
fi

if [ $DESC_LENGTH -eq 0 ] || [ $DESC_LENGTH -gt 256 ]; then
  echo "Error: SERVICE_DESCRIPTION must be between 1 and 256 characters (current: $DESC_LENGTH)"
  exit 1
fi

echo "Service configuration:"
echo "  Name: $SERVICE_NAME"
echo "  Description: $SERVICE_DESCRIPTION"

# Fixed addresses for initialization
PAYMENTS_CONTRACT_ADDRESS="0x0000000000000000000000000000000000000001" # TODO Placeholder to be updated later
if [ -z "$FILCDN_CONTROLLER_ADDRESS" ]; then
    FILCDN_CONTROLLER_ADDRESS="0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A"
fi
if [ -z "$FILCDN_BENEFICIARY_ADDRESS" ]; then
    FILCDN_BENEFICIARY_ADDRESS="0x1D60d2F5960Af6341e842C539985FA297E10d6eA"
fi
USDFC_TOKEN_ADDRESS="0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"    # USDFC token address

# Proving period configuration - use defaults if not set
MAX_PROVING_PERIOD="${MAX_PROVING_PERIOD:-30}"                      # Default 30 epochs (15 minutes on calibnet)
CHALLENGE_WINDOW_SIZE="${CHALLENGE_WINDOW_SIZE:-15}"                # Default 15 epochs

# Validate that the configuration will work with PDPVerifier's challengeFinality
# The calculation: (MAX_PROVING_PERIOD - CHALLENGE_WINDOW_SIZE) + (CHALLENGE_WINDOW_SIZE/2) must be >= CHALLENGE_FINALITY
# This ensures initChallengeWindowStart() + buffer will meet PDPVerifier requirements
MIN_REQUIRED=$((CHALLENGE_FINALITY + CHALLENGE_WINDOW_SIZE / 2))
if [ "$MAX_PROVING_PERIOD" -lt "$MIN_REQUIRED" ]; then
    echo "Error: MAX_PROVING_PERIOD ($MAX_PROVING_PERIOD) is too small for CHALLENGE_FINALITY ($CHALLENGE_FINALITY)"
    echo "       MAX_PROVING_PERIOD must be at least $MIN_REQUIRED (CHALLENGE_FINALITY + CHALLENGE_WINDOW_SIZE/2)"
    echo "       Either increase MAX_PROVING_PERIOD or decrease CHALLENGE_FINALITY"
    exit 1
fi

echo "Configuration validation passed:"
echo "  CHALLENGE_FINALITY=$CHALLENGE_FINALITY"
echo "  MAX_PROVING_PERIOD=$MAX_PROVING_PERIOD"
echo "  CHALLENGE_WINDOW_SIZE=$CHALLENGE_WINDOW_SIZE"

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying contracts from address $ADDR"

NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

if [ -z "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
    # If existing session key registry not supplied, deploy another one
    source "$SCRIPT_DIR/deploy-session-key-registry.sh"
    NONCE=$(expr $NONCE + "1")
fi

# Step 1: Deploy PDPVerifier implementation
echo "Deploying PDPVerifier implementation..."
VERIFIER_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/PDPVerifier.sol:PDPVerifier | grep "Deployed to" | awk '{print $3}')
if [ -z "$VERIFIER_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract PDPVerifier contract address"
    exit 1
fi
echo "PDPVerifier implementation deployed at: $VERIFIER_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 2: Deploy PDPVerifier proxy
echo "Deploying PDPVerifier proxy..."
INIT_DATA=$(cast calldata "initialize(uint256)" $CHALLENGE_FINALITY)
PDP_VERIFIER_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $VERIFIER_IMPLEMENTATION_ADDRESS $INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$PDP_VERIFIER_ADDRESS" ]; then
    echo "Error: Failed to extract PDPVerifier proxy address"
    exit 1
fi
echo "PDPVerifier proxy deployed at: $PDP_VERIFIER_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 3: Deploy Payments contract Implementation
echo "Deploying Payments contract..."
PAYMENTS_CONTRACT_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/fws-payments/src/Payments.sol:Payments | grep "Deployed to" | awk '{print $3}')
if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
    echo "Error: Failed to extract Payments contract address"
    exit 1
fi
echo "Payments contract deployed at: $PAYMENTS_CONTRACT_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 4: Deploy ServiceProviderRegistry implementation
echo "Deploying ServiceProviderRegistry implementation..."
REGISTRY_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID src/ServiceProviderRegistry.sol:ServiceProviderRegistry | grep "Deployed to" | awk '{print $3}')
if [ -z "$REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract ServiceProviderRegistry implementation address"
    exit 1
fi
echo "ServiceProviderRegistry implementation deployed at: $REGISTRY_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 5: Deploy ServiceProviderRegistry proxy
echo "Deploying ServiceProviderRegistry proxy..."
REGISTRY_INIT_DATA=$(cast calldata "initialize()")
SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $REGISTRY_IMPLEMENTATION_ADDRESS $REGISTRY_INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
    echo "Error: Failed to extract ServiceProviderRegistry proxy address"
    exit 1
fi
echo "ServiceProviderRegistry proxy deployed at: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 6: Deploy FilecoinWarmStorageService implementation
echo "Deploying FilecoinWarmStorageService implementation..."

SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILCDN_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS | grep "Deployed to" | awk '{print $3}')

if [ -z "$SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract FilecoinWarmStorageService contract address"
    exit 1
fi
echo "FilecoinWarmStorageService implementation deployed at: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 7: Deploy FilecoinWarmStorageService proxy
echo "Deploying FilecoinWarmStorageService proxy..."
# Initialize with max proving period, challenge window size, FilCDN controller address, name, and description
INIT_DATA=$(cast calldata "initialize(uint64,uint256,address,string,string)" $MAX_PROVING_PERIOD $CHALLENGE_WINDOW_SIZE $FILCDN_CONTROLLER_ADDRESS "$SERVICE_NAME" "$SERVICE_DESCRIPTION")
WARM_STORAGE_SERVICE_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS $INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$WARM_STORAGE_SERVICE_ADDRESS" ]; then
    echo "Error: Failed to extract FilecoinWarmStorageService proxy address"
    exit 1
fi
echo "FilecoinWarmStorageService proxy deployed at: $WARM_STORAGE_SERVICE_ADDRESS"


# Step 8: Deploy FilecoinWarmStorageServiceStateView
NONCE=$(expr $NONCE + "1")
source "$SCRIPT_DIR/deploy-warm-storage-view.sh"

# Step 9: Set the view contract address on the main contract
NONCE=$(expr $NONCE + "1")
source "$SCRIPT_DIR/set-warm-storage-view.sh"

# Summary of deployed contracts
echo
echo "# DEPLOYMENT SUMMARY"
echo "PDPVerifier Implementation: $VERIFIER_IMPLEMENTATION_ADDRESS"
echo "PDPVerifier Proxy: $PDP_VERIFIER_ADDRESS"
echo "Payments Contract: $PAYMENTS_CONTRACT_ADDRESS"
echo "ServiceProviderRegistry Implementation: $REGISTRY_IMPLEMENTATION_ADDRESS"
echo "ServiceProviderRegistry Proxy: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "FilecoinWarmStorageService Implementation: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
echo "FilecoinWarmStorageService Proxy: $WARM_STORAGE_SERVICE_ADDRESS"
echo "FilecoinWarmStorageServiceStateView: $WARM_STORAGE_VIEW_ADDRESS"
echo
echo "USDFC token address: $USDFC_TOKEN_ADDRESS"
echo "FilCDN controller address: $FILCDN_CONTROLLER_ADDRESS"
echo "FilCDN beneficiary address: $FILCDN_BENEFICIARY_ADDRESS"
echo "Max proving period: $MAX_PROVING_PERIOD epochs"
echo "Challenge window size: $CHALLENGE_WINDOW_SIZE epochs"
echo "Service name: $SERVICE_NAME"
echo "Service description: $SERVICE_DESCRIPTION"

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
    echo
    echo "🔍 Starting automatic contract verification..."
    
    # Verify all major contracts
    pushd "$(dirname $0)/.." > /dev/null
    npm exec -y -- filfox-verifier@$FILFOX_VERIFIER_VERSION forge $PDP_VERIFIER_ADDRESS src/PDPVerifier.sol:PDPVerifier --chain $CHAIN_ID
    npm exec -y -- filfox-verifier@$FILFOX_VERIFIER_VERSION forge $PAYMENTS_CONTRACT_ADDRESS src/Payments.sol:Payments --chain $CHAIN_ID
    npm exec -y -- filfox-verifier@$FILFOX_VERIFIER_VERSION forge $REGISTRY_IMPLEMENTATION_ADDRESS src/ServiceProviderRegistry.sol:ServiceProviderRegistry --chain $CHAIN_ID
    npm exec -y -- filfox-verifier@$FILFOX_VERIFIER_VERSION forge $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --chain $CHAIN_ID
    npm exec -y -- filfox-verifier@$FILFOX_VERIFIER_VERSION forge $WARM_STORAGE_VIEW_ADDRESS src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView --chain $CHAIN_ID
    
    # Verify proxy contracts
    echo "🔍 Verifying proxy contracts..."
    npm exec -y -- filfox-verifier@$FILFOX_VERIFIER_VERSION forge $REGISTRY_PROXY_ADDRESS lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --chain $CHAIN_ID
    npm exec -y -- filfox-verifier@$FILFOX_VERIFIER_VERSION forge $WARM_STORAGE_SERVICE_ADDRESS lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --chain $CHAIN_ID
    popd > /dev/null
else
    echo
    echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
