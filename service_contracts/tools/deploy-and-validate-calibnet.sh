#!/bin/bash
# deploy-and-validate-calibnet.sh - Deploy and validate FilecoinWarmStorageService contracts on Calibnet
#
# This script combines deployment and validation into a single operation:
# 1. Runs the existing deployment script
# 2. Parses deployment output to extract contract addresses
# 3. Runs comprehensive validation of deployed contracts
#
# Usage: ./deploy-and-validate-calibnet.sh
#
# Required Environment Variables (same as deploy-all-warm-storage-calibnet.sh):
# - KEYSTORE: Path to the Ethereum keystore file
# - PASSWORD: Password for the keystore
# - RPC_URL: RPC endpoint for Calibration testnet
# - CHALLENGE_FINALITY: Challenge finality parameter for PDPVerifier
#
# Optional Environment Variables:
# - MAX_PROVING_PERIOD: Maximum epochs between proofs (default: 30)
# - CHALLENGE_WINDOW_SIZE: Challenge window size in epochs (default: 15)
# - FILCDN_WALLET: FileCDN wallet address (has default)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== FilecoinWarmStorageService Deploy & Validate ===${NC}"
echo "Deploying and validating contracts on Calibration testnet"
echo ""

# Check required environment variables
required_vars=("KEYSTORE" "PASSWORD" "RPC_URL" "CHALLENGE_FINALITY")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: $var environment variable is not set${NC}"
        exit 1
    fi
done

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy-all-warm-storage-calibnet.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-deployment-calibnet.sh"

# Check if deployment script exists
if [ ! -f "$DEPLOY_SCRIPT" ]; then
    echo -e "${RED}Error: Deployment script not found at $DEPLOY_SCRIPT${NC}"
    exit 1
fi

# Check if validation script exists
if [ ! -f "$VALIDATE_SCRIPT" ]; then
    echo -e "${RED}Error: Validation script not found at $VALIDATE_SCRIPT${NC}"
    exit 1
fi

echo -e "${YELLOW}Step 1: Running deployment script...${NC}"
echo "Command: $DEPLOY_SCRIPT"
echo ""

# Run deployment and capture output
DEPLOY_OUTPUT_FILE=$(mktemp)
if "$DEPLOY_SCRIPT" 2>&1 | tee "$DEPLOY_OUTPUT_FILE"; then
    echo -e "${GREEN}✓ Deployment completed successfully${NC}"
else
    echo -e "${RED}✗ Deployment failed${NC}"
    rm -f "$DEPLOY_OUTPUT_FILE"
    exit 1
fi

echo ""
echo -e "${YELLOW}Step 2: Parsing deployment output...${NC}"

# Parse deployment output to extract contract addresses
VERIFIER_IMPLEMENTATION_ADDRESS=$(grep "PDPVerifier implementation deployed at:" "$DEPLOY_OUTPUT_FILE" | awk '{print $NF}')
PDP_VERIFIER_ADDRESS=$(grep "PDPVerifier proxy deployed at:" "$DEPLOY_OUTPUT_FILE" | awk '{print $NF}')
PAYMENTS_IMPLEMENTATION_ADDRESS=$(grep "Payments implementation deployed at:" "$DEPLOY_OUTPUT_FILE" | awk '{print $NF}')
PAYMENTS_CONTRACT_ADDRESS=$(grep "Payments proxy deployed at:" "$DEPLOY_OUTPUT_FILE" | awk '{print $NF}')
SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS=$(grep "FilecoinWarmStorageService implementation deployed at:" "$DEPLOY_OUTPUT_FILE" | awk '{print $NF}')
WARM_STORAGE_SERVICE_ADDRESS=$(grep "FilecoinWarmStorageService proxy deployed at:" "$DEPLOY_OUTPUT_FILE" | awk '{print $NF}')

# Verify we extracted all addresses
missing_addresses=()
if [ -z "$VERIFIER_IMPLEMENTATION_ADDRESS" ]; then missing_addresses+=("VERIFIER_IMPLEMENTATION_ADDRESS"); fi
if [ -z "$PDP_VERIFIER_ADDRESS" ]; then missing_addresses+=("PDP_VERIFIER_ADDRESS"); fi
if [ -z "$PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then missing_addresses+=("PAYMENTS_IMPLEMENTATION_ADDRESS"); fi
if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then missing_addresses+=("PAYMENTS_CONTRACT_ADDRESS"); fi
if [ -z "$SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then missing_addresses+=("SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"); fi
if [ -z "$WARM_STORAGE_SERVICE_ADDRESS" ]; then missing_addresses+=("WARM_STORAGE_SERVICE_ADDRESS"); fi

if [ ${#missing_addresses[@]} -ne 0 ]; then
    echo -e "${RED}Error: Failed to parse the following contract addresses from deployment output:${NC}"
    for addr in "${missing_addresses[@]}"; do
        echo -e "${RED}  - $addr${NC}"
    done
    echo ""
    echo "Deployment output:"
    cat "$DEPLOY_OUTPUT_FILE"
    rm -f "$DEPLOY_OUTPUT_FILE"
    exit 1
fi

echo -e "${GREEN}✓ Successfully parsed all contract addresses:${NC}"
echo "  PDPVerifier Implementation: $VERIFIER_IMPLEMENTATION_ADDRESS"
echo "  PDPVerifier Proxy: $PDP_VERIFIER_ADDRESS"
echo "  Payments Implementation: $PAYMENTS_IMPLEMENTATION_ADDRESS"
echo "  Payments Proxy: $PAYMENTS_CONTRACT_ADDRESS"
echo "  FilecoinWarmStorageService Implementation: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
echo "  FilecoinWarmStorageService Proxy: $WARM_STORAGE_SERVICE_ADDRESS"

# Clean up deployment output file
rm -f "$DEPLOY_OUTPUT_FILE"

echo ""
echo -e "${YELLOW}Step 3: Running validation script...${NC}"

# Add delay to allow blockchain state to propagate
echo "Waiting 30 seconds (blocktime) for state to propagate..."
sleep 30

# Export environment variables for validation script
export RPC_URL
export PDP_VERIFIER_ADDRESS
export PAYMENTS_CONTRACT_ADDRESS
export WARM_STORAGE_SERVICE_ADDRESS
export VERIFIER_IMPLEMENTATION_ADDRESS
export PAYMENTS_IMPLEMENTATION_ADDRESS
export SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS

# Set expected values based on deployment parameters
export EXPECTED_CHALLENGE_FINALITY="$CHALLENGE_FINALITY"
export EXPECTED_MAX_PROVING_PERIOD="${MAX_PROVING_PERIOD:-30}"
export EXPECTED_CHALLENGE_WINDOW_SIZE="${CHALLENGE_WINDOW_SIZE:-15}"

echo "Running validation with extracted addresses..."
echo ""

# Run validation script
if "$VALIDATE_SCRIPT"; then
    echo ""
    echo -e "${GREEN}🎉 DEPLOYMENT AND VALIDATION COMPLETED SUCCESSFULLY! 🎉${NC}"
    echo ""
    echo -e "${BLUE}=== FINAL DEPLOYMENT SUMMARY ===${NC}"
    echo "PDPVerifier Implementation: $VERIFIER_IMPLEMENTATION_ADDRESS"
    echo "PDPVerifier Proxy: $PDP_VERIFIER_ADDRESS"
    echo "Payments Implementation: $PAYMENTS_IMPLEMENTATION_ADDRESS"
    echo "Payments Proxy: $PAYMENTS_CONTRACT_ADDRESS"
    echo "FilecoinWarmStorageService Implementation: $SERVICE_PAYMENTS_IMPLEMENTATION_ADDRESS"
    echo "FilecoinWarmStorageService Proxy: $WARM_STORAGE_SERVICE_ADDRESS"
    echo ""
    echo "All contracts have been deployed and validated successfully on Calibnet!"
    exit 0
else
    echo ""
    echo -e "${RED}❌ VALIDATION FAILED${NC}"
    echo "Deployment completed but validation found issues."
    echo "Please review the validation output above and check the contracts manually."
    exit 1
fi 