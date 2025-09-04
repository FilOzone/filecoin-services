#! /bin/bash
# deploy-warm-storage-calibnet deploys the Warm Storage service contract to calibration net
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the calibnet.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#
echo "Deploying Warm Storage Service Contract"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
  echo "Error: PAYMENTS_CONTRACT_ADDRESS is not set"
  exit 1
fi

if [ -z "$PDP_VERIFIER_ADDRESS" ]; then
  echo "Error: PDP_VERIFIER_ADDRESS is not set"
  exit 1
fi

if [ -z "$FILCDN_CONTROLLER_ADDRESS" ]; then
  echo "Error: FILCDN_CONTROLLER_ADDRESS is not set"
  exit 1
fi


if [ -z "$FILCDN_BENEFICIARY_ADDRESS" ]; then
  echo "Error: FILCDN_BENEFICIARY_ADDRESS is not set"
  exit 1
fi

if [ -z "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
  echo "Error: SESSION_KEY_REGISTRY_ADDRESS is not set"
  exit 1
fi

if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
  echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not set"
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

# Fixed constants for initialization
USDFC_TOKEN_ADDRESS="0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"    # USDFC token address

# Proving period configuration - use defaults if not set
MAX_PROVING_PERIOD="${MAX_PROVING_PERIOD:-30}"                      # Default 30 epochs (15 minutes on calibnet)
CHALLENGE_WINDOW_SIZE="${CHALLENGE_WINDOW_SIZE:-15}"                # Default 15 epochs

# Query the actual challengeFinality from PDPVerifier
echo "Querying PDPVerifier's challengeFinality..."
CHALLENGE_FINALITY=$(cast call $PDP_VERIFIER_ADDRESS "getChallengeFinality()" --rpc-url "$RPC_URL" | cast --to-dec)
echo "PDPVerifier challengeFinality: $CHALLENGE_FINALITY"

# Validate that the configuration will work with PDPVerifier's challengeFinality
# The calculation: (MAX_PROVING_PERIOD - CHALLENGE_WINDOW_SIZE) + (CHALLENGE_WINDOW_SIZE/2) must be >= CHALLENGE_FINALITY
# This ensures initChallengeWindowStart() + buffer will meet PDPVerifier requirements
MIN_REQUIRED=$((CHALLENGE_FINALITY + CHALLENGE_WINDOW_SIZE / 2))
if [ "$MAX_PROVING_PERIOD" -lt "$MIN_REQUIRED" ]; then
    echo "Error: MAX_PROVING_PERIOD ($MAX_PROVING_PERIOD) is too small for PDPVerifier's challengeFinality ($CHALLENGE_FINALITY)"
    echo "       MAX_PROVING_PERIOD must be at least $MIN_REQUIRED (CHALLENGE_FINALITY + CHALLENGE_WINDOW_SIZE/2)"
    echo "       To fix: Set MAX_PROVING_PERIOD to at least $MIN_REQUIRED"
    echo ""
    echo "       Example: MAX_PROVING_PERIOD=$MIN_REQUIRED CHALLENGE_WINDOW_SIZE=$CHALLENGE_WINDOW_SIZE ./deploy-warm-storage-calibnet.sh"
    exit 1
fi

echo "Configuration validation passed:"
echo "  PDPVerifier challengeFinality: $CHALLENGE_FINALITY"
echo "  MAX_PROVING_PERIOD: $MAX_PROVING_PERIOD epochs"
echo "  CHALLENGE_WINDOW_SIZE: $CHALLENGE_WINDOW_SIZE epochs"

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying contracts from address $ADDR"

NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

# Deploy FilecoinWarmStorageService implementation
echo "Deploying FilecoinWarmStorageService implementation..."
SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILCDN_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS | grep "Deployed to" | awk '{print $3}')
if [ -z "$SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract FilecoinWarmStorageService contract address"
    exit 1
fi
echo "FilecoinWarmStorageService implementation deployed at: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Deploy FilecoinWarmStorageService proxy
echo "Deploying FilecoinWarmStorageService proxy..."
# Initialize with max proving period, challenge window size, FilCDN controller address, name, and description
INIT_DATA=$(cast calldata "initialize(uint64,uint256,address,string,string)" $MAX_PROVING_PERIOD $CHALLENGE_WINDOW_SIZE $FILCDN_CONTROLLER_ADDRESS "$SERVICE_NAME" "$SERVICE_DESCRIPTION")
WARM_STORAGE_SERVICE_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS $INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$WARM_STORAGE_SERVICE_ADDRESS" ]; then
    echo "Error: Failed to extract FilecoinWarmStorageService proxy address"
    exit 1
fi
echo "FilecoinWarmStorageService proxy deployed at: $WARM_STORAGE_SERVICE_ADDRESS"

# Summary of deployed contracts
echo
echo "# DEPLOYMENT SUMMARY"
echo "FilecoinWarmStorageService Implementation: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
echo "FilecoinWarmStorageService Proxy: $WARM_STORAGE_SERVICE_ADDRESS"
echo
echo "USDFC token address: $USDFC_TOKEN_ADDRESS"
echo "PDPVerifier address: $PDP_VERIFIER_ADDRESS"
echo "Payments contract address: $PAYMENTS_CONTRACT_ADDRESS"
echo "FilCDN controller address: $FILCDN_CONTROLLER_ADDRESS"
echo "FilCDN beneficiary address: $FILCDN_BENEFICIARY_ADDRESS"
echo "ServiceProviderRegistry address: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "Max proving period: $MAX_PROVING_PERIOD epochs"
echo "Challenge window size: $CHALLENGE_WINDOW_SIZE epochs"
echo "Service name: $SERVICE_NAME"
echo "Service description: $SERVICE_DESCRIPTION"
