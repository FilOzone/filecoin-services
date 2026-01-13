#!/bin/bash

# announce-planned-upgrade.sh: Completes a pending upgrade
# Required args: ETH_RPC_URL, FWSS_PROXY_ADDRESS, ETH_KEYSTORE, PASSWORD, NEW_FWSS_IMPLEMENTATION_ADDRESS, AFTER_EPOCH

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

if [ -z "$NEW_FWSS_IMPLEMENTATION_ADDRESS" ]; then
  echo "NEW_FWSS_IMPLEMENTATION_ADDRESS is not set"
  exit 1
fi

if [ -z "$AFTER_EPOCH" ]; then
  echo "AFTER_EPOCH is not set"
  exit 1
fi

CURRENT_EPOCH=$(cast block-number 2>/dev/null)

if [ "$CURRENT_EPOCH" -gt "$AFTER_EPOCH" ]; then
  echo "Already past AFTER_EPOCH ($CURRENT_EPOCH > $AFTER_EPOCH)"
  exit 1
else
  echo "Announcing planned upgrade after $(($AFTER_EPOCH - $CURRENT_EPOCH)) epochs"
fi


ADDR=$(cast wallet address --password "$PASSWORD")
echo "Sending announcement from owner address: $ADDR"

# Get current nonce
NONCE=$(cast nonce "$ADDR")

if [ -z "$FWSS_PROXY_ADDRESS" ]; then
  echo "Error: FWSS_PROXY_ADDRESS is not set"
  exit 1
fi

PROXY_OWNER=$(cast call -f 0x0000000000000000000000000000000000000000 "$FWSS_PROXY_ADDRESS" "owner()(address)" 2>/dev/null)
if [ "$PROXY_OWNER" != "$ADDR" ]; then
  echo "Supplied ETH_KEYSTORE ($ADDR) is not the proxy owner ($PROXY_OWNER)."
  exit 1
fi

TX_HASH=$(cast send "$FWSS_PROXY_ADDRESS" "announcePlannedUpgrade((address,uint96))" "($NEW_FWSS_IMPLEMENTATION_ADDRESS,$AFTER_EPOCH)" \
  --password "$PASSWORD" \
  --nonce "$NONCE" \
  --json | jq -r '.transactionHash')

if [ -z "$TX_HASH" ]; then
  echo "Error: Failed to send announcePlannedUpgrade transaction"
  exit 1
fi

echo "announcePlannedUpgrade transaction sent: $TX_HASH"
