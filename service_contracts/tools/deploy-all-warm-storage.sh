#! /bin/bash
# deploy-all-warm-storage deploys the PDP verifier, FilecoinPayV1 contract, and Warm Storage service
# Auto-detects network based on RPC chain ID and sets appropriate configuration
# Assumption: KEYSTORE, PASSWORD, ETH_RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid ETH_RPC_URL for the target network.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#

# Set DRY_RUN=false to actually deploy and broadcast transactions (default is dry-run for safety)
DRY_RUN=${DRY_RUN:-true}

# Default constants (same across all networks)
DEFAULT_FILBEAM_BENEFICIARY_ADDRESS="0x1D60d2F5960Af6341e842C539985FA297E10d6eA"
DEFAULT_FILBEAM_CONTROLLER_ADDRESS="0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A"

if [ "$DRY_RUN" = "true" ]; then
    echo "🧪 Running in DRY-RUN mode - simulation only, no actual deployment"
else
    echo "🚀 Running in DEPLOYMENT mode - will actually deploy and upgrade contracts"
fi

# Get this script's directory so we can reliably source other scripts
# in the same directory, regardless of where this script is executed from
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

echo "Deploying all Warm Storage contracts"

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

# Set network-specific configuration based on chain ID
# NOTE: CHALLENGE_FINALITY should always be 150 in production for security.
# Calibnet uses lower values for faster testing and development.
case "$CHAIN" in
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
    echo "  Detected chain ID: $CHAIN"
    exit 1
    ;;
esac

echo "Detected Chain ID: $CHAIN ($NETWORK_NAME)"

if [ "$DRY_RUN" != "true" ] && [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set (required for actual deployment)"
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
    if [ -z "$ETH_KEYSTORE" ]; then
        echo "Error: ETH_KEYSTORE is not set (required for actual deployment)"
        exit 1
    fi

    ADDR=$(cast wallet address  --password "$PASSWORD")
    NONCE="$(cast nonce "$ADDR")"
    BROADCAST_FLAG="--broadcast"
    echo "Deploying contracts from address $ADDR"
    echo "🚀 Will deploy and broadcast all transactions"
fi

echo
echo "========================================"
echo "DEPLOYING..."
echo "========================================"
echo

# Step 0: Deploy or use existing SessionKeyRegistry
deploy_session_key_registry_if_needed

# Step 1: Deploy or use existing PDPVerifier implementation
deploy_implementation_if_needed \
    "VERIFIER_IMPLEMENTATION_ADDRESS" \
    "lib/pdp/src/PDPVerifier.sol:PDPVerifier" \
    "PDPVerifier implementation"

# Step 2: Deploy or use existing PDPVerifier proxy
INIT_DATA=$(cast calldata "initialize(uint256)" $CHALLENGE_FINALITY)
deploy_proxy_if_needed \
    "PDP_VERIFIER_ADDRESS" \
    "$VERIFIER_IMPLEMENTATION_ADDRESS" \
    "$INIT_DATA" \
    "PDPVerifier proxy"

# Step 3: Deploy or use existing FilecoinPayV1 contract
deploy_implementation_if_needed \
    "PAYMENTS_CONTRACT_ADDRESS" \
    "lib/fws-payments/src/FilecoinPayV1.sol:FilecoinPayV1" \
    "FilecoinPayV1"

# Step 4: Deploy or use existing ServiceProviderRegistry implementation
deploy_implementation_if_needed \
    "REGISTRY_IMPLEMENTATION_ADDRESS" \
    "src/ServiceProviderRegistry.sol:ServiceProviderRegistry" \
    "ServiceProviderRegistry implementation"

# Step 5: Deploy or use existing ServiceProviderRegistry proxy
REGISTRY_INIT_DATA=$(cast calldata "initialize()")
deploy_proxy_if_needed \
    "SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    "$REGISTRY_IMPLEMENTATION_ADDRESS" \
    "$REGISTRY_INIT_DATA" \
    "ServiceProviderRegistry proxy"

# Step 6: Deploy or use existing SignatureVerificationLib
deploy_implementation_if_needed \
    "SIGNATURE_VERIFICATION_LIB_ADDRESS" \
    "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib" \
    "SignatureVerificationLib"

# Step 7: Deploy or use existing FilecoinWarmStorageService implementation
# Set LIBRARIES variable for the deployment helper (format: path:name:address)
LIBRARIES="src/lib/SignatureVerificationLib.sol:SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS"
deploy_implementation_if_needed \
    "FWS_IMPLEMENTATION_ADDRESS" \
    "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService" \
    "FilecoinWarmStorageService implementation" \
    "$PDP_VERIFIER_ADDRESS" \
    "$PAYMENTS_CONTRACT_ADDRESS" \
    "$USDFC_TOKEN_ADDRESS" \
    "$FILBEAM_BENEFICIARY_ADDRESS" \
    "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    "$SESSION_KEY_REGISTRY_ADDRESS"
unset LIBRARIES

# Step 8: Deploy or use existing FilecoinWarmStorageService proxy
# Initialize with max proving period, challenge window size, FilBeam controller address, name, and description
INIT_DATA=$(cast calldata "initialize(uint64,uint256,address,string,string)" $MAX_PROVING_PERIOD $CHALLENGE_WINDOW_SIZE $FILBEAM_CONTROLLER_ADDRESS "$SERVICE_NAME" "$SERVICE_DESCRIPTION")
deploy_proxy_if_needed \
    "WARM_STORAGE_SERVICE_ADDRESS" \
    "$FWS_IMPLEMENTATION_ADDRESS" \
    "$INIT_DATA" \
    "FilecoinWarmStorageService proxy"

# Step 9: Deploy FilecoinWarmStorageServiceStateView
echo -e "${BOLD}FilecoinWarmStorageServiceStateView${RESET}"
if [ "$DRY_RUN" = "true" ]; then
    echo "  🔍 Would deploy (skipping in dry-run)"
    WARM_STORAGE_VIEW_ADDRESS="0x8901234567890123456789012345678901234567"  # Dummy address for dry-run
    echo "  ✅ Deployment planned (dummy: $WARM_STORAGE_VIEW_ADDRESS)"
else
    echo "  🔧 Using external deployment script..."
    source "$SCRIPT_DIR/deploy-warm-storage-view.sh"
    echo "  ✅ Deployed at: $WARM_STORAGE_VIEW_ADDRESS"
fi
echo

# Step 10: Set the view contract address on the main contract
echo -e "${BOLD}Setting view contract address${RESET}"
NONCE=$(expr $NONCE + "1")
if [ "$DRY_RUN" = "true" ]; then
    echo "  🔍 Would set view contract address on main contract (skipping in dry-run)"
else
    echo "  🔧 Setting view address on FilecoinWarmStorageService..."
    source "$SCRIPT_DIR/set-warm-storage-view.sh"
    echo "  ✅ View address set"
fi
echo

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
echo "FilecoinPayV1 Contract: $PAYMENTS_CONTRACT_ADDRESS"
echo "ServiceProviderRegistry Implementation: $REGISTRY_IMPLEMENTATION_ADDRESS"
echo "ServiceProviderRegistry Proxy: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "FilecoinWarmStorageService Implementation: $FWS_IMPLEMENTATION_ADDRESS"
echo "FilecoinWarmStorageService Proxy: $WARM_STORAGE_SERVICE_ADDRESS"
echo "FilecoinWarmStorageServiceStateView: $WARM_STORAGE_VIEW_ADDRESS"
echo
echo "Network Configuration ($NETWORK_NAME):"
echo "Challenge finality: $CHALLENGE_FINALITY epochs"
echo "Max proving period: $MAX_PROVING_PERIOD epochs"
echo "Challenge window size: $CHALLENGE_WINDOW_SIZE epochs"
echo "USDFC token address: $USDFC_TOKEN_ADDRESS"
echo "FilBeam controller address: $FILBEAM_CONTROLLER_ADDRESS"
echo "FilBeam beneficiary address: $FILBEAM_BENEFICIARY_ADDRESS"
echo "Service name: $SERVICE_NAME"
echo "Service description: $SERVICE_DESCRIPTION"

# Contract verification
if [ "$DRY_RUN" = "false" ] && [ "${AUTO_VERIFY:-true}" = "true" ]; then
    echo
    echo "🔍 Starting automatic contract verification..."
    
    pushd "$(dirname "$0")/.." >/dev/null
    source tools/verify-contracts.sh
    
    verify_contracts_batch \
        "$VERIFIER_IMPLEMENTATION_ADDRESS,lib/pdp/src/PDPVerifier.sol:PDPVerifier" \
        "$PDP_VERIFIER_ADDRESS,lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy" \
        "$PAYMENTS_CONTRACT_ADDRESS,lib/fws-payments/src/FilecoinPayV1.sol:FilecoinPayV1" \
        "$REGISTRY_IMPLEMENTATION_ADDRESS,src/ServiceProviderRegistry.sol:ServiceProviderRegistry" \
        "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS,lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" \
        "$FWS_IMPLEMENTATION_ADDRESS,src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService" \
        "$WARM_STORAGE_SERVICE_ADDRESS,lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" \
        "$WARM_STORAGE_VIEW_ADDRESS,src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView"
    
    popd >/dev/null
fi
