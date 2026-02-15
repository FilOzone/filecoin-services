#!/bin/bash
# validate-deployment-calibnet.sh - Validates deployed FilecoinWarmStorageService contracts on Calibnet
# 
# This script performs comprehensive validation of all deployed contracts including:
# - Contract existence and bytecode verification
# - Basic contract functionality testing
# - Proxy configuration validation
# - Parameter verification
#
# Usage: ./validate-deployment-calibnet.sh
# 
# Required Environment Variables:
# - RPC_URL: RPC endpoint for Calibration testnet
# - PDP_VERIFIER_ADDRESS: Address of deployed PDPVerifier proxy
# - PAYMENTS_CONTRACT_ADDRESS: Address of deployed Payments proxy  
# - WARM_STORAGE_SERVICE_ADDRESS: Address of deployed FilecoinWarmStorageService proxy
# - VERIFIER_IMPLEMENTATION_ADDRESS: Address of PDPVerifier implementation
# - PAYMENTS_IMPLEMENTATION_ADDRESS: Address of Payments implementation
# - SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS: Address of FilecoinWarmStorageService implementation
#
# Optional Environment Variables:
# - EXPECTED_CHALLENGE_FINALITY: Expected challenge finality value (default: 900)
# - EXPECTED_MAX_PROVING_PERIOD: Expected max proving period (default: 30)
# - EXPECTED_CHALLENGE_WINDOW_SIZE: Expected challenge window size (default: 15)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters for test results
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# Default expected values
EXPECTED_CHALLENGE_FINALITY="${EXPECTED_CHALLENGE_FINALITY:-900}"
EXPECTED_MAX_PROVING_PERIOD="${EXPECTED_MAX_PROVING_PERIOD:-30}"
EXPECTED_CHALLENGE_WINDOW_SIZE="${EXPECTED_CHALLENGE_WINDOW_SIZE:-15}"
EXPECTED_USDFC_TOKEN="0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"
EXPECTED_OPERATOR_COMMISSION_BPS="100"

echo -e "${BLUE}=== FilecoinWarmStorageService Deployment Validation ===${NC}"
echo "Validating contracts on Calibration testnet"
echo "RPC URL: $RPC_URL"
echo ""

# Function to log test results
log_test() {
    local test_name="$1"
    local result="$2"
    local details="$3"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}✓ PASS${NC} - $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        if [ -n "$details" ]; then
            echo "  $details"
        fi
    else
        echo -e "${RED}✗ FAIL${NC} - $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        if [ -n "$details" ]; then
            echo -e "${RED}  Error: $details${NC}"
        fi
    fi
}

# Function to check if address has contract code
has_contract_code() {
    local address="$1"
    local code_size=$(cast code --rpc-url "$RPC_URL" "$address" | wc -c)
    # Subtract 2 for the "0x" prefix, empty contracts return "0x"
    [ "$code_size" -gt 2 ]
}

# Function to normalize addresses for comparison (remove padding, lowercase)
normalize_address() {
    local addr="$1"
    # Remove padding, ensure lowercase, keep 0x prefix
    echo "$addr" | sed 's/0x000000000000000000000000/0x/' | tr '[:upper:]' '[:lower:]'
}

# Function to get implementation address from ERC1967 proxy storage
get_proxy_implementation() {
    local proxy_address="$1"
    # ERC1967 implementation storage slot: keccak256("eip1967.proxy.implementation") - 1
    local storage_slot="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
    
    # Retry logic to handle transient network issues
    for attempt in 1 2 3; do
        echo "DEBUG: Attempt $attempt to read implementation address for $proxy_address" >&2
        local raw_address=$(cast storage --rpc-url "$RPC_URL" "$proxy_address" "$storage_slot" 2>/dev/null)
        echo "DEBUG: Raw address attempt $attempt: '$raw_address'" >&2
        
        # Check if we got a valid response
        if [ -n "$raw_address" ] && [ "$raw_address" != "0x" ] && [ "$raw_address" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
            # Convert to address format (remove padding, ensure single 0x prefix)
            local clean_address=$(echo "$raw_address" | sed 's/0x000000000000000000000000//')
            if [[ "$clean_address" == "0x"* ]]; then
                echo "$clean_address"
            else
                echo "0x$clean_address"
            fi
            return 0
        fi
        
        if [ $attempt -lt 3 ]; then
            echo "DEBUG: Attempt $attempt failed, retrying in 5 seconds..." >&2
            sleep 5
        fi
    done
    
    # If all attempts failed, return the last raw address for debugging
    echo "DEBUG: All attempts failed, last raw address: '$raw_address'" >&2
    echo "$raw_address"
}

# Function to safely call contract method
safe_contract_call() {
    local address="$1"
    local method="$2"
    local expected_error="${3:-}"
    
    local result
    if result=$(cast call --rpc-url "$RPC_URL" "$address" "$method" 2>&1); then
        echo "$result"
        return 0
    else
        if [ -n "$expected_error" ]; then
            echo "EXPECTED_ERROR"
            return 1
        else
            echo "ERROR: $result" >&2
            return 1
        fi
    fi
}

# Validate required environment variables
echo -e "${YELLOW}Checking environment variables...${NC}"

required_vars=(
    "RPC_URL"
    "PDP_VERIFIER_ADDRESS" 
    "PAYMENTS_CONTRACT_ADDRESS"
    "WARM_STORAGE_SERVICE_ADDRESS"
    "VERIFIER_IMPLEMENTATION_ADDRESS"
    "PAYMENTS_IMPLEMENTATION_ADDRESS" 
    "SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log_test "Environment variable $var" "FAIL" "Variable not set"
        exit 1
    else
        log_test "Environment variable $var" "PASS" "Set to ${!var}"
    fi
done

echo ""
echo -e "${YELLOW}=== Contract Existence Validation ===${NC}"

# Test: PDPVerifier Implementation
if has_contract_code "$VERIFIER_IMPLEMENTATION_ADDRESS"; then
    log_test "PDPVerifier Implementation has contract code" "PASS" "Address: $VERIFIER_IMPLEMENTATION_ADDRESS"
else
    log_test "PDPVerifier Implementation has contract code" "FAIL" "No code at address: $VERIFIER_IMPLEMENTATION_ADDRESS"
fi

# Test: PDPVerifier Proxy
if has_contract_code "$PDP_VERIFIER_ADDRESS"; then
    log_test "PDPVerifier Proxy has contract code" "PASS" "Address: $PDP_VERIFIER_ADDRESS"
else
    log_test "PDPVerifier Proxy has contract code" "FAIL" "No code at address: $PDP_VERIFIER_ADDRESS"
fi

# Test: Payments Implementation
if has_contract_code "$PAYMENTS_IMPLEMENTATION_ADDRESS"; then
    log_test "Payments Implementation has contract code" "PASS" "Address: $PAYMENTS_IMPLEMENTATION_ADDRESS"
else
    log_test "Payments Implementation has contract code" "FAIL" "No code at address: $PAYMENTS_IMPLEMENTATION_ADDRESS"
fi

# Test: Payments Proxy
if has_contract_code "$PAYMENTS_CONTRACT_ADDRESS"; then
    log_test "Payments Proxy has contract code" "PASS" "Address: $PAYMENTS_CONTRACT_ADDRESS"
else
    log_test "Payments Proxy has contract code" "FAIL" "No code at address: $PAYMENTS_CONTRACT_ADDRESS"
fi

# Test: FilecoinWarmStorageService Implementation
if has_contract_code "$SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"; then
    log_test "FilecoinWarmStorageService Implementation has contract code" "PASS" "Address: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
else
    log_test "FilecoinWarmStorageService Implementation has contract code" "FAIL" "No code at address: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
fi

# Test: FilecoinWarmStorageService Proxy
if has_contract_code "$WARM_STORAGE_SERVICE_ADDRESS"; then
    log_test "FilecoinWarmStorageService Proxy has contract code" "PASS" "Address: $WARM_STORAGE_SERVICE_ADDRESS"
else
    log_test "FilecoinWarmStorageService Proxy has contract code" "FAIL" "No code at address: $WARM_STORAGE_SERVICE_ADDRESS"
fi

echo ""
echo -e "${YELLOW}=== PDPVerifier Functionality Validation ===${NC}"

# Test: PDPVerifier owner call
if owner=$(safe_contract_call "$PDP_VERIFIER_ADDRESS" "owner()"); then
    log_test "PDPVerifier owner() call" "PASS" "Owner: $owner"
else
    log_test "PDPVerifier owner() call" "FAIL" "Failed to call owner()"
fi

# Test: PDPVerifier challengeFinality call
if challenge_finality=$(safe_contract_call "$PDP_VERIFIER_ADDRESS" "getChallengeFinality()"); then
    # Convert hex to decimal for comparison
    challenge_finality_decimal=$(printf "%d" "$challenge_finality")
    if [ "$challenge_finality_decimal" = "$EXPECTED_CHALLENGE_FINALITY" ]; then
        log_test "PDPVerifier getChallengeFinality() value" "PASS" "Value: $challenge_finality_decimal (expected: $EXPECTED_CHALLENGE_FINALITY)"
    else
        log_test "PDPVerifier getChallengeFinality() value" "FAIL" "Value: $challenge_finality_decimal, expected: $EXPECTED_CHALLENGE_FINALITY"
    fi
else
    log_test "PDPVerifier getChallengeFinality() call" "FAIL" "Failed to call getChallengeFinality()"
fi

# Test: PDPVerifier implementation address
if implementation=$(get_proxy_implementation "$PDP_VERIFIER_ADDRESS"); then
    # Normalize both addresses for comparison
    impl_clean=$(normalize_address "$implementation")
    expected_clean=$(normalize_address "$VERIFIER_IMPLEMENTATION_ADDRESS")
    if [ "$impl_clean" = "$expected_clean" ]; then
        log_test "PDPVerifier proxy points to correct implementation" "PASS" "Implementation: $implementation"
    else
        log_test "PDPVerifier proxy points to correct implementation" "FAIL" "Expected: $VERIFIER_IMPLEMENTATION_ADDRESS, Got: $implementation"
    fi
else
    log_test "PDPVerifier implementation() call" "FAIL" "Failed to get implementation address from storage"
fi

echo ""
echo -e "${YELLOW}=== FilecoinWarmStorageService Validation ===${NC}"

# Test: FilecoinWarmStorageService maxProvingPeriod
if max_proving_period=$(safe_contract_call "$WARM_STORAGE_SERVICE_ADDRESS" "getMaxProvingPeriod()"); then
    max_proving_period_decimal=$(printf "%d" "$max_proving_period")
    if [ "$max_proving_period_decimal" = "$EXPECTED_MAX_PROVING_PERIOD" ]; then
        log_test "FilecoinWarmStorageService getMaxProvingPeriod() value" "PASS" "Value: $max_proving_period_decimal (expected: $EXPECTED_MAX_PROVING_PERIOD)"
    else
        log_test "FilecoinWarmStorageService getMaxProvingPeriod() value" "FAIL" "Value: $max_proving_period_decimal, expected: $EXPECTED_MAX_PROVING_PERIOD"
    fi
else
    log_test "FilecoinWarmStorageService getMaxProvingPeriod() call" "FAIL" "Failed to call getMaxProvingPeriod()"
fi

# Test: FilecoinWarmStorageService challengeWindowSize
if challenge_window_size=$(safe_contract_call "$WARM_STORAGE_SERVICE_ADDRESS" "challengeWindow()"); then
    challenge_window_size_decimal=$(printf "%d" "$challenge_window_size")
    if [ "$challenge_window_size_decimal" = "$EXPECTED_CHALLENGE_WINDOW_SIZE" ]; then
        log_test "FilecoinWarmStorageService challengeWindow() value" "PASS" "Value: $challenge_window_size_decimal (expected: $EXPECTED_CHALLENGE_WINDOW_SIZE)"
    else
        log_test "FilecoinWarmStorageService challengeWindow() value" "FAIL" "Value: $challenge_window_size_decimal, expected: $EXPECTED_CHALLENGE_WINDOW_SIZE"
    fi
else
    log_test "FilecoinWarmStorageService challengeWindow() call" "FAIL" "Failed to call challengeWindow()"
fi

# Test: FilecoinWarmStorageService pdpVerifier address
if pdp_verifier=$(safe_contract_call "$WARM_STORAGE_SERVICE_ADDRESS" "pdpVerifierAddress()"); then
    pdp_clean=$(normalize_address "$pdp_verifier")
    expected_clean=$(normalize_address "$PDP_VERIFIER_ADDRESS")
    if [ "$pdp_clean" = "$expected_clean" ]; then
        log_test "FilecoinWarmStorageService pdpVerifierAddress() address" "PASS" "PDPVerifier: $pdp_verifier"
    else
        log_test "FilecoinWarmStorageService pdpVerifierAddress() address" "FAIL" "Expected: $PDP_VERIFIER_ADDRESS, Got: $pdp_verifier"
    fi
else
    log_test "FilecoinWarmStorageService pdpVerifierAddress() call" "FAIL" "Failed to call pdpVerifierAddress()"
fi

# Test: FilecoinWarmStorageService payments address
if payments=$(safe_contract_call "$WARM_STORAGE_SERVICE_ADDRESS" "paymentsContractAddress()"); then
    payments_clean=$(normalize_address "$payments")
    expected_clean=$(normalize_address "$PAYMENTS_CONTRACT_ADDRESS")
    if [ "$payments_clean" = "$expected_clean" ]; then
        log_test "FilecoinWarmStorageService paymentsContractAddress() address" "PASS" "Payments: $payments"
    else
        log_test "FilecoinWarmStorageService paymentsContractAddress() address" "FAIL" "Expected: $PAYMENTS_CONTRACT_ADDRESS, Got: $payments"
    fi
else
    log_test "FilecoinWarmStorageService paymentsContractAddress() call" "FAIL" "Failed to call paymentsContractAddress()"
fi

# Test: FilecoinWarmStorageService USDFC token address
if usdfc_token=$(safe_contract_call "$WARM_STORAGE_SERVICE_ADDRESS" "usdfcTokenAddress()"); then
    usdfc_clean=$(normalize_address "$usdfc_token")
    expected_clean=$(normalize_address "$EXPECTED_USDFC_TOKEN")
    if [ "$usdfc_clean" = "$expected_clean" ]; then
        log_test "FilecoinWarmStorageService usdfcTokenAddress() address" "PASS" "USDFC Token: $usdfc_token"
    else
        log_test "FilecoinWarmStorageService usdfcTokenAddress() address" "FAIL" "Expected: $EXPECTED_USDFC_TOKEN, Got: $usdfc_token"
    fi
else
    log_test "FilecoinWarmStorageService usdfcTokenAddress() call" "FAIL" "Failed to call usdfcTokenAddress()"
fi

# Test: FilecoinWarmStorageService service commission
if service_commission=$(safe_contract_call "$WARM_STORAGE_SERVICE_ADDRESS" "serviceCommissionBps()"); then
    service_commission_decimal=$(printf "%d" "$service_commission")
    # Note: The deployment shows the contract uses serviceCommissionBps, not operatorCommissionBps
    # The contract initializes serviceCommissionBps to 0%, not the operator commission
    expected_service_commission="0"  # Service commission is set to 0% in initialize()
    if [ "$service_commission_decimal" = "$expected_service_commission" ]; then
        log_test "FilecoinWarmStorageService serviceCommissionBps() value" "PASS" "Value: $service_commission_decimal bps (expected: $expected_service_commission)"
    else
        log_test "FilecoinWarmStorageService serviceCommissionBps() value" "FAIL" "Value: $service_commission_decimal, expected: $expected_service_commission"
    fi
else
    log_test "FilecoinWarmStorageService serviceCommissionBps() call" "FAIL" "Failed to call serviceCommissionBps()"
fi

# Test: FilecoinWarmStorageService implementation address
if implementation=$(get_proxy_implementation "$WARM_STORAGE_SERVICE_ADDRESS"); then
    # Debug output to see what we actually got
    echo "DEBUG: Raw implementation value: '$implementation'"
    echo "DEBUG: Implementation length: ${#implementation}"
    # Check if we got the zero address, which indicates the storage slot is empty
    if [ "$implementation" = "0x0000000000000000000000000000000000000000" ] || [ "$implementation" = "0x" ]; then
        log_test "FilecoinWarmStorageService proxy points to correct implementation" "FAIL" "Implementation storage slot is empty (got zero address). This may indicate the proxy was not properly initialized."
    else
        impl_clean=$(normalize_address "$implementation")
        expected_clean=$(normalize_address "$SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS")
        echo "DEBUG: Normalized impl: '$impl_clean'"
        echo "DEBUG: Normalized expected: '$expected_clean'"
        if [ "$impl_clean" = "$expected_clean" ]; then
            log_test "FilecoinWarmStorageService proxy points to correct implementation" "PASS" "Implementation: $implementation"
        else
            log_test "FilecoinWarmStorageService proxy points to correct implementation" "FAIL" "Expected: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS, Got: $implementation"
        fi
    fi
else
    log_test "FilecoinWarmStorageService implementation() call" "FAIL" "Failed to get implementation address from storage"
fi

echo ""
echo -e "${BLUE}=== Validation Summary ===${NC}"
echo -e "Total tests: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 All validation tests passed! Deployment is healthy.${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}❌ $TESTS_FAILED validation test(s) failed. Please review the deployment.${NC}"
    exit 1
fi 