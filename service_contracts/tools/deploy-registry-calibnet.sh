#!/bin/bash
# deploy-registry-calibnet deploys the Service Provider Registry contract to calibration net
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the calibnet.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#
echo "Deploying Service Provider Registry Contract"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

# Optional: Check if PASSWORD is set (some users might use empty password)
if [ -z "$PASSWORD" ]; then
  echo "Warning: PASSWORD is not set, using empty password"
fi

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying contracts from address $ADDR"

# Get current balance
BALANCE=$(cast balance --rpc-url "$RPC_URL" "$ADDR")
echo "Deployer balance: $BALANCE"

NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"
echo "Starting nonce: $NONCE"

# Deploy ServiceProviderRegistry implementation
echo ""
echo "=== STEP 1: Deploying ServiceProviderRegistry Implementation ==="
REGISTRY_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 src/ServiceProviderRegistry.sol:ServiceProviderRegistry --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')
if [ -z "$REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract ServiceProviderRegistry implementation address"
    exit 1
fi
echo "✓ ServiceProviderRegistry implementation deployed at: $REGISTRY_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Deploy ServiceProviderRegistry proxy
echo ""
echo "=== STEP 2: Deploying ServiceProviderRegistry Proxy ==="
# Initialize with no parameters for basic initialization
INIT_DATA=$(cast calldata "initialize()")
echo "Initialization calldata: $INIT_DATA"

REGISTRY_PROXY_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $REGISTRY_IMPLEMENTATION_ADDRESS $INIT_DATA --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')
if [ -z "$REGISTRY_PROXY_ADDRESS" ]; then
    echo "Error: Failed to extract ServiceProviderRegistry proxy address"
    exit 1
fi
echo "✓ ServiceProviderRegistry proxy deployed at: $REGISTRY_PROXY_ADDRESS"

# Verify deployment by calling version() on the proxy
echo ""
echo "=== STEP 3: Verifying Deployment ==="
VERSION=$(cast call --rpc-url "$RPC_URL" $REGISTRY_PROXY_ADDRESS "version()(string)")
if [ -z "$VERSION" ]; then
    echo "Warning: Could not verify contract version"
else
    echo "✓ Contract version: $VERSION"
fi

# Get registration fee
FEE=$(cast call --rpc-url "$RPC_URL" $REGISTRY_PROXY_ADDRESS "getRegistrationFee()(uint256)")
if [ -z "$FEE" ]; then
    echo "Warning: Could not retrieve registration fee"
else
    # Convert from wei to FIL (assuming 1 FIL = 10^18 attoFIL)
    FEE_IN_FIL=$(echo "scale=2; $FEE / 1000000000000000000" | bc 2>/dev/null || echo "1")
    echo "✓ Registration fee: $FEE attoFIL ($FEE_IN_FIL FIL)"
fi

# Get burn actor address
BURN_ACTOR=$(cast call --rpc-url "$RPC_URL" $REGISTRY_PROXY_ADDRESS "BURN_ACTOR()(address)")
if [ -z "$BURN_ACTOR" ]; then
    echo "Warning: Could not retrieve burn actor address"
else
    echo "✓ Burn actor address: $BURN_ACTOR"
fi

# Summary of deployed contracts
echo ""
echo "=========================================="
echo "=== DEPLOYMENT SUMMARY ==="
echo "=========================================="
echo "ServiceProviderRegistry Implementation: $REGISTRY_IMPLEMENTATION_ADDRESS" 
echo "ServiceProviderRegistry Proxy: $REGISTRY_PROXY_ADDRESS"
echo "=========================================="
echo ""
echo "Contract Details:"
echo "  - Version: 1.0.0"
echo "  - Registration Fee: 1 FIL (burned)"
echo "  - Burn Actor: 0xff00000000000000000000000000000000000063"
echo "  - Chain: Calibration testnet (314159)"
echo ""
echo "Next steps:"
echo "1. Save the proxy address: export REGISTRY_ADDRESS=$REGISTRY_PROXY_ADDRESS"
echo "2. Verify the deployment by calling getProviderCount() - should return 0"
echo "3. Test registration with: cast send --value 1ether ..."
echo "4. Transfer ownership if needed using transferOwnership()"
echo "5. The registry is ready for provider registrations"
echo ""
echo "To interact with the registry:"
echo "  View functions:"
echo "    cast call $REGISTRY_PROXY_ADDRESS \"getProviderCount()(uint256)\""
echo "    cast call $REGISTRY_PROXY_ADDRESS \"getAllActiveProviders()(uint256[])\""
echo "  State changes (requires 1 FIL fee):"
echo "    Register as provider (requires proper encoding of PDPData)"
echo ""

# Automatic contract verification
if [ "${AUTO_VERIFY:-true}" = "true" ]; then
    echo
    echo "🔍 Starting automatic contract verification..."
    
    # Install filfox-verifier if needed
    if [ ! -d "node_modules" ]; then
        npm install
    fi
    
    # Detect chain ID for verification
    FILECOIN_NETWORK=${FILECOIN_NETWORK:-calibnet}
    if [ "$FILECOIN_NETWORK" = "mainnet" ]; then
        VERIFY_CHAIN_ID=314
    else
        VERIFY_CHAIN_ID=314159
    fi
    
    # Verify implementation contract
    npx filfox-verifier forge "$REGISTRY_IMPLEMENTATION_ADDRESS" "src/ServiceProviderRegistry.sol:ServiceProviderRegistry" --chain "$VERIFY_CHAIN_ID"
    
    # Verify proxy contract
    echo "🔍 Verifying ServiceProviderRegistry proxy..."
    npx filfox-verifier forge "$REGISTRY_PROXY_ADDRESS" "lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy" --chain "$VERIFY_CHAIN_ID"
else
    echo
    echo "⏭️  Skipping automatic verification (set AUTO_VERIFY=true to enable)"
fi
echo "=========================================="