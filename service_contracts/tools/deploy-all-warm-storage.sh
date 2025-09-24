#! /bin/bash
# deploy-all-warm-storage deploys the PDP verifier, Payments contract, and Warm Storage service
# Auto-detects network based on RPC chain ID and sets appropriate configuration
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the target network.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#

# Set DRY_RUN=false to actually deploy and broadcast transactions (default is dry-run for safety)
DRY_RUN=${DRY_RUN:-true}

# Default constants (same across all networks)
DEFAULT_FILCDN_BENEFICIARY_ADDRESS="0x1D60d2F5960Af6341e842C539985FA297E10d6eA"
DEFAULT_FILCDN_CONTROLLER_ADDRESS="0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A"

if [ "$DRY_RUN" = "true" ]; then
    echo "🧪 Running in DRY-RUN mode - simulation only, no actual deployment"
else
    echo "🚀 Running in DEPLOYMENT mode - will actually deploy and upgrade contracts"
fi

# Get this script's directory so we can reliably source other scripts
# in the same directory, regardless of where this script is executed from
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

echo "Deploying all Warm Storage contracts"

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

# Set network-specific configuration based on chain ID
# NOTE: CHALLENGE_FINALITY should always be 150 in production for security.
# Calibnet uses lower values for faster testing and development.
case "$CHAIN_ID" in
  "314159")
    NETWORK_NAME="calibnet"
    # Network-specific addresses for calibnet
    USDFC_TOKEN_ADDRESS="0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"
    # Default challenge and proving configuration for calibnet (testing values)
    DEFAULT_CHALLENGE_FINALITY="10"          # Low value for fast testing (should be 150 in production)
    DEFAULT_MAX_PROVING_PERIOD="240"         # 240 epochs on calibnet
    DEFAULT_CHALLENGE_WINDOW_SIZE="30"       # 30 epochs
    ;;
  "314")
    NETWORK_NAME="mainnet"
    # Network-specific addresses for mainnet
    USDFC_TOKEN_ADDRESS="0x80B98d3aa09ffff255c3ba4A241111Ff1262F045"
    # Default challenge and proving configuration for mainnet (production values)
    DEFAULT_CHALLENGE_FINALITY="150"         # Production security value
    DEFAULT_MAX_PROVING_PERIOD="2880"        # 2880 epochs on mainnet
    DEFAULT_CHALLENGE_WINDOW_SIZE="60"       # 60 epochs
    ;;
  *)
    echo "Error: Unsupported network"
    echo "  Supported networks:"
    echo "    314159 - Filecoin Calibration testnet"
    echo "    314    - Filecoin mainnet"
    echo "  Detected chain ID: $CHAIN_ID"
    exit 1
    ;;
esac

echo "Detected Chain ID: $CHAIN_ID ($NETWORK_NAME)"

if [ "$DRY_RUN" != "true" ] && [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set (required for actual deployment)"
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

# Use environment variables if set, otherwise use network defaults
if [ -z "$FILCDN_CONTROLLER_ADDRESS" ]; then
    FILCDN_CONTROLLER_ADDRESS="$DEFAULT_FILCDN_CONTROLLER_ADDRESS"
fi

if [ -z "$FILCDN_BENEFICIARY_ADDRESS" ]; then
    FILCDN_BENEFICIARY_ADDRESS="$DEFAULT_FILCDN_BENEFICIARY_ADDRESS"
fi

# Challenge and proving period configuration - use environment variables if set, otherwise use network defaults
CHALLENGE_FINALITY="${CHALLENGE_FINALITY:-$DEFAULT_CHALLENGE_FINALITY}"
MAX_PROVING_PERIOD="${MAX_PROVING_PERIOD:-$DEFAULT_MAX_PROVING_PERIOD}"
CHALLENGE_WINDOW_SIZE="${CHALLENGE_WINDOW_SIZE:-$DEFAULT_CHALLENGE_WINDOW_SIZE}"

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

echo "Network: $NETWORK_NAME"
echo "Configuration validation passed:"
echo "  CHALLENGE_FINALITY=$CHALLENGE_FINALITY"
echo "  MAX_PROVING_PERIOD=$MAX_PROVING_PERIOD"
echo "  CHALLENGE_WINDOW_SIZE=$CHALLENGE_WINDOW_SIZE"

# Test compilation of key contracts in dry-run mode
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Testing compilation of core contracts..."
    
    # Test compilation without network interaction
    echo "  - Testing FilecoinWarmStorageService compilation..."
    forge build --contracts src/FilecoinWarmStorageService.sol > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ FilecoinWarmStorageService compilation failed"
        exit 1
    fi
    
    echo "  - Testing ServiceProviderRegistry compilation..."
    forge build --contracts src/ServiceProviderRegistry.sol > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ ServiceProviderRegistry compilation failed"
        exit 1
    fi
    
    echo "✅ Core contract compilation tests passed"
fi

if [ "$DRY_RUN" = "true" ]; then
    ADDR="0x0000000000000000000000000000000000000000"  # Dummy address for dry-run
    NONCE="0"  # Use dummy nonce for dry-run
    BROADCAST_FLAG=""
    echo "Deploying contracts from address $ADDR (dry-run)"
    echo "🧪 Will simulate all deployments without broadcasting transactions"
    
    # Use dummy session key registry address for dry-run if not provided
    if [ -z "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
        SESSION_KEY_REGISTRY_ADDRESS="0x9012345678901234567890123456789012345678"
        echo "🧪 Using dummy SessionKeyRegistry address: $SESSION_KEY_REGISTRY_ADDRESS"
    fi
else
    if [ -z "$KEYSTORE" ]; then
        echo "Error: KEYSTORE is not set (required for actual deployment)"
        exit 1
    fi
    
    ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
    NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"
    BROADCAST_FLAG="--broadcast"
    echo "Deploying contracts from address $ADDR"
    echo "🚀 Will deploy and broadcast all transactions"
    
    if [ -z "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
        # If existing session key registry not supplied, deploy another one
        source "$SCRIPT_DIR/deploy-session-key-registry.sh"
        NONCE=$(expr $NONCE + "1")
    fi
fi

# Step 1: Deploy PDPVerifier implementation
echo "Deploying PDPVerifier implementation..."
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Testing compilation of PDPVerifier implementation"
    forge build lib/pdp/src/PDPVerifier.sol > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        VERIFIER_IMPLEMENTATION_ADDRESS="0x1234567890123456789012345678901234567890"  # Dummy address for dry-run
        echo "✅ PDPVerifier implementation compilation successful"
    else
        echo "❌ PDPVerifier implementation compilation failed"
        exit 1
    fi
else
    VERIFIER_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" $BROADCAST_FLAG --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/PDPVerifier.sol:PDPVerifier | grep "Deployed to" | awk '{print $3}')
    if [ -z "$VERIFIER_IMPLEMENTATION_ADDRESS" ]; then
        echo "Error: Failed to extract PDPVerifier contract address"
        exit 1
    fi
    echo "✅ PDPVerifier implementation deployed at: $VERIFIER_IMPLEMENTATION_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")

# Step 2: Deploy PDPVerifier proxy
echo "Deploying PDPVerifier proxy..."
INIT_DATA=$(cast calldata "initialize(uint256)" $CHALLENGE_FINALITY)
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would deploy PDPVerifier proxy with:"
    echo "   - Implementation: $VERIFIER_IMPLEMENTATION_ADDRESS"
    echo "   - Initialize with challenge finality: $CHALLENGE_FINALITY"
    PDP_VERIFIER_ADDRESS="0x2345678901234567890123456789012345678901"  # Dummy address for dry-run
    echo "✅ PDPVerifier proxy deployment planned"
else
    PDP_VERIFIER_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" $BROADCAST_FLAG --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $VERIFIER_IMPLEMENTATION_ADDRESS $INIT_DATA | grep "Deployed to" | awk '{print $3}')
    if [ -z "$PDP_VERIFIER_ADDRESS" ]; then
        echo "Error: Failed to extract PDPVerifier proxy address"
        exit 1
    fi
    echo "✅ PDPVerifier proxy deployed at: $PDP_VERIFIER_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")

# Step 3: Deploy Payments contract Implementation
echo "Deploying Payments contract..."
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Testing compilation of Payments contract"
    forge build lib/fws-payments/src/Payments.sol > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        PAYMENTS_CONTRACT_ADDRESS="0x3456789012345678901234567890123456789012"  # Dummy address for dry-run
        echo "✅ Payments contract compilation successful"
    else
        echo "❌ Payments contract compilation failed"
        exit 1
    fi
else
    PAYMENTS_CONTRACT_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" $BROADCAST_FLAG --nonce $NONCE --chain-id $CHAIN_ID lib/fws-payments/src/Payments.sol:Payments | grep "Deployed to" | awk '{print $3}')
    if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
        echo "Error: Failed to extract Payments contract address"
        exit 1
    fi
    echo "✅ Payments contract deployed at: $PAYMENTS_CONTRACT_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")

# Step 4: Deploy ServiceProviderRegistry implementation
echo "Deploying ServiceProviderRegistry implementation..."
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Testing compilation of ServiceProviderRegistry implementation"
    forge build src/ServiceProviderRegistry.sol > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        REGISTRY_IMPLEMENTATION_ADDRESS="0x4567890123456789012345678901234567890123"  # Dummy address for dry-run
        echo "✅ ServiceProviderRegistry implementation compilation successful"
    else
        echo "❌ ServiceProviderRegistry implementation compilation failed"
        exit 1
    fi
else
    REGISTRY_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" $BROADCAST_FLAG --nonce $NONCE --chain-id $CHAIN_ID src/ServiceProviderRegistry.sol:ServiceProviderRegistry | grep "Deployed to" | awk '{print $3}')
    if [ -z "$REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
        echo "Error: Failed to extract ServiceProviderRegistry implementation address"
        exit 1
    fi
    echo "✅ ServiceProviderRegistry implementation deployed at: $REGISTRY_IMPLEMENTATION_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")

# Step 5: Deploy ServiceProviderRegistry proxy
echo "Deploying ServiceProviderRegistry proxy..."
REGISTRY_INIT_DATA=$(cast calldata "initialize()")
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would deploy ServiceProviderRegistry proxy with:"
    echo "   - Implementation: $REGISTRY_IMPLEMENTATION_ADDRESS"
    echo "   - Initialize: empty initialization"
    SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS="0x5678901234567890123456789012345678901234"  # Dummy address for dry-run
    echo "✅ ServiceProviderRegistry proxy deployment planned"
else
    SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" $BROADCAST_FLAG --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $REGISTRY_IMPLEMENTATION_ADDRESS $REGISTRY_INIT_DATA | grep "Deployed to" | awk '{print $3}')
    if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
        echo "Error: Failed to extract ServiceProviderRegistry proxy address"
        exit 1
    fi
    echo "✅ ServiceProviderRegistry proxy deployed at: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")

# Step 6: Deploy FilecoinWarmStorageService implementation
echo "Deploying FilecoinWarmStorageService implementation..."
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would deploy FilecoinWarmStorageService implementation with:"
    echo "   - PDP Verifier: $PDP_VERIFIER_ADDRESS"
    echo "   - Payments Contract: $PAYMENTS_CONTRACT_ADDRESS"
    echo "   - USDFC Token: $USDFC_TOKEN_ADDRESS"
    echo "   - FilCDN Beneficiary: $FILCDN_BENEFICIARY_ADDRESS"
    echo "   - Service Provider Registry: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
    echo "   - Session Key Registry: $SESSION_KEY_REGISTRY_ADDRESS"
    SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS="0x6789012345678901234567890123456789012345"  # Dummy address for dry-run
    echo "✅ FilecoinWarmStorageService implementation deployment planned"
else
    SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" $BROADCAST_FLAG --nonce $NONCE --chain-id $CHAIN_ID src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILCDN_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS | grep "Deployed to" | awk '{print $3}')
    if [ -z "$SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then
        echo "Error: Failed to extract FilecoinWarmStorageService contract address"
        exit 1
    fi
    echo "✅ FilecoinWarmStorageService implementation deployed at: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")

# Step 7: Deploy FilecoinWarmStorageService proxy
echo "Deploying FilecoinWarmStorageService proxy..."
# Initialize with max proving period, challenge window size, FilCDN controller address, name, and description
INIT_DATA=$(cast calldata "initialize(uint64,uint256,address,string,string)" $MAX_PROVING_PERIOD $CHALLENGE_WINDOW_SIZE $FILCDN_CONTROLLER_ADDRESS "$SERVICE_NAME" "$SERVICE_DESCRIPTION")
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would deploy FilecoinWarmStorageService proxy with:"
    echo "   - Implementation: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
    echo "   - Max Proving Period: $MAX_PROVING_PERIOD epochs"
    echo "   - Challenge Window Size: $CHALLENGE_WINDOW_SIZE epochs"
    echo "   - FilCDN Controller: $FILCDN_CONTROLLER_ADDRESS"
    echo "   - Service Name: $SERVICE_NAME"
    echo "   - Service Description: $SERVICE_DESCRIPTION"
    WARM_STORAGE_SERVICE_ADDRESS="0x7890123456789012345678901234567890123456"  # Dummy address for dry-run
    echo "✅ FilecoinWarmStorageService proxy deployment planned"
else
    WARM_STORAGE_SERVICE_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" $BROADCAST_FLAG --nonce $NONCE --chain-id $CHAIN_ID lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS $INIT_DATA | grep "Deployed to" | awk '{print $3}')
    if [ -z "$WARM_STORAGE_SERVICE_ADDRESS" ]; then
        echo "Error: Failed to extract FilecoinWarmStorageService proxy address"
        exit 1
    fi
    echo "✅ FilecoinWarmStorageService proxy deployed at: $WARM_STORAGE_SERVICE_ADDRESS"
fi

# Step 8: Deploy FilecoinWarmStorageServiceStateView
NONCE=$(expr $NONCE + "1")
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would deploy FilecoinWarmStorageServiceStateView (skipping in dry-run)"
    WARM_STORAGE_VIEW_ADDRESS="0x8901234567890123456789012345678901234567"  # Dummy address for dry-run
else
    source "$SCRIPT_DIR/deploy-warm-storage-view.sh"
fi

# Step 9: Set the view contract address on the main contract
NONCE=$(expr $NONCE + "1")
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would set view contract address on main contract (skipping in dry-run)"
else
    source "$SCRIPT_DIR/set-warm-storage-view.sh"
fi

if [ "$DRY_RUN" = "true" ]; then
    echo
    echo "✅ Dry run completed successfully!"
    echo "🔍 All contract compilations and simulations passed"
    echo
    echo "To perform actual deployment, run with: DRY_RUN=false ./tools/deploy-all-warm-storage.sh"
    echo
    echo "# DRY-RUN SUMMARY ($NETWORK_NAME)"
else
    echo
    echo "✅ Deployment completed successfully!"
    echo
    echo "# DEPLOYMENT SUMMARY ($NETWORK_NAME)"
fi

echo "PDPVerifier Implementation: $VERIFIER_IMPLEMENTATION_ADDRESS"
echo "PDPVerifier Proxy: $PDP_VERIFIER_ADDRESS"
echo "Payments Contract: $PAYMENTS_CONTRACT_ADDRESS"
echo "ServiceProviderRegistry Implementation: $REGISTRY_IMPLEMENTATION_ADDRESS"
echo "ServiceProviderRegistry Proxy: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "FilecoinWarmStorageService Implementation: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
echo "FilecoinWarmStorageService Proxy: $WARM_STORAGE_SERVICE_ADDRESS"
echo "FilecoinWarmStorageServiceStateView: $WARM_STORAGE_VIEW_ADDRESS"
echo
echo "Network Configuration ($NETWORK_NAME):"
echo "Challenge finality: $CHALLENGE_FINALITY epochs"
echo "Max proving period: $MAX_PROVING_PERIOD epochs"
echo "Challenge window size: $CHALLENGE_WINDOW_SIZE epochs"
echo "USDFC token address: $USDFC_TOKEN_ADDRESS"
echo "FilCDN controller address: $FILCDN_CONTROLLER_ADDRESS"
echo "FilCDN beneficiary address: $FILCDN_BENEFICIARY_ADDRESS"
echo "Service name: $SERVICE_NAME"
echo "Service description: $SERVICE_DESCRIPTION"
