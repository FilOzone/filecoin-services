#!/bin/bash

set -o pipefail

# warm-storage-announce-upgrade.sh: Announces a planned FWSS upgrade
# Required args: ETH_RPC_URL, FWSS_PROXY_ADDRESS, NEW_FWSS_IMPLEMENTATION_ADDRESS
# Required in the default delay mode: UPGRADE_DELAY_EPOCHS
# Required for the v1.3.0 -> v1.3.1 bootstrap: ANNOUNCEMENT_MODE=legacy, AFTER_EPOCH
# Required for direct send (not CALLDATA_ONLY): ETH_KEYSTORE, PASSWORD
# Optional: CALLDATA_ONLY=true to generate calldata for Safe multisig instead of sending;
#           ANNOUNCEMENT_MODE=delay|legacy (default: delay)

# Get script directory and source deployments.sh
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"
source "$SCRIPT_DIR/multisig.sh"

CALLDATA_ONLY="${CALLDATA_ONLY:-false}"
ANNOUNCEMENT_MODE="${ANNOUNCEMENT_MODE:-delay}"

case "$CALLDATA_ONLY" in
  true | false) ;;
  *)
    echo "Error: CALLDATA_ONLY must be 'true' or 'false'"
    exit 1
    ;;
esac

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
  CHAIN=$(cast chain-id --rpc-url "$ETH_RPC_URL")
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

if [ -z "$NEW_FWSS_IMPLEMENTATION_ADDRESS" ]; then
  echo "NEW_FWSS_IMPLEMENTATION_ADDRESS is not set"
  exit 1
fi

if [ -z "$FWSS_PROXY_ADDRESS" ]; then
  echo "Error: FWSS_PROXY_ADDRESS is not set"
  exit 1
fi

is_non_negative_integer() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

CALL_SIGNATURE=""
CALL_ARGS=()

case "$ANNOUNCEMENT_MODE" in
  delay)
    if [ -z "$UPGRADE_DELAY_EPOCHS" ]; then
      echo "Error: UPGRADE_DELAY_EPOCHS is not set"
      exit 1
    fi
    if ! is_non_negative_integer "$UPGRADE_DELAY_EPOCHS"; then
      echo "Error: UPGRADE_DELAY_EPOCHS must be a non-negative base-10 integer without leading zeros"
      exit 1
    fi
    if [ -n "$AFTER_EPOCH" ]; then
      echo "Error: AFTER_EPOCH is only valid with ANNOUNCEMENT_MODE=legacy"
      exit 1
    fi

    CALL_SIGNATURE="announceUpgradePlan(address,uint96)"
    CALL_ARGS=("$NEW_FWSS_IMPLEMENTATION_ADDRESS" "$UPGRADE_DELAY_EPOCHS")
    echo "Announcing upgrade with a requested delay of $UPGRADE_DELAY_EPOCHS epochs"
    echo "Delay mode requires the deployed FWSS implementation to expose announceUpgradePlan"
    if [ "$UPGRADE_DELAY_EPOCHS" = "0" ]; then
      echo "The contract will enforce a minimum delay of one epoch"
    fi
    ;;
  legacy)
    # Bootstrap only: FWSS v1.3.0 predates announceUpgradePlan, so the v1.3.1
    # rollout cannot use delay mode. Deprecate this branch after v1.3.1 is live on
    # both networks; remove it once rollback to v1.3.0 is retired (checklist Phase 5).
    if [ -z "$AFTER_EPOCH" ]; then
      echo "Error: AFTER_EPOCH is not set for ANNOUNCEMENT_MODE=legacy"
      exit 1
    fi
    if ! is_non_negative_integer "$AFTER_EPOCH"; then
      echo "Error: AFTER_EPOCH must be a non-negative base-10 integer without leading zeros"
      exit 1
    fi
    if [ -n "$UPGRADE_DELAY_EPOCHS" ]; then
      echo "Error: UPGRADE_DELAY_EPOCHS is not valid with ANNOUNCEMENT_MODE=legacy"
      exit 1
    fi

    CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL" 2>/dev/null)
    if ! is_non_negative_integer "$CURRENT_EPOCH"; then
      echo "Error: Failed to read the current epoch"
      exit 1
    fi
    if [ "$CURRENT_EPOCH" -ge "$AFTER_EPOCH" ]; then
      echo "Error: legacy AFTER_EPOCH must be in the future ($CURRENT_EPOCH >= $AFTER_EPOCH)"
      exit 1
    fi

    CALL_SIGNATURE="announcePlannedUpgrade((address,uint96))"
    CALL_ARGS=("($NEW_FWSS_IMPLEMENTATION_ADDRESS,$AFTER_EPOCH)")
    echo "Using v1.3.0 bootstrap legacy mode; announcing upgrade after $((AFTER_EPOCH - CURRENT_EPOCH)) epochs"
    echo "Ensure AFTER_EPOCH includes enough Safe-signing buffer; legacy calldata can expire before execution"
    ;;
  *)
    echo "Error: ANNOUNCEMENT_MODE must be 'delay' or 'legacy'"
    exit 1
    ;;
esac

ZERO_ADDRESS="0x0000000000000000000000000000000000000000"
if ! PROXY_OWNER=$(cast call --rpc-url "$ETH_RPC_URL" --from "$ZERO_ADDRESS" \
  "$FWSS_PROXY_ADDRESS" "owner()(address)" 2>/dev/null); then
  echo "Error: Failed to read the FWSS proxy owner"
  exit 1
fi

# Simulate from the owner before producing calldata. This catches unsupported
# announcement modes, invalid implementation addresses, and delay overflow.
if ! cast call --rpc-url "$ETH_RPC_URL" --from "$PROXY_OWNER" \
  "$FWSS_PROXY_ADDRESS" "$CALL_SIGNATURE" "${CALL_ARGS[@]}" >/dev/null; then
  echo "Error: $CALL_SIGNATURE would revert against the current FWSS proxy"
  if [ "$ANNOUNCEMENT_MODE" = "delay" ]; then
    echo "For the FWSS v1.3.0 -> v1.3.1 bootstrap, rerun with ANNOUNCEMENT_MODE=legacy"
  fi
  exit 1
fi

if [ "$CALLDATA_ONLY" = "true" ]; then
  if ! CALLDATA=$(cast calldata "$CALL_SIGNATURE" "${CALL_ARGS[@]}"); then
    echo "Error: Failed to encode $CALL_SIGNATURE calldata"
    exit 1
  fi
  print_safe_transaction "$FWSS_PROXY_ADDRESS" "$CALL_SIGNATURE" "$CALLDATA"
  exit 0
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Sending announcement from owner address: $ADDR"

# Get current nonce
NONCE=$(cast nonce "$ADDR")

if [ "$PROXY_OWNER" != "$ADDR" ]; then
  echo "Supplied ETH_KEYSTORE ($ADDR) is not the proxy owner ($PROXY_OWNER)."
  exit 1
fi

if ! TX_HASH=$(cast send "$FWSS_PROXY_ADDRESS" "$CALL_SIGNATURE" "${CALL_ARGS[@]}" \
  --password "$PASSWORD" \
  --nonce "$NONCE" \
  --json | jq -er '.transactionHash | select(type == "string" and length > 0)'); then
  echo "Error: Failed to send $CALL_SIGNATURE transaction"
  exit 1
fi

echo "$CALL_SIGNATURE transaction sent: $TX_HASH"
