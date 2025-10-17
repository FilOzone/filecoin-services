#! /bin/bash
# deploy.sh deploys the FilecoinPayV1 contract to the specified network
# Usage: ./tools/deploy.sh <chain_id>
# Example: ./tools/deploy.sh 314159 (calibnet)
#          ./tools/deploy.sh 314 (mainnet)
#          ./tools/deploy.sh 31415926 (devnet)
#
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
fi
set -euo pipefail

CHAIN_ID=${1:-314159} # Default to calibnet

# Set default RPC_URL if not set
if [ -z "${RPC_URL:-}" ]; then
  if [ "$CHAIN_ID" = "314159" ]; then
    export RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
  elif [ "$CHAIN_ID" = "314" ]; then
    export RPC_URL="https://api.node.glif.io/rpc/v1"
  else
    echo "Error: RPC_URL must be set for CHAIN_ID $CHAIN_ID"
    exit 1
  fi
fi

if [ -z "${KEYSTORE:-}" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi
if [ -z "${PASSWORD:-}" ]; then
  echo "Error: PASSWORD is not set"
  exit 1
fi

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying FilecoinPayV1 from address $ADDR to chain $CHAIN_ID"
NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

# Use PAYMENTS_PATH if set, otherwise default
if [ -z "${PAYMENTS_PATH:-}" ]; then
  PAYMENTS_PATH="src/FilecoinPayV1.sol:FilecoinPayV1"
fi

echo "Deploying FilecoinPayV1 implementation ($PAYMENTS_PATH)"
export PAYMENTS_CONTRACT_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID $PAYMENTS_PATH | grep "Deployed to" | awk '{print $3}')
if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
    echo "Error: Failed to extract FilecoinPayV1 implementation contract address"
    exit 1
fi
echo "FilecoinPayV1 Address: $PAYMENTS_CONTRACT_ADDRESS"

echo ""
echo "=== DEPLOYMENT SUMMARY ==="
echo "FilecoinPayV1 Contract Address: $PAYMENTS_CONTRACT_ADDRESS"
echo "=========================="
