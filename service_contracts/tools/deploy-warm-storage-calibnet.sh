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

# Fixed constants for initialization
USDFC_TOKEN_ADDRESS="0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"    # USDFC token address
OPERATOR_COMMISSION_BPS="100"                                         # 1% commission in basis points

# Proving period configuration - use defaults if not set
MAX_PROVING_PERIOD="${MAX_PROVING_PERIOD:-30}"                      # Default 30 epochs (15 minutes on calibnet)
CHALLENGE_WINDOW_SIZE="${CHALLENGE_WINDOW_SIZE:-15}"                # Default 15 epochs

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying contracts from address $ADDR"
 
NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

# Deploy FilecoinWarmStorageService implementation
echo "Deploying FilecoinWarmStorageService implementation..."
SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')
if [ -z "$SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract FilecoinWarmStorageService contract address"
    exit 1
fi
echo "FilecoinWarmStorageService implementation deployed at: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Deploy FilecoinWarmStorageService proxy
echo "Deploying FilecoinWarmStorageService proxy..."
# Initialize with PDPVerifier address, payments contract address, USDFC token address, commission rate, max proving period, and challenge window size
INIT_DATA=$(cast calldata "initialize(address,address,address,uint256,uint64,uint256)" $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $OPERATOR_COMMISSION_BPS $MAX_PROVING_PERIOD $CHALLENGE_WINDOW_SIZE)
WARM_STORAGE_SERVICE_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS $INIT_DATA --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')
if [ -z "$WARM_STORAGE_SERVICE_ADDRESS" ]; then
    echo "Error: Failed to extract FilecoinWarmStorageService proxy address"
    exit 1
fi
echo "FilecoinWarmStorageService proxy deployed at: $WARM_STORAGE_SERVICE_ADDRESS"

# Summary of deployed contracts
echo ""
echo "=== DEPLOYMENT SUMMARY ==="
echo "FilecoinWarmStorageService Implementation: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS" 
echo "FilecoinWarmStorageService Proxy: $WARM_STORAGE_SERVICE_ADDRESS"
echo "=========================="
echo ""
echo "USDFC token address: $USDFC_TOKEN_ADDRESS"
echo "PDPVerifier address: $PDP_VERIFIER_ADDRESS"
echo "Payments contract address: $PAYMENTS_CONTRACT_ADDRESS"
echo "Operator commission rate: $OPERATOR_COMMISSION_BPS basis points (${OPERATOR_COMMISSION_BPS})"
echo "Max proving period: $MAX_PROVING_PERIOD epochs"
echo "Challenge window size: $CHALLENGE_WINDOW_SIZE epochs"
