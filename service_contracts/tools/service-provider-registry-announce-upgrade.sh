#!/bin/bash

set -o pipefail

# Announces a ServiceProviderRegistry implementation upgrade.
#
# Required:
#   ETH_RPC_URL
#   SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS
#   NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS
#   ANNOUNCEMENT_MODE=legacy|delay
# Required in legacy mode (v1.1.0 -> v1.2.0 bootstrap):
#   AFTER_EPOCH
# Required in delay mode:
#   UPGRADE_DELAY_EPOCHS
# Required for direct send (CALLDATA_ONLY=false):
#   ETH_KEYSTORE, PASSWORD
# Optional:
#   CALLDATA_ONLY=true|false (default: false)
#   VERIFY_ANNOUNCEMENT_ONLY=true|false (default: false)
#   ANNOUNCE_TX_HASH (required to verify delay-mode execution)
#   ALLOW_REPLACE_PENDING_UPGRADE=true|false (default: false)
#   EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION
#     (default: 1.1.0 in legacy mode, 1.2.0 in delay mode)

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/multisig.sh"

CALLDATA_ONLY="${CALLDATA_ONLY:-false}"
VERIFY_ANNOUNCEMENT_ONLY="${VERIFY_ANNOUNCEMENT_ONLY:-false}"
ALLOW_REPLACE_PENDING_UPGRADE="${ALLOW_REPLACE_PENDING_UPGRADE:-false}"
ANNOUNCEMENT_MODE="${ANNOUNCEMENT_MODE:-}"
EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION="${EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION:-1.2.0}"
EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION="${EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION:-}"
EXPECTED_CURRENT_REINITIALIZER_VERSION="${EXPECTED_CURRENT_REINITIALIZER_VERSION:-}"
IMPLEMENTATION_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"
MAX_UINT96="79228162514264337593543950335"
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

is_uint96() {
  is_non_negative_integer "$1" && decimal_lte "$1" "$MAX_UINT96"
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
    echo "Error: Failed to read nextUpgrade() from the ServiceProviderRegistry proxy" >&2
    return 1
  fi

  local values=($output)
  if [ "${#values[@]}" -ne 2 ] || ! is_address "${values[0]}" || ! is_uint96 "${values[1]}"; then
    echo "Error: Invalid nextUpgrade() response: $output" >&2
    return 1
  fi

  PENDING_IMPLEMENTATION="${values[0]}"
  PENDING_AFTER_EPOCH="${values[1]}"
}

receipt_block_number() {
  local block_number
  if ! block_number=$(cast receipt --rpc-url "$ETH_RPC_URL" "$1" blockNumber 2>/dev/null); then
    return 1
  fi
  if [[ "$block_number" =~ ^0x[0-9a-fA-F]+$ ]]; then
    block_number=$(cast to-base "$block_number" 10)
  fi
  if ! is_shell_integer "$block_number"; then
    return 1
  fi
  printf '%s\n' "$block_number"
}

verify_pending_plan() {
  if ! read_pending_plan; then
    return 1
  fi

  if [ "$(normalize_address "$PENDING_IMPLEMENTATION")" != \
    "$(normalize_address "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS")" ]; then
    echo "Error: Pending implementation $PENDING_IMPLEMENTATION does not match expected $NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
    return 1
  fi

  local expected_after_epoch
  if [ "$ANNOUNCEMENT_MODE" = "legacy" ]; then
    expected_after_epoch="$AFTER_EPOCH"
  else
    if [[ ! "${ANNOUNCE_TX_HASH:-}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
      echo "Error: ANNOUNCE_TX_HASH is required to verify a delay-mode announcement"
      return 1
    fi
    local announce_epoch
    if ! announce_epoch=$(receipt_block_number "$ANNOUNCE_TX_HASH"); then
      echo "Error: Failed to read the announcement transaction block number"
      return 1
    fi
    local effective_delay="$UPGRADE_DELAY_EPOCHS"
    if [ "$effective_delay" -eq 0 ]; then
      effective_delay=1
    fi
    if [ "$announce_epoch" -gt $((MAX_SHELL_INTEGER - effective_delay)) ]; then
      echo "Error: Announcement epoch plus requested delay exceeds this tool's arithmetic range"
      return 1
    fi
    expected_after_epoch=$((announce_epoch + effective_delay))
  fi

  if [ "$PENDING_AFTER_EPOCH" != "$expected_after_epoch" ]; then
    echo "Error: Pending afterEpoch $PENDING_AFTER_EPOCH does not match expected $expected_after_epoch"
    return 1
  fi

  echo "Verified pending ServiceProviderRegistry upgrade"
  echo "  Implementation: $PENDING_IMPLEMENTATION"
  echo "  Observed afterEpoch: $PENDING_AFTER_EPOCH"
}

for bool_value in "$CALLDATA_ONLY" "$VERIFY_ANNOUNCEMENT_ONLY" "$ALLOW_REPLACE_PENDING_UPGRADE"; do
  if ! is_boolean "$bool_value"; then
    echo "Error: Boolean options must be 'true' or 'false'"
    exit 1
  fi
done

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi
if ! is_address "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"; then
  echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not a valid address"
  exit 1
fi
if ! is_address "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"; then
  echo "Error: NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS is not a valid address"
  exit 1
fi

case "$ANNOUNCEMENT_MODE" in
  legacy)
    EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION="${EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION:-1.1.0}"
    if ! is_uint96 "${AFTER_EPOCH:-}" || ! is_shell_integer "$AFTER_EPOCH"; then
      echo "Error: AFTER_EPOCH must be a non-negative base-10 uint96 within this tool's arithmetic range"
      exit 1
    fi
    if [ -n "${UPGRADE_DELAY_EPOCHS:-}" ]; then
      echo "Error: UPGRADE_DELAY_EPOCHS is only valid with ANNOUNCEMENT_MODE=delay"
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
    if [ "$VERIFY_ANNOUNCEMENT_ONLY" != "true" ] && \
      [ "$AFTER_EPOCH" -le "$CURRENT_EPOCH" ]; then
      echo "Error: Legacy AFTER_EPOCH must be in the future ($AFTER_EPOCH <= $CURRENT_EPOCH)"
      exit 1
    fi
    CALL_SIGNATURE='announcePlannedUpgrade((address,uint96))'
    CALL_ARGS=("($NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS,$AFTER_EPOCH)")
    ;;
  delay)
    EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION="${EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION:-1.2.0}"
    if ! is_uint96 "${UPGRADE_DELAY_EPOCHS:-}" || ! is_shell_integer "$UPGRADE_DELAY_EPOCHS"; then
      echo "Error: UPGRADE_DELAY_EPOCHS must be a non-negative base-10 uint96 within this tool's arithmetic range"
      exit 1
    fi
    if [ -n "${AFTER_EPOCH:-}" ]; then
      echo "Error: AFTER_EPOCH is only valid with ANNOUNCEMENT_MODE=legacy"
      exit 1
    fi
    CALL_SIGNATURE='announceUpgradePlan(address,uint96)'
    CALL_ARGS=("$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" "$UPGRADE_DELAY_EPOCHS")
    ;;
  *)
    echo "Error: ANNOUNCEMENT_MODE must be explicitly set to 'legacy' or 'delay'"
    exit 1
    ;;
esac

if [ -z "$EXPECTED_CURRENT_REINITIALIZER_VERSION" ] && \
  [ "$ANNOUNCEMENT_MODE" = "legacy" ]; then
  EXPECTED_CURRENT_REINITIALIZER_VERSION=2
fi

if ! CURRENT_PROXY_IMPLEMENTATION=$(read_implementation_slot \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"); then
  echo "Error: Failed to read the current ServiceProviderRegistry implementation"
  exit 1
fi
if ! CURRENT_PROXY_VERSION=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" 'VERSION()(string)' 2>/dev/null); then
  echo "Error: Failed to read VERSION() from the current ServiceProviderRegistry proxy"
  exit 1
fi
CURRENT_PROXY_VERSION=$(printf '%s' "$CURRENT_PROXY_VERSION" | tr -d '"')
if [ "$CURRENT_PROXY_VERSION" != "$EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION" ]; then
  echo "Error: Current ServiceProviderRegistry VERSION() is $CURRENT_PROXY_VERSION; expected $EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION for $ANNOUNCEMENT_MODE mode"
  exit 1
fi
if ! CURRENT_PROXY_CODE=$(cast code --rpc-url "$ETH_RPC_URL" \
  "$CURRENT_PROXY_IMPLEMENTATION" 2>/dev/null); then
  echo "Error: Failed to read the current ServiceProviderRegistry implementation bytecode"
  exit 1
fi
if ! SELECTOR=$(cast sig "$CALL_SIGNATURE"); then
  echo "Error: Failed to derive the selector for $CALL_SIGNATURE"
  exit 1
fi
if [[ ! "$SELECTOR" =~ ^0x[0-9a-fA-F]{8}$ ]]; then
  echo "Error: Invalid selector returned for $CALL_SIGNATURE: $SELECTOR"
  exit 1
fi
SELECTOR_HEX="${SELECTOR#0x}"
if [[ "$(printf '%s' "$CURRENT_PROXY_CODE" | tr '[:upper:]' '[:lower:]')" != \
  *"$(printf '%s' "$SELECTOR_HEX" | tr '[:upper:]' '[:lower:]')"* ]]; then
  echo "Error: Current ServiceProviderRegistry implementation does not expose $CALL_SIGNATURE"
  exit 1
fi

if ! NEW_IMPLEMENTATION_CODE=$(cast code --rpc-url "$ETH_RPC_URL" \
  "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" 2>/dev/null); then
  echo "Error: Failed to read new implementation bytecode"
  exit 1
fi
if [ "$NEW_IMPLEMENTATION_CODE" = "0x" ]; then
  echo "Error: New implementation address has no bytecode"
  exit 1
fi
NEW_IMPLEMENTATION_CODE_BYTES=$(((${#NEW_IMPLEMENTATION_CODE} - 2) / 2))
if [ "$NEW_IMPLEMENTATION_CODE_BYTES" -le 3000 ]; then
  echo "Error: New implementation bytecode is too small for the on-chain upgrade guard"
  exit 1
fi

if ! NEW_IMPLEMENTATION_VERSION=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" 'VERSION()(string)' 2>/dev/null); then
  echo "Error: Failed to read VERSION() from the new implementation"
  exit 1
fi
NEW_IMPLEMENTATION_VERSION=$(printf '%s' "$NEW_IMPLEMENTATION_VERSION" | tr -d '"')
if [ "$NEW_IMPLEMENTATION_VERSION" != "$EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION" ]; then
  echo "Error: New implementation VERSION() is $NEW_IMPLEMENTATION_VERSION; expected $EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION"
  exit 1
fi

if ! PROXIABLE_UUID=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" 'proxiableUUID()(bytes32)' 2>/dev/null); then
  echo "Error: New implementation does not expose proxiableUUID()"
  exit 1
fi
if [ "$(printf '%s' "$PROXIABLE_UUID" | tr '[:upper:]' '[:lower:]')" != "$IMPLEMENTATION_SLOT" ]; then
  echo "Error: New implementation returned unexpected proxiableUUID(): $PROXIABLE_UUID"
  exit 1
fi

if ! CURRENT_REINITIALIZER_VERSION=$("$SCRIPT_DIR/get-initialized-counter.sh" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"); then
  echo "Error: Failed to read the current ServiceProviderRegistry initializer counter"
  exit 1
fi
if [ -n "$EXPECTED_CURRENT_REINITIALIZER_VERSION" ] && \
  [ "$CURRENT_REINITIALIZER_VERSION" != "$EXPECTED_CURRENT_REINITIALIZER_VERSION" ]; then
  echo "Error: Current initializer counter is $CURRENT_REINITIALIZER_VERSION; expected $EXPECTED_CURRENT_REINITIALIZER_VERSION"
  exit 1
fi

if [ "$VERIFY_ANNOUNCEMENT_ONLY" = "true" ]; then
  verify_pending_plan
  exit $?
fi

if ! read_pending_plan; then
  exit 1
fi
if [ "$(normalize_address "$PENDING_IMPLEMENTATION")" != "$ZERO_ADDRESS" ]; then
  if [ "$ALLOW_REPLACE_PENDING_UPGRADE" != "true" ]; then
    echo "Error: A pending upgrade already exists: $PENDING_IMPLEMENTATION after epoch $PENDING_AFTER_EPOCH"
    echo "Set ALLOW_REPLACE_PENDING_UPGRADE=true only after recording the superseded announcement."
    exit 1
  fi
  echo "Warning: This announcement will replace $PENDING_IMPLEMENTATION after epoch $PENDING_AFTER_EPOCH"
fi

if ! PROXY_OWNER=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" 'owner()(address)' 2>/dev/null); then
  echo "Error: Failed to read the ServiceProviderRegistry proxy owner"
  exit 1
fi
if ! is_address "$PROXY_OWNER"; then
  echo "Error: ServiceProviderRegistry proxy returned an invalid owner: $PROXY_OWNER"
  exit 1
fi

# Simulate from the proxy owner before producing calldata. This catches an
# unsupported selector, an invalid implementation, and delay arithmetic that
# would revert when the Safe transaction executes.
if ! cast call --rpc-url "$ETH_RPC_URL" --from "$PROXY_OWNER" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "$CALL_SIGNATURE" "${CALL_ARGS[@]}" >/dev/null; then
  echo "Error: $CALL_SIGNATURE would revert against the current ServiceProviderRegistry proxy"
  if [ "$ANNOUNCEMENT_MODE" = "delay" ]; then
    echo "Use ANNOUNCEMENT_MODE=legacy while the deployed implementation lacks announceUpgradePlan(address,uint96)"
  fi
  exit 1
fi

if ! CALLDATA=$(cast calldata "$CALL_SIGNATURE" "${CALL_ARGS[@]}"); then
  echo "Error: Failed to encode $CALL_SIGNATURE calldata"
  exit 1
fi

echo "ServiceProviderRegistry announcement mode: $ANNOUNCEMENT_MODE"
echo "Current proxy implementation: $CURRENT_PROXY_IMPLEMENTATION"
echo "Target implementation: $NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
if [ "$ANNOUNCEMENT_MODE" = "legacy" ]; then
  echo "Absolute afterEpoch: $AFTER_EPOCH"
else
  echo "Requested delay: $UPGRADE_DELAY_EPOCHS epochs"
  if [ "$UPGRADE_DELAY_EPOCHS" -eq 0 ]; then
    echo "The contract will enforce an effective delay of one epoch"
  fi
fi

if [ "$CALLDATA_ONLY" = "true" ]; then
  print_safe_transaction "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "$CALL_SIGNATURE" "$CALLDATA"
  echo
  echo "After the Safe transaction executes, verify the on-chain plan with:"
  echo "  ANNOUNCE_TX_HASH=0x... VERIFY_ANNOUNCEMENT_ONLY=true CALLDATA_ONLY=true $0"
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
if [ "$(normalize_address "$PROXY_OWNER")" != "$(normalize_address "$ADDR")" ]; then
  echo "Error: ETH_KEYSTORE address $ADDR is not proxy owner $PROXY_OWNER"
  exit 1
fi
if ! NONCE=$(cast nonce --rpc-url "$ETH_RPC_URL" "$ADDR"); then
  echo "Error: Failed to read the sender nonce"
  exit 1
fi

if ! TX_HASH=$(cast send --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "$CALL_SIGNATURE" "${CALL_ARGS[@]}" \
  --keystore "$ETH_KEYSTORE" \
  --password "$PASSWORD" \
  --nonce "$NONCE" \
  --json | jq -er '.transactionHash | select(type == "string" and length > 0)'); then
  echo "Error: Failed to send $CALL_SIGNATURE"
  exit 1
fi

echo "$CALL_SIGNATURE transaction sent: $TX_HASH"
if ! cast receipt --rpc-url "$ETH_RPC_URL" "$TX_HASH" --confirmations 1 >/dev/null; then
  echo "Error: Failed waiting for the announcement transaction receipt"
  exit 1
fi
ANNOUNCE_TX_HASH="$TX_HASH"
verify_pending_plan
