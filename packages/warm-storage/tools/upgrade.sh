#!/bin/bash

# upgrade.sh: Completes a pending upgrade
# Required args: ETH_RPC_URL, WARM_STORAGE_PROXY_ADDRESS, ETH_KEYSTORE, PASSWORD, NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS
# Optional args: NEW_WARM_STORAGE_VIEW_ADDRESS
# Calculated if unset: CHAIN, WARM_STORAGE_VIEW_ADDRESS

if [ -z "$NEW_WARM_STORAGE_VIEW_ADDRESS" ]; then
  echo "Warning: NEW_WARM_STORAGE_VIEW_ADDRESS is not set. Keeping previous view contract." 
fi

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
  CHAIN=$(cast chain-id")
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Using owner address: $ADDR"

# Get current nonce
NONCE=$(cast nonce "$ADDR")

if [ -z "$WARM_STORAGE_PROXY_ADDRESS" ]; then
  echo "Error: WARM_STORAGE_PROXY_ADDRESS is not set"
  exit 1
fi

PROXY_OWNER=$(cast call "$WARM_STORAGE_PROXY_ADDRESS" "owner()(address)" 2>/dev/null)
if [ "$PROXY_OWNER" != "$ADDR" ]; then
  echo "Supplied ETH_KEYSTORE ($ADDR) is not the proxy owner ($PROXY_OWNER)."
  exit 1
fi

if [ -z "$WARM_STORAGE_VIEW_ADDRESS" ]; then
  WARM_STORAGE_VIEW_ADDRESS=$(cast call "$WARM_STORAGE_PROXY_ADDRESS" "viewContractAddress()(address)" 2>/dev/null)
fi

# Get the upgrade plan
UPGRADE_PLAN=($(cast call "$WARM_STORAGE_VIEW_ADDRESS" "nextUpgrade()(address,uint96)" 2>/dev/null))

PLANNED_WARM_STORAGE_IMPLEMENTATION_ADDRESS=${UPGRADE_PLAN[0]}
AFTER_EPOCH=${UPGRADE_PLAN[1]}

if [ "$PLANNED_WARM_STORAGE_IMPLEMENTATION_ADDRESS" != "$NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS" ]; then
  echo "NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS ($NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS) != planned ($PLANNED_WARM_STORAGE_IMPLEMENTATION_ADDRESS)"
  exit 1
else
  echo "Upgrade plan matches ($NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS)"
fi

CURRENT_EPOCH=$(cast block-number 2>/dev/null)

if [ "$CURRENT_EPOCH" -lt "$AFTER_EPOCH" ]; then
  echo "Not time yet ($CURRENT_EPOCH < $AFTER_EPOCH)"
  exit 1
else
  echo "Upgrade ready ($CURRENT_EPOCH > $AFTER_EPOCH)"
fi

if [ -n "$NEW_WARM_STORAGE_VIEW_ADDRESS" ]; then
  echo "Using provided view contract address: $NEW_WARM_STORAGE_VIEW_ADDRESS"
  MIGRATE_DATA=$(cast calldata "migrate(address)" "$NEW_WARM_STORAGE_VIEW_ADDRESS")
else
  echo "Keeping previous view contract address ($WARM_STORAGE_VIEW_ADDRESS)"
  MIGRATE_DATA=$(cast calldata "migrate(address)" "0x0000000000000000000000000000000000000000")
fi

# Call upgradeToAndCall on the proxy with migrate function
echo "Upgrading proxy and calling migrate..."
TX_HASH=$(cast send "$WARM_STORAGE_PROXY_ADDRESS" "upgradeToAndCall(address,bytes)" "$NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS" "$MIGRATE_DATA" \
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
NEW_IMPL=$(cast rpc eth_getStorageAt "$WARM_STORAGE_PROXY_ADDRESS" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc latest | sed 's/"//g' | sed 's/0x000000000000000000000000/0x/')

# Compare to lowercase
export EXPECTED_IMPL=$(echo $NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS | tr '[:upper:]' '[:lower:]')

if [ "$NEW_IMPL" = "$EXPECTED_IMPL" ]; then
    echo "✅ Upgrade successful! Proxy now points to: $NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS"
else
    echo "⚠️  Warning: Could not verify upgrade. Please check manually."
    echo "Expected: $NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS"
    echo "Got: $NEW_IMPL"
fi
