#!/bin/bash

# upgrade-registry.sh: Completes a pending upgrade for ServiceProviderRegistry
# Required args: ETH_RPC_URL, REGISTRY_PROXY_ADDRESS, ETH_KEYSTORE, PASSWORD, NEW_REGISTRY_IMPLEMENTATION_ADDRESS
# Optional args: NEW_VERSION
# Calculated if unset: CHAIN

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

if [ -z "$PASSWORD" ]; then
  echo "Error: PASSWORD is not set"
  exit 1
fi

if [ -z "$CHAIN" ]; then
  CHAIN=$(cast chain-id)
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Using owner address: $ADDR"

# Get current nonce
NONCE=$(cast nonce "$ADDR")

if [ -z "$REGISTRY_PROXY_ADDRESS" ]; then
  echo "Error: REGISTRY_PROXY_ADDRESS is not set"
  exit 1
fi

PROXY_OWNER=$(cast call -f 0x0000000000000000000000000000000000000000 "$REGISTRY_PROXY_ADDRESS" "owner()(address)" 2>/dev/null)
if [ "$PROXY_OWNER" != "$ADDR" ]; then
  echo "Supplied ETH_KEYSTORE ($ADDR) is not the proxy owner ($PROXY_OWNER)."
  exit 1
fi

# Get the upgrade plan (if any)
UPGRADE_PLAN=($(cast call -f 0x0000000000000000000000000000000000000000 "$REGISTRY_PROXY_ADDRESS" "nextUpgrade()(address,uint96)" 2>/dev/null))

PLANNED_REGISTRY_IMPLEMENTATION_ADDRESS=${UPGRADE_PLAN[0]}
AFTER_EPOCH=${UPGRADE_PLAN[1]}

# Check if there's a planned upgrade (new two-step mechanism)
# If PLANNED_REGISTRY_IMPLEMENTATION_ADDRESS is zero, fall back to one-step mechanism
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"

if [ "$PLANNED_REGISTRY_IMPLEMENTATION_ADDRESS" != "$ZERO_ADDRESS" ]; then
  # New two-step mechanism: validate planned upgrade
  echo "Detected planned upgrade (two-step mechanism)"
  
  if [ "$PLANNED_REGISTRY_IMPLEMENTATION_ADDRESS" != "$NEW_REGISTRY_IMPLEMENTATION_ADDRESS" ]; then
    echo "NEW_REGISTRY_IMPLEMENTATION_ADDRESS ($NEW_REGISTRY_IMPLEMENTATION_ADDRESS) != planned ($PLANNED_REGISTRY_IMPLEMENTATION_ADDRESS)"
    exit 1
  else
    echo "Upgrade plan matches ($NEW_REGISTRY_IMPLEMENTATION_ADDRESS)"
  fi

  CURRENT_EPOCH=$(cast block-number 2>/dev/null)

  if [ "$CURRENT_EPOCH" -lt "$AFTER_EPOCH" ]; then
    echo "Not time yet ($CURRENT_EPOCH < $AFTER_EPOCH)"
    exit 1
  else
    echo "Upgrade ready ($CURRENT_EPOCH >= $AFTER_EPOCH)"
  fi
else
  # Old one-step mechanism: direct upgrade without announcement
  echo "No planned upgrade detected, using one-step mechanism (direct upgrade)"
  echo "WARNING: This is the legacy upgrade path. For new deployments, use announce-planned-upgrade-registry.sh first."
fi

if [ -n "$NEW_VERSION" ]; then
  echo "Using provided version: $NEW_VERSION"
  MIGRATE_DATA=$(cast calldata "migrate(string)" "$NEW_VERSION")
else
  echo "Warning: NEW_VERSION is not set. Using empty string for version."
  MIGRATE_DATA=$(cast calldata "migrate(string)" "")
fi

# Call upgradeToAndCall on the proxy with migrate function
echo "Upgrading proxy and calling migrate..."
TX_HASH=$(cast send "$REGISTRY_PROXY_ADDRESS" "upgradeToAndCall(address,bytes)" "$NEW_REGISTRY_IMPLEMENTATION_ADDRESS" "$MIGRATE_DATA" \
  --password "$PASSWORD" \
  --nonce "$NONCE" \
  --json | jq -r '.transactionHash')

if [ -z "$TX_HASH" ]; then
  echo "Error: Failed to send upgrade transaction"
  echo "The transaction may have failed due to:"
  echo "- Insufficient permissions (not owner)"
  echo "- Proxy is paused or locked"
  echo "- Implementation address is invalid"
  exit 1
fi

echo "Upgrade transaction sent: $TX_HASH"
echo "Waiting for confirmation..."

# Wait for transaction receipt
cast receipt "$TX_HASH" --confirmations 1 > /dev/null

# Verify the upgrade by checking the implementation address
echo "Verifying upgrade..."
NEW_IMPL=$(cast rpc eth_getStorageAt "$REGISTRY_PROXY_ADDRESS" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc latest | sed 's/"//g' | sed 's/0x000000000000000000000000/0x/')

# Compare to lowercase
export EXPECTED_IMPL=$(echo $NEW_REGISTRY_IMPLEMENTATION_ADDRESS | tr '[:upper:]' '[:lower:]')

if [ "$NEW_IMPL" = "$EXPECTED_IMPL" ]; then
    echo "✅ Upgrade successful! Proxy now points to: $NEW_REGISTRY_IMPLEMENTATION_ADDRESS"
else
    echo "⚠️  Warning: Could not verify upgrade. Please check manually."
    echo "Expected: $NEW_REGISTRY_IMPLEMENTATION_ADDRESS"
    echo "Got: $NEW_IMPL"
fi

