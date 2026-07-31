#!/bin/bash

set -o pipefail

# Executes an announced ServiceProviderRegistry upgrade.
#
# Required:
#   ETH_RPC_URL
#   SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS
#   NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS
#   NEW_VERSION=1.2.0
# Required for direct send (CALLDATA_ONLY=false):
#   ETH_KEYSTORE, PASSWORD
# Optional:
#   CHAIN
#   CALLDATA_ONLY=true|false (default: false)
#   VERIFY_EXECUTION_ONLY=true|false (default: false)
#   UPDATE_DEPLOYMENTS_AFTER_VERIFICATION=true|false (default: false)

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"
source "$SCRIPT_DIR/multisig.sh"

CALLDATA_ONLY="${CALLDATA_ONLY:-false}"
VERIFY_EXECUTION_ONLY="${VERIFY_EXECUTION_ONLY:-false}"
UPDATE_DEPLOYMENTS_AFTER_VERIFICATION="${UPDATE_DEPLOYMENTS_AFTER_VERIFICATION:-false}"
EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION="${EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION:-1.2.0}"
EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION="${EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION:-1.1.0}"
EXPECTED_CURRENT_REINITIALIZER_VERSION="${EXPECTED_CURRENT_REINITIALIZER_VERSION:-2}"
EXPECTED_NEW_REINITIALIZER_VERSION="${EXPECTED_NEW_REINITIALIZER_VERSION:-3}"
EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER="${EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER:-0x6386622B4915B027900d65560b0ab84F8a1ff2AA}"
IMPLEMENTATION_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"
MAX_SHELL_INTEGER="9223372036854775807"

is_boolean() {
  [ "$1" = "true" ] || [ "$1" = "false" ]
}

is_address() {
  [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

normalize_address() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_non_negative_integer() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

decimal_lte() {
  local left="$1"
  local right="$2"
  if [ "${#left}" -lt "${#right}" ]; then
    return 0
  fi
  if [ "${#left}" -gt "${#right}" ]; then
    return 1
  fi
  [[ "$left" == "$right" || "$left" < "$right" ]]
}

is_shell_integer() {
  is_non_negative_integer "$1" && decimal_lte "$1" "$MAX_SHELL_INTEGER"
}

read_implementation_slot() {
  local proxy_address="$1"
  local raw_slot
  if ! raw_slot=$(cast rpc --rpc-url "$ETH_RPC_URL" \
    eth_getStorageAt "$proxy_address" "$IMPLEMENTATION_SLOT" latest 2>/dev/null); then
    return 1
  fi
  raw_slot=$(printf '%s' "$raw_slot" | tr -d '"')
  if [[ ! "$raw_slot" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    return 1
  fi
  printf '0x%s\n' "${raw_slot: -40}"
}

read_pending_plan() {
  local output
  if ! output=$(cast call --rpc-url "$ETH_RPC_URL" \
    "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    'nextUpgrade()(address,uint96)' 2>/dev/null); then
    echo "Error: Failed to read nextUpgrade(); refusing to fall back to a one-step upgrade" >&2
    return 1
  fi

  local values=($output)
  if [ "${#values[@]}" -ne 2 ] || ! is_address "${values[0]}" || \
    ! is_shell_integer "${values[1]}"; then
    echo "Error: Invalid nextUpgrade() response: $output" >&2
    return 1
  fi

  PENDING_IMPLEMENTATION="${values[0]}"
  PENDING_AFTER_EPOCH="${values[1]}"
}

verify_new_implementation() {
  local implementation_code implementation_version proxiable_uuid

  if ! implementation_code=$(cast code --rpc-url "$ETH_RPC_URL" \
    "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" 2>/dev/null); then
    echo "Error: Failed to read new implementation bytecode"
    return 1
  fi
  if [ "$implementation_code" = "0x" ]; then
    echo "Error: New implementation address has no bytecode"
    return 1
  fi

  if ! implementation_version=$(cast call --rpc-url "$ETH_RPC_URL" \
    "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" 'VERSION()(string)' 2>/dev/null); then
    echo "Error: Failed to read VERSION() from the new implementation"
    return 1
  fi
  implementation_version=$(printf '%s' "$implementation_version" | tr -d '"')
  if [ "$implementation_version" != "$EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION" ]; then
    echo "Error: New implementation VERSION() is $implementation_version; expected $EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION"
    return 1
  fi

  if ! proxiable_uuid=$(cast call --rpc-url "$ETH_RPC_URL" \
    "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" 'proxiableUUID()(bytes32)' 2>/dev/null); then
    echo "Error: New implementation does not expose proxiableUUID()"
    return 1
  fi
  if [ "$(printf '%s' "$proxiable_uuid" | tr '[:upper:]' '[:lower:]')" != "$IMPLEMENTATION_SLOT" ]; then
    echo "Error: New implementation returned unexpected proxiableUUID(): $proxiable_uuid"
    return 1
  fi
}

verify_completed_upgrade() {
  local actual_implementation actual_version actual_counter actual_owner

  if ! actual_implementation=$(read_implementation_slot \
    "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"); then
    echo "Error: Failed to read the post-upgrade implementation slot"
    return 1
  fi
  if [ "$(normalize_address "$actual_implementation")" != \
    "$(normalize_address "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS")" ]; then
    echo "Error: Implementation slot is $actual_implementation; expected $NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
    return 1
  fi

  if ! actual_version=$(cast call --rpc-url "$ETH_RPC_URL" \
    "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" 'VERSION()(string)' 2>/dev/null); then
    echo "Error: Failed to read post-upgrade VERSION()"
    return 1
  fi
  actual_version=$(printf '%s' "$actual_version" | tr -d '"')
  if [ "$actual_version" != "$EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION" ]; then
    echo "Error: Post-upgrade VERSION() is $actual_version; expected $EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION"
    return 1
  fi

  if ! read_pending_plan; then
    return 1
  fi
  if [ "$(normalize_address "$PENDING_IMPLEMENTATION")" != "$ZERO_ADDRESS" ] || \
    [ "$PENDING_AFTER_EPOCH" != "0" ]; then
    echo "Error: nextUpgrade() was not cleared: $PENDING_IMPLEMENTATION after epoch $PENDING_AFTER_EPOCH"
    return 1
  fi

  if ! actual_counter=$("$SCRIPT_DIR/get-initialized-counter.sh" \
    "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"); then
    echo "Error: Failed to read the post-upgrade initializer counter"
    return 1
  fi
  if [ "$actual_counter" != "$EXPECTED_NEW_REINITIALIZER_VERSION" ]; then
    echo "Error: Post-upgrade initializer counter is $actual_counter; expected $EXPECTED_NEW_REINITIALIZER_VERSION"
    return 1
  fi

  if ! actual_owner=$(cast call --rpc-url "$ETH_RPC_URL" \
    "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" 'owner()(address)' 2>/dev/null); then
    echo "Error: Failed to read the post-upgrade owner"
    return 1
  fi
  if [ "$(normalize_address "$actual_owner")" != \
    "$(normalize_address "$EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER")" ]; then
    echo "Error: Post-upgrade owner is $actual_owner; expected $EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER"
    return 1
  fi

  echo "Verified completed ServiceProviderRegistry upgrade"
  echo "  Implementation: $actual_implementation"
  echo "  VERSION(): $actual_version"
  echo "  Initializer counter: $actual_counter"
  echo "  nextUpgrade(): ($PENDING_IMPLEMENTATION, $PENDING_AFTER_EPOCH)"
  echo "  Owner: $actual_owner"

  if [ "$UPDATE_DEPLOYMENTS_AFTER_VERIFICATION" = "true" ]; then
    update_deployment_address "$CHAIN" \
      "SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" \
      "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
    update_deployment_metadata "$CHAIN"
    echo "Updated deployments.json after the live proxy switch was verified"
  else
    echo "deployments.json was not updated; use the post-switch follow-up PR flow"
  fi
}

for bool_value in "$CALLDATA_ONLY" "$VERIFY_EXECUTION_ONLY" "$UPDATE_DEPLOYMENTS_AFTER_VERIFICATION"; do
  if ! is_boolean "$bool_value"; then
    echo "Error: Boolean options must be 'true' or 'false'"
    exit 1
  fi
done

for counter_value in "$EXPECTED_CURRENT_REINITIALIZER_VERSION" "$EXPECTED_NEW_REINITIALIZER_VERSION"; do
  if ! is_shell_integer "$counter_value"; then
    echo "Error: Expected initializer counters must be non-negative base-10 integers within this tool's arithmetic range"
    exit 1
  fi
done

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

if [ -z "$CHAIN" ]; then
  if ! CHAIN=$(cast chain-id --rpc-url "$ETH_RPC_URL"); then
    echo "Error: Failed to detect chain ID from ETH_RPC_URL"
    exit 1
  fi
fi
if [[ ! "$CHAIN" =~ ^[0-9]+$ ]]; then
  echo "Error: CHAIN must be a base-10 integer"
  exit 1
fi

load_deployment_addresses "$CHAIN"

if ! is_address "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"; then
  echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not a valid address"
  exit 1
fi
if ! is_address "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"; then
  echo "Error: NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS is not a valid address"
  exit 1
fi
if ! is_address "$EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER"; then
  echo "Error: EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER is not a valid address"
  exit 1
fi

if [ -z "${NEW_VERSION:-}" ]; then
  echo "Error: NEW_VERSION must be explicitly set to 1.2.0"
  exit 1
fi
if [ "$NEW_VERSION" != "$EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION" ] || \
  [ "$NEW_VERSION" != "1.2.0" ]; then
  echo "Error: NEW_VERSION must be 1.2.0 for this rollout"
  exit 1
fi

if ! verify_new_implementation; then
  exit 1
fi

if [ "$VERIFY_EXECUTION_ONLY" = "true" ]; then
  verify_completed_upgrade
  exit $?
fi

if ! CURRENT_PROXY_VERSION=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" 'VERSION()(string)' 2>/dev/null); then
  echo "Error: Failed to read the current proxy VERSION()"
  exit 1
fi
CURRENT_PROXY_VERSION=$(printf '%s' "$CURRENT_PROXY_VERSION" | tr -d '"')
if [ "$CURRENT_PROXY_VERSION" != "$EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION" ]; then
  echo "Error: Current proxy VERSION() is $CURRENT_PROXY_VERSION; expected $EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION"
  exit 1
fi

if ! CURRENT_REINITIALIZER_VERSION=$("$SCRIPT_DIR/get-initialized-counter.sh" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"); then
  echo "Error: Failed to read the current initializer counter"
  exit 1
fi
if [ "$CURRENT_REINITIALIZER_VERSION" != "$EXPECTED_CURRENT_REINITIALIZER_VERSION" ]; then
  echo "Error: Current initializer counter is $CURRENT_REINITIALIZER_VERSION; expected $EXPECTED_CURRENT_REINITIALIZER_VERSION"
  exit 1
fi
if [ $((CURRENT_REINITIALIZER_VERSION + 1)) -ne "$EXPECTED_NEW_REINITIALIZER_VERSION" ]; then
  echo "Error: Expected new initializer counter is inconsistent with current live state"
  exit 1
fi

if ! read_pending_plan; then
  exit 1
fi
if [ "$(normalize_address "$PENDING_IMPLEMENTATION")" = "$ZERO_ADDRESS" ]; then
  echo "Error: No pending ServiceProviderRegistry upgrade is announced"
  exit 1
fi
if [ "$(normalize_address "$PENDING_IMPLEMENTATION")" != \
  "$(normalize_address "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS")" ]; then
  echo "Error: Pending implementation $PENDING_IMPLEMENTATION does not match expected $NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
  exit 1
fi
if ! is_shell_integer "$PENDING_AFTER_EPOCH"; then
  echo "Error: Pending afterEpoch is invalid: $PENDING_AFTER_EPOCH"
  exit 1
fi

if ! CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL" 2>/dev/null); then
  echo "Error: Failed to read the current epoch"
  exit 1
fi
if ! is_shell_integer "$CURRENT_EPOCH"; then
  echo "Error: RPC returned an invalid current epoch: $CURRENT_EPOCH"
  exit 1
fi
if [ "$CURRENT_EPOCH" -lt "$PENDING_AFTER_EPOCH" ]; then
  echo "Error: Upgrade is not ready ($CURRENT_EPOCH < $PENDING_AFTER_EPOCH)"
  exit 1
fi

if ! MIGRATE_DATA=$(cast calldata 'migrate(string)' "$NEW_VERSION"); then
  echo "Error: Failed to encode migrate(string) calldata"
  exit 1
fi
if ! CALLDATA=$(cast calldata 'upgradeToAndCall(address,bytes)' \
  "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" "$MIGRATE_DATA"); then
  echo "Error: Failed to encode upgradeToAndCall(address,bytes) calldata"
  exit 1
fi

echo "ServiceProviderRegistry upgrade is ready"
echo "  Proxy: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "  Planned implementation: $PENDING_IMPLEMENTATION"
echo "  Observed afterEpoch: $PENDING_AFTER_EPOCH"
echo "  Current epoch: $CURRENT_EPOCH"
echo "  Migration version: $NEW_VERSION"
echo "  Expected initializer transition: $CURRENT_REINITIALIZER_VERSION -> $EXPECTED_NEW_REINITIALIZER_VERSION"

if [ "$CALLDATA_ONLY" = "true" ]; then
  print_safe_transaction "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    'upgradeToAndCall(address,bytes)' "$CALLDATA"
  echo
  echo "After the Safe transaction executes, verify the proxy with:"
  echo "  VERIFY_EXECUTION_ONLY=true CALLDATA_ONLY=true $0"
  exit 0
fi

if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi
if [ -z "$PASSWORD" ]; then
  echo "Error: PASSWORD is not set"
  exit 1
fi

if ! ADDR=$(cast wallet address --keystore "$ETH_KEYSTORE" --password "$PASSWORD"); then
  echo "Error: Failed to read the sender address from ETH_KEYSTORE"
  exit 1
fi
if [ "$(normalize_address "$ADDR")" != \
  "$(normalize_address "$EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER")" ]; then
  echo "Error: ETH_KEYSTORE address $ADDR is not expected owner $EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER"
  exit 1
fi
if ! ACTUAL_OWNER=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" 'owner()(address)' 2>/dev/null); then
  echo "Error: Failed to read the current proxy owner"
  exit 1
fi
if [ "$(normalize_address "$ACTUAL_OWNER")" != \
  "$(normalize_address "$EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER")" ]; then
  echo "Error: Current proxy owner is $ACTUAL_OWNER; expected $EXPECTED_SERVICE_PROVIDER_REGISTRY_OWNER"
  exit 1
fi
if ! NONCE=$(cast nonce --rpc-url "$ETH_RPC_URL" "$ADDR"); then
  echo "Error: Failed to read the sender nonce"
  exit 1
fi

if ! TX_HASH=$(cast send --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
  'upgradeToAndCall(address,bytes)' \
  "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" \
  "$MIGRATE_DATA" \
  --keystore "$ETH_KEYSTORE" \
  --password "$PASSWORD" \
  --nonce "$NONCE" \
  --json | jq -er '.transactionHash | select(type == "string" and length > 0)'); then
  echo "Error: Failed to send upgradeToAndCall(address,bytes)"
  exit 1
fi

echo "upgradeToAndCall transaction sent: $TX_HASH"
if ! cast receipt --rpc-url "$ETH_RPC_URL" "$TX_HASH" --confirmations 1 >/dev/null; then
  echo "Error: Failed waiting for the upgrade transaction receipt"
  exit 1
fi
verify_completed_upgrade
