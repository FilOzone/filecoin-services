#! /bin/bash
# deploy-all-warm-storage deploys the PDP verifier, FilecoinPayV1 contract, and Warm Storage service
# Auto-detects network based on RPC chain ID and sets appropriate configuration
#
# Supported Networks:
#   - Chain ID 31415926: Filecoin devnet (15s blocktime, fast testing)
#   - Chain ID 314159:   Filecoin Calibration testnet
#   - Chain ID 314:      Filecoin mainnet
#
# Authentication: Support both keystore and private key authentication:
#   - Keystore: Set ETH_KEYSTORE, PASSWORD, ETH_RPC_URL env vars
#   - Private Key: Set PRIVATE_KEY, ETH_RPC_URL env vars (more convenient for CI/CD)
#
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#

# Set DRY_RUN=false to actually deploy and broadcast transactions (default is dry-run for safety)
DRY_RUN=${DRY_RUN:-true}

# Default constants (same across all networks)
DEFAULT_FILBEAM_BENEFICIARY_ADDRESS="0x1D60d2F5960Af6341e842C539985FA297E10d6eA"
DEFAULT_FILBEAM_CONTROLLER_ADDRESS="0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A"

if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "🧪 Running in DRY-RUN mode - no transactions will be sent to the network"
else
    :  # Remove deployment mode message for clean output
fi

# Get this script's directory so we can reliably source other scripts
# in the same directory, regardless of where this script is executed from
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

# Auto-detect chain ID from RPC
if [ -z "$CHAIN" ]; then
  # Choose authentication method for chain detection
  if [ -n "$PRIVATE_KEY" ]; then
    export CHAIN=$(cast chain-id --rpc-url "$ETH_RPC_URL" 2>/dev/null)
  else
    export CHAIN=$(cast chain-id 2>/dev/null)
  fi
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

# Set network-specific configuration based on chain ID
# NOTE: CHALLENGE_FINALITY should always be 150 in production for security.
# Calibnet and devnet use lower values for faster testing and development.
case "$CHAIN" in
  "31415926")
    NETWORK_NAME="devnet"
    # Network-specific addresses for devnet (using calibnet addresses as fallback)
    USDFC_TOKEN_ADDRESS="${USDFC_TOKEN_ADDRESS}"
    # Default challenge and proving configuration for devnet (fast testing values)
    # Devnet has ~15 second blocktimes, so epochs are much faster than mainnet
    DEFAULT_CHALLENGE_FINALITY="20"          # Reasonable security for testing (higher than calibnet)
    DEFAULT_MAX_PROVING_PERIOD="480"         # 480 epochs ≈ 2 hours at 15s/epoch for faster testing
    DEFAULT_CHALLENGE_WINDOW_SIZE="48"       # 48 epochs ≈ 12 minutes (10% of proving period)
    ;;
  "314159")
    NETWORK_NAME="calibnet"
    # Network-specific addresses for calibnet
    USDFC_TOKEN_ADDRESS="0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"
    # Default challenge and proving configuration for calibnet (testing values)
    DEFAULT_CHALLENGE_FINALITY="10"          # Low value for fast testing (should be 150 in production)
    DEFAULT_MAX_PROVING_PERIOD="240"         # 240 epochs on calibnet
    DEFAULT_CHALLENGE_WINDOW_SIZE="20"       # 20 epochs
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
    echo "    31415926 - Filecoin devnet (15s blocktime)"
    echo "    314159   - Filecoin Calibration testnet"
    echo "    314      - Filecoin mainnet"
    :  # Remove debug message for clean output
    exit 1
    ;;
esac

# Chain detected and network configuration set

# Authentication validation - support both keystore and private key methods
if [ "$DRY_RUN" != "true" ]; then
  if [ -n "$PRIVATE_KEY" ]; then
    :  # Remove authentication message for clean output
    # Validate private key format
    if [[ ! "$PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
      echo "Error: PRIVATE_KEY must be a 64-character hex string starting with 0x"
      exit 1
    fi
  elif [ -n "$ETH_KEYSTORE" ]; then
    :  # Remove authentication message for clean output
    if [ ! -f "$ETH_KEYSTORE" ]; then
      echo "Error: ETH_KEYSTORE file not found: $ETH_KEYSTORE"
      exit 1
    fi
  else
    echo "Error: Either PRIVATE_KEY or ETH_KEYSTORE must be set for actual deployment"
    echo "  For private key: set PRIVATE_KEY environment variable"
    echo "  For keystore: set ETH_KEYSTORE and PASSWORD environment variables"
    exit 1
  fi
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

# Use environment variables if set, otherwise use network defaults
if [ -z "$FILBEAM_CONTROLLER_ADDRESS" ]; then
    FILBEAM_CONTROLLER_ADDRESS="$DEFAULT_FILBEAM_CONTROLLER_ADDRESS"
fi

if [ -z "$FILBEAM_BENEFICIARY_ADDRESS" ]; then
    FILBEAM_BENEFICIARY_ADDRESS="$DEFAULT_FILBEAM_BENEFICIARY_ADDRESS"
fi

# Challenge and proving period configuration - use environment variables if set, otherwise use network defaults
CHALLENGE_FINALITY="${CHALLENGE_FINALITY:-$DEFAULT_CHALLENGE_FINALITY}"
MAX_PROVING_PERIOD="${MAX_PROVING_PERIOD:-$DEFAULT_MAX_PROVING_PERIOD}"
CHALLENGE_WINDOW_SIZE="${CHALLENGE_WINDOW_SIZE:-$DEFAULT_CHALLENGE_WINDOW_SIZE}"

# ========================================
# Deployment Helper Functions
# ========================================

# ANSI formatting codes
BOLD='\033[1m'
RESET='\033[0m'

# Deploy a contract implementation if address not already provided
# Args: $1=var_name, $2=contract_path:contract_name, $3=description, $4...=constructor_args
deploy_implementation_if_needed() {
    local var_name="$1"
    local contract="$2"
    local description="$3"
    shift 3
    local constructor_args=("$@")

    # Check if address already provided
    if [ -n "${!var_name}" ]; then
        echo -e "${BOLD}${description}${RESET}"
        echo "  ✅ Using existing address: ${!var_name}"
        echo
        return 0
    fi

    echo -e "${BOLD}Deploying ${description}${RESET}"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  🔍 Testing compilation..."
        forge build --contracts "$contract" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            # Generate a dummy address based on var name hash for consistency
            local dummy_addr="0x$(printf '%s' "$var_name" | sha256sum | cut -c1-40)"
            eval "$var_name='$dummy_addr'"
            echo "  ✅ Compilation successful (dummy: ${!var_name})"
        else
            echo "  ❌ Compilation failed"
            exit 1
        fi
    else
        # Add libraries if LIBRARIES variable is set
        if [ -n "$LIBRARIES" ]; then
            echo "  📚 Using libraries: $LIBRARIES"
        fi

        # Add constructor args display if provided
        if [ ${#constructor_args[@]} -gt 0 ]; then
            echo "  🔧 Constructor args: ${#constructor_args[@]} arguments"
        fi

        # Build the forge create command
        local forge_cmd=(forge create --password "$PASSWORD" $BROADCAST_FLAG --nonce "$NONCE")

        if [ -n "$LIBRARIES" ]; then
            forge_cmd+=(--libraries "$LIBRARIES")
        fi

        forge_cmd+=("$contract")

        if [ ${#constructor_args[@]} -gt 0 ]; then
            forge_cmd+=(--constructor-args "${constructor_args[@]}")
        fi

        local address=$("${forge_cmd[@]}" | grep "Deployed to" | awk '{print $3}')

        if [ -z "$address" ]; then
            echo "  ❌ Failed to extract address"
            exit 1
        fi

        eval "$var_name='$address'"
        echo "  ✅ Deployed at: ${!var_name}"
    fi

    NONCE=$(expr $NONCE + "1")
    echo
}

# Deploy a proxy contract if address not already provided
# Args: $1=var_name, $2=implementation_address, $3=init_data, $4=description
deploy_proxy_if_needed() {
    local var_name="$1"
    local implementation="$2"
    local init_data="$3"
    local description="$4"

    # Check if address already provided
    if [ -n "${!var_name}" ]; then
        echo -e "${BOLD}${description}${RESET}"
        echo "  ✅ Using existing address: ${!var_name}"
        echo
        return 0
    fi

    echo -e "${BOLD}Deploying ${description}${RESET}"

    if [ "$DRY_RUN" = "true" ]; then
        echo "  🔍 Testing proxy deployment..."
        echo "  📦 Implementation: $implementation"
        local dummy_addr="0x$(printf '%s' "$var_name" | sha256sum | cut -c1-40)"
        eval "$var_name='$dummy_addr'"
        echo "  ✅ Deployment planned (dummy: ${!var_name})"
    else
        echo "  📦 Implementation: $implementation"
        local address=$(forge create --password "$PASSWORD" $BROADCAST_FLAG --nonce $NONCE \
            lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy \
            --constructor-args "$implementation" "$init_data" | grep "Deployed to" | awk '{print $3}')

        if [ -z "$address" ]; then
            echo "  ❌ Failed to extract address"
            exit 1
        fi

        eval "$var_name='$address'"
        echo "  ✅ Deployed at: ${!var_name}"
    fi

    NONCE=$(expr $NONCE + "1")
    echo
}

# Deploy session key registry if needed (uses ./deploy-session-key-registry.sh)
deploy_session_key_registry_if_needed() {
    if [ -n "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
        echo -e "${BOLD}SessionKeyRegistry${RESET}"
        echo "  ✅ Using existing address: $SESSION_KEY_REGISTRY_ADDRESS"
        echo
        return 0
    fi

    echo -e "${BOLD}Deploying SessionKeyRegistry${RESET}"

    if [ "$DRY_RUN" = "true" ]; then
        SESSION_KEY_REGISTRY_ADDRESS="0x9012345678901234567890123456789012345678"
        echo "  🧪 Using dummy address: $SESSION_KEY_REGISTRY_ADDRESS"
    else
        echo "  🔧 Using external deployment script..."
        source "$SCRIPT_DIR/deploy-session-key-registry.sh"
        NONCE=$(expr $NONCE + "1")
        echo "  ✅ Deployed at: $SESSION_KEY_REGISTRY_ADDRESS"
    fi
    echo
}

# ========================================
# Validation
# ========================================

# Validate that the configuration will work with PDPVerifier's challengeFinality
# The calculation: (MAX_PROVING_PERIOD - CHALLENGE_WINDOW_SIZE) + (CHALLENGE_WINDOW_SIZE/2) must be >= CHALLENGE_FINALITY
# This ensures initChallengeWindowStart() + buffer will meet PDPVerifier requirements
MIN_REQUIRED=$((CHALLENGE_FINALITY + CHALLENGE_WINDOW_SIZE / 2))
if [ "$MAX_PROVING_PERIOD" -lt "$MIN_REQUIRED" ]; then
    echo "Error: MAX_PROVING_PERIOD ($MAX_PROVING_PERIOD) is too small for CHALLENGE_FINALITY ($CHALLENGE_FINALITY)"
    echo "       MAX_PROVING_PERIOD must be at least $MIN_REQUIRED (CHALLENGE_FINALITY + CHALLENGE_WINDOW_SIZE/2)"
    echo "       Either increase MAX_PROVING_PERIOD or decrease CHALLENGE_FINALITY"
    echo "       See service_contracts/tools/README.md for deployment parameter guidelines."
    exit 1
fi

# Suppress forge warnings by redirecting stderr
export FOUNDRY_PROFILE=default

# Helper function to run forge create with appropriate authentication (suppress warnings)
forge_create() {
    local contract_path="$1"
    shift
    local extra_args="$@"
    
    if [ "$DRY_RUN" = "true" ]; then
        return 0  # Skip actual deployment in dry-run
    fi
    
    # Suppress all forge warnings by redirecting stderr
    if [ -n "$PRIVATE_KEY" ]; then
        eval "forge create --private-key \"$PRIVATE_KEY\" --rpc-url \"$ETH_RPC_URL\" --broadcast $extra_args \"$contract_path\" 2>/dev/null"
    else
        eval "forge create --password \"$PASSWORD\" --broadcast $extra_args \"$contract_path\" 2>/dev/null"
    fi
}

# Test compilation of key contracts in dry-run mode
if [ "$DRY_RUN" = "true" ]; then
    echo "Testing contract compilation..."
    forge build > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ Contract compilation failed"
        exit 1
    fi
    echo "✅ Contract compilation successful"
fi

# ========================================
# Initialize Deployment Environment
# ========================================

if [ "$DRY_RUN" = "true" ]; then
    ADDR="0x0000000000000000000000000000000000000000"  # Dummy address for dry-run
    NONCE="0"  # Use dummy nonce for dry-run
    BROADCAST_FLAG=""
    echo "Deploying contracts from address $ADDR (dry-run)"
    echo "🧪 Will simulate all deployments without broadcasting transactions"
else
    # Get deployer address based on authentication method
    if [ -n "$PRIVATE_KEY" ]; then
        ADDR=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)
        NONCE="$(cast nonce "$ADDR" --rpc-url "$ETH_RPC_URL" 2>/dev/null)"
    else
        ADDR=$(cast wallet address --password "$PASSWORD" 2>/dev/null)
        NONCE="$(cast nonce "$ADDR" 2>/dev/null)"
    fi
    
    BROADCAST_FLAG="--broadcast"
    
    if [ -z "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
        # Deploy SessionKeyRegistry inline to support both auth methods
        if [ -n "$PRIVATE_KEY" ]; then
            SESSION_KEY_REGISTRY_ADDRESS=$(forge create --private-key "$PRIVATE_KEY" --rpc-url "$ETH_RPC_URL" --broadcast --nonce $NONCE lib/session-key-registry/src/SessionKeyRegistry.sol:SessionKeyRegistry 2>/dev/null | grep "Deployed to" | awk '{print $3}')
        else
            SESSION_KEY_REGISTRY_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE lib/session-key-registry/src/SessionKeyRegistry.sol:SessionKeyRegistry 2>/dev/null | grep "Deployed to" | awk '{print $3}')
        fi
        
        if [ -z "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
            echo "Error: Failed to extract SessionKeyRegistry address"
            exit 1
        fi
        echo "SessionKeyRegistry: $SESSION_KEY_REGISTRY_ADDRESS"
        NONCE=$(expr $NONCE + "1")
    fi
fi

# Step 1: Deploy PDPVerifier implementation
if [ "$DRY_RUN" = "true" ]; then
    VERIFIER_IMPLEMENTATION_ADDRESS="0x1234567890123456789012345678901234567890"  # Dummy address for dry-run
else
    VERIFIER_IMPLEMENTATION_ADDRESS=$(forge_create lib/pdp/src/PDPVerifier.sol:PDPVerifier --nonce $NONCE | grep "Deployed to" | awk '{print $3}')
    if [ -z "$VERIFIER_IMPLEMENTATION_ADDRESS" ]; then
        echo "Error: Failed to extract PDPVerifier contract address"
        exit 1
    fi
fi
echo "PDPVerifierImplementation: $VERIFIER_IMPLEMENTATION_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 2: Deploy PDPVerifier proxy
INIT_DATA=$(cast calldata "initialize(uint256)" $CHALLENGE_FINALITY 2>/dev/null)
if [ "$DRY_RUN" = "true" ]; then
    PDP_VERIFIER_ADDRESS="0x2345678901234567890123456789012345678901"  # Dummy address for dry-run
else
    if [ -n "$PRIVATE_KEY" ]; then
        PDP_VERIFIER_ADDRESS=$(forge create --private-key "$PRIVATE_KEY" --rpc-url "$ETH_RPC_URL" --broadcast --nonce $NONCE lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args "$VERIFIER_IMPLEMENTATION_ADDRESS" "$INIT_DATA" 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    else
        PDP_VERIFIER_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args "$VERIFIER_IMPLEMENTATION_ADDRESS" "$INIT_DATA" 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    fi
    if [ -z "$PDP_VERIFIER_ADDRESS" ]; then
        echo "Error: Failed to extract PDPVerifier proxy address"
        exit 1
    fi
fi
echo "PDPVerifier: $PDP_VERIFIER_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 3: Deploy Payments contract Implementation
if [ "$DRY_RUN" = "true" ]; then
    PAYMENTS_CONTRACT_ADDRESS="0x3456789012345678901234567890123456789012"  # Dummy address for dry-run
else
    PAYMENTS_CONTRACT_ADDRESS=$(forge_create lib/fws-payments/src/Payments.sol:Payments --nonce $NONCE | grep "Deployed to" | awk '{print $3}')
    if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
        echo "Error: Failed to extract Payments contract address"
        exit 1
    fi
fi
echo "Payments: $PAYMENTS_CONTRACT_ADDRESS"
NONCE=$(expr $NONCE + "1")

# Step 4: Deploy ServiceProviderRegistry implementation
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
    REGISTRY_IMPLEMENTATION_ADDRESS=$(forge_create src/ServiceProviderRegistry.sol:ServiceProviderRegistry --nonce $NONCE | grep "Deployed to" | awk '{print $3}')
    if [ -z "$REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
        echo "Error: Failed to extract ServiceProviderRegistry implementation address"
        exit 1
    fi
    echo "ServiceProviderRegistryImplementation: $REGISTRY_IMPLEMENTATION_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")

# Step 5: Deploy ServiceProviderRegistry proxy
INIT_DATA=$(cast calldata "initialize()" 2>/dev/null)
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would deploy ServiceProviderRegistry proxy with:"
    echo "   - Implementation: $REGISTRY_IMPLEMENTATION_ADDRESS"
    echo "   - Initialize: empty initialization"
    SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS="0x5678901234567890123456789012345678901234"  # Dummy address for dry-run
    echo "✅ ServiceProviderRegistry proxy deployment planned"
else
    if [ -n "$PRIVATE_KEY" ]; then
        SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS=$(forge create --private-key "$PRIVATE_KEY" --rpc-url "$ETH_RPC_URL" --broadcast --nonce $NONCE lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --constructor-args "$REGISTRY_IMPLEMENTATION_ADDRESS" "$INIT_DATA" 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    else
        SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args "$REGISTRY_IMPLEMENTATION_ADDRESS" "$REGISTRY_INIT_DATA" 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    fi
    if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
        echo "Error: Failed to extract ServiceProviderRegistry proxy address"
        exit 1
    fi
    echo "ServiceProviderRegistry: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")

# Step 6: Deploy FilecoinWarmStorageService implementation
# First, deploy SignatureVerificationLib library dependency
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Testing compilation of SignatureVerificationLib"
    forge build src/lib/SignatureVerificationLib.sol > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        SIGNATURE_VERIFICATION_LIB_ADDRESS="0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"  # Dummy address for dry-run
        echo "✅ SignatureVerificationLib compilation successful"
    else
        echo "❌ SignatureVerificationLib compilation failed"
        exit 1
    fi
else
    SIGNATURE_VERIFICATION_LIB_ADDRESS=$(forge_create src/lib/SignatureVerificationLib.sol:SignatureVerificationLib --nonce $NONCE | grep "Deployed to" | awk '{print $3}')
    if [ -z "$SIGNATURE_VERIFICATION_LIB_ADDRESS" ]; then
        echo "Error: Failed to extract SignatureVerificationLib address"
        exit 1
    fi
    echo "SignatureVerificationLib: $SIGNATURE_VERIFICATION_LIB_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would deploy FilecoinWarmStorageService implementation with:"
    echo "   - PDP Verifier: $PDP_VERIFIER_ADDRESS"
    echo "   - Payments Contract: $PAYMENTS_CONTRACT_ADDRESS"
    echo "   - USDFC Token: $USDFC_TOKEN_ADDRESS"
    echo "   - FilBeam Beneficiary: $FILBEAM_BENEFICIARY_ADDRESS"
    echo "   - Service Provider Registry: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
    echo "   - Session Key Registry: $SESSION_KEY_REGISTRY_ADDRESS"
    FWS_IMPLEMENTATION_ADDRESS="0x6789012345678901234567890123456789012345"  # Dummy address for dry-run
    echo "✅ FilecoinWarmStorageService implementation deployment planned"
else
    if [ -n "$PRIVATE_KEY" ]; then
        FWS_IMPLEMENTATION_ADDRESS=$(forge create --private-key "$PRIVATE_KEY" --rpc-url "$ETH_RPC_URL" --broadcast --nonce $NONCE \
            --libraries "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS" \
            src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService \
            --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILBEAM_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    else
        FWS_IMPLEMENTATION_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE \
            --libraries "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS" \
            src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService \
            --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILBEAM_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    fi
    if [ -z "$FWS_IMPLEMENTATION_ADDRESS" ]; then
        echo "Error: Failed to extract FilecoinWarmStorageService contract address"
        exit 1
    fi
    echo "FilecoinWarmStorageServiceImplementation: $FWS_IMPLEMENTATION_ADDRESS"
fi
NONCE=$(expr $NONCE + "1")

# Step 7: Deploy FilecoinWarmStorageService proxy
# Initialize with max proving period, challenge window size, FilBeam controller address, name, and description
INIT_DATA=$(cast calldata "initialize(uint64,uint256,address,string,string)" $MAX_PROVING_PERIOD $CHALLENGE_WINDOW_SIZE $FILBEAM_CONTROLLER_ADDRESS "$SERVICE_NAME" "$SERVICE_DESCRIPTION" 2>/dev/null)
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would deploy FilecoinWarmStorageService proxy with:"
    echo "   - Implementation: $FWS_IMPLEMENTATION_ADDRESS"
    echo "   - Max Proving Period: $MAX_PROVING_PERIOD epochs"
    echo "   - Challenge Window Size: $CHALLENGE_WINDOW_SIZE epochs"
    echo "   - FilBeam Controller: $FILBEAM_CONTROLLER_ADDRESS"
    echo "   - Service Name: $SERVICE_NAME"
    echo "   - Service Description: $SERVICE_DESCRIPTION"
    WARM_STORAGE_SERVICE_ADDRESS="0x7890123456789012345678901234567890123456"  # Dummy address for dry-run
    echo "✅ FilecoinWarmStorageService proxy deployment planned"
else
    if [ -n "$PRIVATE_KEY" ]; then
        WARM_STORAGE_SERVICE_ADDRESS=$(forge create --private-key "$PRIVATE_KEY" --rpc-url "$ETH_RPC_URL" --broadcast --nonce $NONCE lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args "$FWS_IMPLEMENTATION_ADDRESS" "$INIT_DATA" 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    else
        WARM_STORAGE_SERVICE_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy --constructor-args "$FWS_IMPLEMENTATION_ADDRESS" "$INIT_DATA" 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    fi
    if [ -z "$WARM_STORAGE_SERVICE_ADDRESS" ]; then
        echo "Error: Failed to extract FilecoinWarmStorageService proxy address"
        exit 1
    fi
    echo "FilecoinWarmStorageService: $WARM_STORAGE_SERVICE_ADDRESS"
fi

# Step 8: Deploy FilecoinWarmStorageServiceStateView
NONCE=$(expr $NONCE + "1")
if [ "$DRY_RUN" = "true" ]; then
    echo "🔍 Would deploy FilecoinWarmStorageServiceStateView (skipping in dry-run)"
    WARM_STORAGE_VIEW_ADDRESS="0x8901234567890123456789012345678901234567"  # Dummy address for dry-run
    echo "  ✅ Deployment planned (dummy: $WARM_STORAGE_VIEW_ADDRESS)"
else
    # Deploy view contract using same authentication method
    if [ -n "$PRIVATE_KEY" ]; then
        WARM_STORAGE_VIEW_ADDRESS=$(forge create --private-key "$PRIVATE_KEY" --rpc-url "$ETH_RPC_URL" --broadcast --nonce $NONCE src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView --constructor-args $WARM_STORAGE_SERVICE_ADDRESS 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    else
        WARM_STORAGE_VIEW_ADDRESS=$(forge create --password "$PASSWORD" --broadcast --nonce $NONCE src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView --constructor-args $WARM_STORAGE_SERVICE_ADDRESS 2>/dev/null | grep "Deployed to" | awk '{print $3}')
    fi
    if [ -z "$WARM_STORAGE_VIEW_ADDRESS" ]; then
        echo "Error: Failed to extract FilecoinWarmStorageServiceStateView address"
        exit 1
    fi
    echo "FilecoinWarmStorageServiceStateView: $WARM_STORAGE_VIEW_ADDRESS"
fi
echo

# Step 10: Set the view contract address on the main contract
echo -e "${BOLD}Setting view contract address${RESET}"
NONCE=$(expr $NONCE + "1")
if [ "$DRY_RUN" = "true" ]; then
    echo "  🔍 Would set view contract address on main contract (skipping in dry-run)"
else
    # Set view contract address using same authentication method
    if [ -n "$PRIVATE_KEY" ]; then
        cast send --private-key "$PRIVATE_KEY" --rpc-url "$ETH_RPC_URL" --nonce $NONCE $WARM_STORAGE_SERVICE_ADDRESS "setStateView(address)" $WARM_STORAGE_VIEW_ADDRESS 2>/dev/null > /dev/null
    else
        cast send --password "$PASSWORD" --nonce $NONCE $WARM_STORAGE_SERVICE_ADDRESS "setStateView(address)" $WARM_STORAGE_VIEW_ADDRESS 2>/dev/null > /dev/null
    fi
fi
