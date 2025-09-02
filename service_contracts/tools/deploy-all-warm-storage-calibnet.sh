#! /bin/bash
# deploy-all-warm-storage-calibnet deploys the PDP verifier, Payments contract, and Warm Storage service to calibration net
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the calibnet.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#
echo "Deploying all Warm Storage contracts to calibnet"

CHAIN_ID=314159

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

if [ -z "$CHALLENGE_FINALITY" ]; then
  echo "Error: CHALLENGE_FINALITY is not set"
  exit 1
fi

# Fixed addresses for initialization
PAYMENTS_CONTRACT_ADDRESS="0x0000000000000000000000000000000000000001" # TODO Placeholder to be updated later
if [ -z "$FILCDN_CONTROLLER_ADDRESS" ]; then
    FILCDN_CONTROLLER_ADDRESS="0xff0000000000000000000000000000000002870c"
fi
if [ -z "$FILCDN_BENEFICIARY_ADDRESS" ]; then
    FILCDN_BENEFICIARY_ADDRESS="0xff0000000000000000000000000000000002870c"
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

if [ -z "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
    # If existing session key registry not supplied, deploy another one
    source tools/deploy-session-key-registry.sh
fi

NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

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

# Step 3: Deploy Payments implementation
echo "Deploying Payments implementation..."
PAYMENTS_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/fws-payments/src/Payments.sol:Payments | grep "Deployed to" | awk '{print $3}')
if [ -z "$PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract Payments contract address"
    exit 1
fi
echo "Payments implementation deployed at: $PAYMENTS_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 4: Deploy Payments proxy
echo "Deploying Payments proxy..."
PAYMENTS_INIT_DATA=$(cast calldata "initialize()")
PAYMENTS_CONTRACT_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $PAYMENTS_IMPLEMENTATION_ADDRESS $PAYMENTS_INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
    echo "Error: Failed to extract Payments proxy address"
    exit 1
fi
echo "Payments proxy deployed at: $PAYMENTS_CONTRACT_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 5: Deploy ServiceProviderRegistry implementation
echo "Deploying ServiceProviderRegistry implementation..."
REGISTRY_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 src/ServiceProviderRegistry.sol:ServiceProviderRegistry | grep "Deployed to" | awk '{print $3}')
if [ -z "$REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract ServiceProviderRegistry implementation address"
    exit 1
fi
echo "ServiceProviderRegistry implementation deployed at: $REGISTRY_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 6: Deploy ServiceProviderRegistry proxy
echo "Deploying ServiceProviderRegistry proxy..."
REGISTRY_INIT_DATA=$(cast calldata "initialize()")
SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $REGISTRY_IMPLEMENTATION_ADDRESS $REGISTRY_INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
    echo "Error: Failed to extract ServiceProviderRegistry proxy address"
    exit 1
fi
echo "ServiceProviderRegistry proxy deployed at: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 7: Deploy FilecoinWarmStorageService implementation
echo "Deploying FilecoinWarmStorageService implementation..."

SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILCDN_CONTROLLER_ADDRESS $FILCDN_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS | grep "Deployed to" | awk '{print $3}')

if [ -z "$SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract FilecoinWarmStorageService contract address"
    exit 1
fi
echo "FilecoinWarmStorageService implementation deployed at: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 8: Deploy FilecoinWarmStorageService proxy
echo "Deploying FilecoinWarmStorageService proxy..."
# Initialize with PDPVerifier address, payments contract address, USDFC token address, commission rate, max proving period, and challenge window size
INIT_DATA=$(cast calldata "initialize(uint64,uint256)"  $MAX_PROVING_PERIOD $CHALLENGE_WINDOW_SIZE)
WARM_STORAGE_SERVICE_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS $INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$WARM_STORAGE_SERVICE_ADDRESS" ]; then
    echo "Error: Failed to extract FilecoinWarmStorageService proxy address"
    exit 1
fi
echo "FilecoinWarmStorageService proxy deployed at: $WARM_STORAGE_SERVICE_ADDRESS"

# Step 7: Deploy FilecoinWarmStorageServiceStateView
NONCE=$(expr $NONCE + "1")
source tools/deploy-warm-storage-view.sh

# Step 8: Set the view contract address on the main contract
echo "Setting view contract address on FilecoinWarmStorageService..."
NONCE=$(expr $NONCE + "1")
cast send --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --nonce $NONCE --chain-id $CHAIN_ID $WARM_STORAGE_SERVICE_ADDRESS "setViewContract(address)" $WARM_STORAGE_VIEW_ADDRESS
if [ $? -eq 0 ]; then
    echo "View contract address set successfully"
else
    echo "Error: Failed to set view contract address"
    exit 1
fi

# Summary of deployed contracts
echo
echo "# DEPLOYMENT SUMMARY"
echo "PDPVerifier Implementation: $VERIFIER_IMPLEMENTATION_ADDRESS"
echo "PDPVerifier Proxy: $PDP_VERIFIER_ADDRESS"
echo "Payments Implementation: $PAYMENTS_IMPLEMENTATION_ADDRESS"
echo "Payments Proxy: $PAYMENTS_CONTRACT_ADDRESS"
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
