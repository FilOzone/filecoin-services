#! /bin/bash
# upgrade-pandora-calibnet upgrades the FilecoinWarmStorage service contract and initializes new parameters
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the calibnet.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#
echo "Upgrading FilecoinWarmStorage Service Contract"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

if [ -z "$FILECOIN_WARM_STORAGE_SERVICE_PROXY_ADDRESS" ]; then
  echo "Error: FILECOIN_WARM_STORAGE_SERVICE_PROXY_ADDRESS is not set"
  exit 1
fi

# Proving period configuration - use defaults if not set
MAX_PROVING_PERIOD="${MAX_PROVING_PERIOD:-30}"                      # Default 30 epochs (15 minutes on calibnet)
CHALLENGE_WINDOW_SIZE="${CHALLENGE_WINDOW_SIZE:-15}"                # Default 15 epochs

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Upgrading contracts from address $ADDR"
 
NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

# Deploy new FilecoinWarmStorageService implementation
echo "Deploying new FilecoinWarmStorageService implementation..."
NEW_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')
if [ -z "$NEW_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract new FilecoinWarmStorageService implementation address"
    exit 1
fi
echo "New FilecoinWarmStorageService implementation deployed at: $NEW_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Upgrade the proxy to point to the new implementation
echo "Upgrading proxy to new implementation..."
cast send --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --nonce $NONCE --chain-id 314159 $FILECOIN_WARM_STORAGE_SERVICE_PROXY_ADDRESS "upgradeToAndCall(address,bytes)" $NEW_IMPLEMENTATION_ADDRESS $(cast calldata "initializeV2(uint64,uint256)" $MAX_PROVING_PERIOD $CHALLENGE_WINDOW_SIZE)
if [ $? -ne 0 ]; then
    echo "Error: Failed to upgrade proxy and initialize V2"
    exit 1
fi
echo "Proxy upgraded and V2 initialized successfully"

# Summary of upgrade
echo ""
echo "=== UPGRADE SUMMARY ==="
echo "Proxy Address: $FILECOIN_WARM_STORAGE_SERVICE_PROXY_ADDRESS"
echo "Old Implementation: (check previous deployment)"
echo "New Implementation: $NEW_IMPLEMENTATION_ADDRESS" 
echo "=========================="
echo ""
echo "Max proving period: $MAX_PROVING_PERIOD epochs"
echo "Challenge window size: $CHALLENGE_WINDOW_SIZE epochs"