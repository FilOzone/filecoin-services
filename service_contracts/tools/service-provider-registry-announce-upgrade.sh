#!/bin/bash

# service-provider-registry-announce-upgrade.sh: Announces a planned upgrade for ServiceProviderRegistry
# Required args: ETH_RPC_URL, SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS,
#                NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS, UPGRADE_DELAY_EPOCHS
# Required for direct send (not CALLDATA_ONLY): ETH_KEYSTORE, PASSWORD
# Optional: CALLDATA_ONLY=true to generate calldata for Safe multisig instead of sending

# Get script directory and source shared helpers
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/multisig.sh"

CALLDATA_ONLY="${CALLDATA_ONLY:-false}"

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

if [ "$CALLDATA_ONLY" != "true" ]; then
  if [ -z "$ETH_KEYSTORE" ]; then
    echo "Error: ETH_KEYSTORE is not set"
    exit 1
  fi

  if [ -z "$PASSWORD" ]; then
    echo "Error: PASSWORD is not set"
    exit 1
  fi
fi

if [ -z "$CHAIN" ]; then
  CHAIN=$(cast chain-id)
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

if [ -z "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
  echo "NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS is not set"
  exit 1
fi

if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
  echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not set"
  exit 1
fi

if [ -z "$UPGRADE_DELAY_EPOCHS" ]; then
  echo "Error: UPGRADE_DELAY_EPOCHS is not set"
  exit 1
fi

if [ -n "$AFTER_EPOCH" ]; then
  echo "Error: AFTER_EPOCH is no longer supported; use UPGRADE_DELAY_EPOCHS"
  exit 1
fi

CALL_SIGNATURE="announceUpgradePlan(address,uint96)"
CALL_ARGS=("$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" "$UPGRADE_DELAY_EPOCHS")

echo "Announcing ServiceProviderRegistry upgrade with a requested delay of $UPGRADE_DELAY_EPOCHS epochs"

if [ "$CALLDATA_ONLY" = "true" ]; then
  CALLDATA=$(cast calldata "$CALL_SIGNATURE" "${CALL_ARGS[@]}")
  print_safe_transaction "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "$CALL_SIGNATURE" "$CALLDATA"
  exit 0
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Sending announcement from owner address: $ADDR"

# Get current nonce
NONCE=$(cast nonce "$ADDR")

PROXY_OWNER=$(cast call -f 0x0000000000000000000000000000000000000000 "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "owner()(address)" 2>/dev/null)
if [ "$PROXY_OWNER" != "$ADDR" ]; then
  echo "Supplied ETH_KEYSTORE ($ADDR) is not the proxy owner ($PROXY_OWNER)."
  exit 1
fi

TX_HASH=$(cast send "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "$CALL_SIGNATURE" "${CALL_ARGS[@]}" \
  --password "$PASSWORD" \
  --nonce "$NONCE" \
  --json | jq -r '.transactionHash')

if [ -z "$TX_HASH" ]; then
  echo "Error: Failed to send announceUpgradePlan transaction"
  exit 1
fi

echo "$CALL_SIGNATURE transaction sent: $TX_HASH"
