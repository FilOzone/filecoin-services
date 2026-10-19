#! /bin/bash
# warm-storage-deploy-all.sh deploys a fresh Warm Storage stack: SessionKeyRegistry, FilecoinPayV1, PDPVerifier,
# ServiceProviderRegistry, FWSS on the ERC-8167 dispatcher, and the endorsements ProviderIdSet. Mainly for local devnets;
# existing deployments change through josuke migrations, not this script.
# Each contract whose <NAME>_ADDRESS is set, in the environment or deployments.json, is used as-is instead of deployed.
# Auto-detects network based on RPC chain ID and sets appropriate configuration
# Assumption: ETH_KEYSTORE, PASSWORD, ETH_RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid ETH_RPC_URL for the target network.
# Assumption: forge, cast, jq and the evm assembler (make install-evm) are in the PATH
# Assumption: called from contracts directory so forge paths work out
#

# Set DRY_RUN=false to deploy and broadcast transactions (default is a plan with dummy addresses for safety).
DRY_RUN=${DRY_RUN:-true}

# Filecoin RPC inclusion can exceed Foundry's default transaction and RPC timeouts.
# Keep both values overrideable while allowing enough time for a mined CREATE
# transaction to be observed before the deployment script decides it failed.
export ETH_TIMEOUT="${ETH_TIMEOUT:-300}"
export ETH_RPC_TIMEOUT="${ETH_RPC_TIMEOUT:-300}"

case "$DRY_RUN" in
  true|false) ;;
  *)
    echo "Error: DRY_RUN must be 'true' or 'false'"
    exit 1
    ;;
esac

# Default constants (same across all networks)
DEFAULT_FILBEAM_BENEFICIARY_ADDRESS="0x1D60d2F5960Af6341e842C539985FA297E10d6eA"
DEFAULT_FILBEAM_CONTROLLER_ADDRESS="0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A"

if [ "$DRY_RUN" = "true" ]; then
    echo "🧪 Running in DRY-RUN mode - plan only, no transactions"
else
    echo "🚀 Running in DEPLOYMENT mode - will deploy and broadcast transactions"
fi

# Get this script's directory so we can reliably source other scripts
# in the same directory, regardless of where this script is executed from
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")"

# Source the shared deployments script
source "$SCRIPT_DIR/deployments.sh"

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
  "31415926")
    NETWORK_NAME="devnet"
    # USDFC_TOKEN_ADDRESS must be provided via environment variable for devnet
    # Default challenge and proving configuration for devnet (fastest for testing)
    DEFAULT_CHALLENGE_FINALITY="5"           # Minimal value for fast local testing
    DEFAULT_MAX_PROVING_PERIOD="120"         # 120 epochs on devnet
    DEFAULT_CHALLENGE_WINDOW_SIZE="10"       # 10 epochs
    ;;
  "314159")
    NETWORK_NAME="calibnet"
    # Network-specific addresses for calibnet
    USDFC_TOKEN_ADDRESS="${USDFC_TOKEN_ADDRESS:-0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0}"
    # Default challenge and proving configuration for calibnet (testing values)
    DEFAULT_CHALLENGE_FINALITY="10"          # Low value for fast testing (should be 150 in production)
    DEFAULT_MAX_PROVING_PERIOD="240"         # 240 epochs on calibnet
    DEFAULT_CHALLENGE_WINDOW_SIZE="20"       # 20 epochs
    ;;
  "314")
    NETWORK_NAME="mainnet"
    # Network-specific addresses for mainnet
    USDFC_TOKEN_ADDRESS="${USDFC_TOKEN_ADDRESS:-0x80B98d3aa09ffff255c3ba4A241111Ff1262F045}"
    # Default challenge and proving configuration for mainnet (production values)
    DEFAULT_CHALLENGE_FINALITY="150"         # Production security value
    DEFAULT_MAX_PROVING_PERIOD="2880"        # 2880 epochs on mainnet
    DEFAULT_CHALLENGE_WINDOW_SIZE="60"       # 60 epochs
    ;;
  *)
    echo "Error: Unsupported network"
    echo "  Supported networks:"
    echo "    31415926 - Filecoin local development network"
    echo "    314159 - Filecoin Calibration testnet"
    echo "    314    - Filecoin mainnet"
    echo "  Detected chain ID: $CHAIN"
    exit 1
    ;;
esac

echo "Detected Chain ID: $CHAIN ($NETWORK_NAME)"

# Load deployment addresses from deployments.json
load_deployment_addresses "$CHAIN"

# Devnet requires USDFC_TOKEN_ADDRESS to be provided
if [ "$CHAIN" = "31415926" ] && [ -z "$USDFC_TOKEN_ADDRESS" ]; then
  echo "Error: USDFC_TOKEN_ADDRESS is not set (required for devnet)"
  echo "Please set USDFC_TOKEN_ADDRESS environment variable to your deployed MockUSDFC address"
  exit 1
fi

if [ "$DRY_RUN" != "true" ] && [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set (required for actual deployment)"
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

# Reports an address that is already provided, else returns non-zero so the caller deploys
# Args: $1=var_name, $2=description
using_existing() {
    local var_name="$1"
    local description="$2"

    if [ -z "${!var_name}" ]; then
        return 1
    fi
    echo -e "${BOLD}${description}${RESET}"
    echo "  ✅ Using existing address: ${!var_name}"
    echo
}

# Sets a dummy address for a dry run, after checking the artifact the deployment needs
# Args: $1=var_name, $2...=artifact paths
plan_dummy() {
    local var_name="$1"
    shift
    for artifact_path in "$@"; do
        if [ ! -f "$artifact_path" ]; then
            echo "  ❌ Artifact not found: $artifact_path"
            exit 1
        fi
    done
    local dummy_addr="0x$(printf '%s' "$var_name" | sha256sum | cut -c1-40)"
    eval "$var_name='$dummy_addr'"
    echo "  ✅ Deployment planned (dummy: ${!var_name})"
}

# Deploy a contract if its address is not already provided
# Args: $1=var_name, $2=artifact_contract, $3=description, $4...=constructor args
deploy_contract_if_needed() {
    local var_name="$1"
    local contract="$2"
    local description="$3"
    shift 3
    local constructor_args=("$@")

    using_existing "$var_name" "$description" && return 0

    echo -e "${BOLD}Deploying ${description}${RESET}"

    if [ "$DRY_RUN" = "true" ]; then
        plan_dummy "$var_name" "$(_artifact_path "$contract")"
    else
        local forge_cmd=(forge create --password "$PASSWORD" $BROADCAST_FLAG --nonce "$NONCE" "$contract")
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

        update_deployment_address "$CHAIN" "$var_name" "${!var_name}"
        update_deployment_bytecode "$CHAIN" "${var_name%_ADDRESS}" "$contract" "" "${constructor_args[@]}"
    fi

    NONCE=$(expr $NONCE + "1")
    echo
}

# Deploy a proxy contract if address not already provided
# Args: $1=var_name, $2=implementation_address, $3=init_data, $4=description
deploy_proxy_if_needed() {
    deploy_contract_if_needed "$1" lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy "$4" "$2" "$3"
}

# Deploy session key registry if needed (uses ./session-key-registry-deploy.sh)
deploy_session_key_registry_if_needed() {
    using_existing SESSION_KEY_REGISTRY_ADDRESS SessionKeyRegistry && return 0

    echo -e "${BOLD}Deploying SessionKeyRegistry${RESET}"

    if [ "$DRY_RUN" = "true" ]; then
        SESSION_KEY_REGISTRY_ADDRESS="0x9012345678901234567890123456789012345678"
        echo "  🧪 Using dummy address: $SESSION_KEY_REGISTRY_ADDRESS"
    else
        echo "  🔧 Using external deployment script..."
        source "$SCRIPT_DIR/session-key-registry-deploy.sh"
        NONCE=$(expr $NONCE + "1")
        echo "  ✅ Deployed at: $SESSION_KEY_REGISTRY_ADDRESS"

        # Update deployments.json
        if [ -n "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
            update_deployment_address "$CHAIN" "SESSION_KEY_REGISTRY_ADDRESS" "$SESSION_KEY_REGISTRY_ADDRESS"
        fi
    fi
    echo
}

# Deploy endorsements ProviderIdSet contract if needed (uses ./provider-id-set-deploy.sh)
deploy_endorsements_if_needed() {
    using_existing ENDORSEMENT_SET_ADDRESS "Endorsements ProviderIdSet" && return 0

    echo -e "${BOLD}Deploying Endorsements ProviderIdSet${RESET}"

    if [ "$DRY_RUN" = "true" ]; then
        ENDORSEMENT_SET_ADDRESS="0x0123456789012345678901234567890123456789"
        echo "  🧪 Using dummy address: $ENDORSEMENT_SET_ADDRESS"
    else
        echo "  🔧 Using external deployment script..."
        AUTO_VERIFY_BEFORE=${AUTO_VERIFY:-true}
        AUTO_VERIFY=false # override so as to set last
        # This also updates deployments.json
        source "$SCRIPT_DIR/provider-id-set-deploy.sh"
        AUTO_VERIFY=$AUTO_VERIFY_BEFORE
        NONCE=$(expr $NONCE + "1")
        echo "  ✅ Deployed at: $ENDORSEMENT_SET_ADDRESS"
    fi
    echo
}

# Deploy FWSS on the ERC-8167 dispatcher if needed (uses script/FWSSDeploy.s.sol, which the tests share)
deploy_fwss_if_needed() {
    using_existing FWSS_PROXY_ADDRESS "FilecoinWarmStorageService proxy" && return 0

    echo -e "${BOLD}Deploying FilecoinWarmStorageService${RESET}"

    if [ "$DRY_RUN" = "true" ]; then
        plan_dummy FWSS_PROXY_ADDRESS \
            lib/erc8167/out/Proxy.evm/Proxy.json \
            lib/erc8167/out/Implementation.evm/Implementation.json \
            "$(_artifact_path src/FWSSInitializer.sol:FWSSInitializer)"
        FWSS_DISPATCHER_ADDRESS="${FWSS_DISPATCHER_ADDRESS:-0x$(printf '%s' FWSS_DISPATCHER_ADDRESS | sha256sum | cut -c1-40)}"
    else
        # --skip-simulation makes forge estimate each transaction's gas with the node, like forge create: FEVM gas
        # differs from the local EVM's, and Foundry does not know it does. --json reports what run() returns.
        local output
        if ! output=$(SKIP_UPDATE_DEPLOYMENTS="${SKIP_UPDATE_DEPLOYMENTS:-}" \
            FILECOIN_PAY_ADDRESS="$FILECOIN_PAY_ADDRESS" \
            PDP_VERIFIER_PROXY_ADDRESS="$PDP_VERIFIER_PROXY_ADDRESS" \
            USDFC_TOKEN_ADDRESS="$USDFC_TOKEN_ADDRESS" \
            FILBEAM_BENEFICIARY_ADDRESS="$FILBEAM_BENEFICIARY_ADDRESS" \
            SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS="$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
            SESSION_KEY_REGISTRY_ADDRESS="$SESSION_KEY_REGISTRY_ADDRESS" \
            MAX_PROVING_PERIOD="$MAX_PROVING_PERIOD" \
            CHALLENGE_WINDOW_SIZE="$CHALLENGE_WINDOW_SIZE" \
            FILBEAM_CONTROLLER_ADDRESS="$FILBEAM_CONTROLLER_ADDRESS" \
            forge script script/FWSSDeploy.s.sol \
                --rpc-url "$ETH_RPC_URL" --keystore "$ETH_KEYSTORE" --password "$PASSWORD" --sender "$ADDR" \
                --broadcast --skip-simulation --json); then
            echo "$output"
            echo "  ❌ FWSS deployment failed"
            exit 1
        fi
        jq -rR 'fromjson? | .logs[]? | "  " + .' <<<"$output"

        FWSS_DISPATCHER_ADDRESS=$(jq -rR 'fromjson? | .returns.dispatcher.value // empty' <<<"$output")
        FWSS_PROXY_ADDRESS=$(jq -rR 'fromjson? | .returns.proxy.value // empty' <<<"$output")
        if [ -z "$FWSS_PROXY_ADDRESS" ] || [ -z "$FWSS_DISPATCHER_ADDRESS" ]; then
            echo "  ❌ FWSSDeploy did not return the FWSS proxy and dispatcher"
            exit 1
        fi
        echo "  ✅ Deployed at: $FWSS_PROXY_ADDRESS"

        # forge script sent several transactions
        NONCE="$(cast nonce "$ADDR")"
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

# FWSS runs on the ERC-8167 dispatcher, which the evm assembler builds
echo "🔍 Building contracts..."
if ! make erc8167; then
    echo "❌ ERC-8167 build failed"
    exit 1
fi
if ! forge build; then
    echo "❌ Contract compilation failed"
    exit 1
fi
echo "✅ Contract compilation passed"

# ========================================
# Initialize Deployment Environment
# ========================================

if [ "$DRY_RUN" = "true" ]; then
    ADDR="0x0000000000000000000000000000000000000000"  # Dummy address for dry-run
    NONCE="0"  # Use dummy nonce for dry-run
    BROADCAST_FLAG=""
    echo "Deploying contracts from address $ADDR (dry-run)"
    echo "🧪 Will plan deployments without broadcasting transactions"
else
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

# Step 1: Deploy or use existing FilecoinPayV1 contract
deploy_contract_if_needed \
    "FILECOIN_PAY_ADDRESS" \
    "lib/fws-payments/src/FilecoinPayV1.sol:FilecoinPayV1" \
    "FilecoinPayV1"

# Step 2: Deploy or use existing PDPVerifier implementation, at initializer version 1 for its fresh proxy
deploy_contract_if_needed \
    "PDP_VERIFIER_IMPLEMENTATION_ADDRESS" \
    "lib/pdp/src/PDPVerifier.sol:PDPVerifier" \
    "PDPVerifier implementation" \
    "1" \
    "$CHALLENGE_FINALITY"

# Step 3: Deploy or use existing PDPVerifier proxy
INIT_DATA=$(cast calldata "initialize()")
deploy_proxy_if_needed \
    "PDP_VERIFIER_PROXY_ADDRESS" \
    "$PDP_VERIFIER_IMPLEMENTATION_ADDRESS" \
    "$INIT_DATA" \
    "PDPVerifier proxy"

# Step 4: Deploy or use existing ServiceProviderRegistry implementation, at initializer version 1 for its fresh proxy
deploy_contract_if_needed \
    "SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" \
    "src/ServiceProviderRegistry.sol:ServiceProviderRegistry" \
    "ServiceProviderRegistry implementation" \
    "1"

# Step 5: Deploy or use existing ServiceProviderRegistry proxy
REGISTRY_INIT_DATA=$(cast calldata "initialize()")
deploy_proxy_if_needed \
    "SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" \
    "$REGISTRY_INIT_DATA" \
    "ServiceProviderRegistry proxy"

# Step 6: Deploy or use existing FilecoinWarmStorageService, initialized with max proving period, challenge window
# size, and FilBeam controller address
deploy_fwss_if_needed

# Step 7: Deploy Endorsements ProviderIdSet
deploy_endorsements_if_needed

if [ "$DRY_RUN" = "true" ]; then
    echo
    echo "✅ Dry run completed successfully!"
    echo "🔍 Contract compilation and deployment planning passed"
    echo
    echo "To perform actual deployment, run with: DRY_RUN=false ./tools/warm-storage-deploy-all.sh"
    echo
    echo "# DRY-RUN SUMMARY ($NETWORK_NAME)"
else
    echo
    echo "✅ Deployment completed successfully!"
    echo
    echo "# DEPLOYMENT SUMMARY ($NETWORK_NAME)"
fi

echo "PDPVerifier Implementation: $PDP_VERIFIER_IMPLEMENTATION_ADDRESS"
echo "PDPVerifier Proxy: $PDP_VERIFIER_PROXY_ADDRESS"
echo "FilecoinPayV1 Contract: $FILECOIN_PAY_ADDRESS"
echo "ServiceProviderRegistry Implementation: $SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
echo "ServiceProviderRegistry Proxy: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "SessionKeyRegistry: $SESSION_KEY_REGISTRY_ADDRESS"
# The proxy's ERC-1967 implementation is the dispatcher, and the proxy serves the StateView reads itself
echo "FilecoinWarmStorageService Implementation: $FWSS_DISPATCHER_ADDRESS"
echo "FilecoinWarmStorageService Proxy: $FWSS_PROXY_ADDRESS"
echo "FilecoinWarmStorageService StateView: $FWSS_PROXY_ADDRESS"
echo "Endorsements: $ENDORSEMENT_SET_ADDRESS"
echo
echo "Network Configuration ($NETWORK_NAME):"
echo "Challenge finality: $CHALLENGE_FINALITY epochs"
echo "Max proving period: $MAX_PROVING_PERIOD epochs"
echo "Challenge window size: $CHALLENGE_WINDOW_SIZE epochs"
echo "USDFC token address: $USDFC_TOKEN_ADDRESS"
echo "FilBeam controller address: $FILBEAM_CONTROLLER_ADDRESS"
echo "FilBeam beneficiary address: $FILBEAM_BENEFICIARY_ADDRESS"

# Contract verification. josuke verify covers the FWSS facets.
if [ "$DRY_RUN" = "false" ] && [ "${AUTO_VERIFY:-true}" = "true" ]; then
    echo
    echo "🔍 Starting automatic contract verification..."

    pushd "$(dirname "$0")/.." >/dev/null
    source tools/verify-contracts.sh

    verify_contracts_batch \
        "$PDP_VERIFIER_IMPLEMENTATION_ADDRESS,lib/pdp/src/PDPVerifier.sol:PDPVerifier" \
        "$PDP_VERIFIER_PROXY_ADDRESS,lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy" \
        "$ENDORSEMENT_SET_ADDRESS,src/ProviderIdSet.sol:ProviderIdSet" \
        "$FILECOIN_PAY_ADDRESS,lib/fws-payments/src/FilecoinPayV1.sol:FilecoinPayV1" \
        "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS,src/ServiceProviderRegistry.sol:ServiceProviderRegistry" \
        "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS,lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy" \
        "$FWSS_PROXY_ADDRESS,lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy"

    popd >/dev/null
fi

# Update deployment metadata if this was an actual deployment
if [ "$DRY_RUN" != "true" ]; then
    echo
    echo "📝 Updating deployment metadata..."
    update_deployment_metadata "$CHAIN"
fi
