#!/bin/bash

# warm-storage-manage-approved-provider.sh: Inspect and manage FWSS approved provider IDs
#
# Supported actions:
#   ACTION=list                  - Print the current approved provider list with indexes
#   ACTION=status                - Print current owner/view info and optional provider status
#   ACTION=add                   - Add or propose addApprovedProvider(uint256)
#   ACTION=remove                - Remove or propose removeApprovedProvider(uint256,uint256)
#
# Required:
#   ETH_RPC_URL
#   ACTION
#
# Required for add/remove:
#   Either PROVIDER_ID or SERVICE_PROVIDER_ADDRESS
#
# Optional:
#   CHAIN
#   FWSS_PROXY_ADDRESS
#   FWSS_VIEW_ADDRESS
#   SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS
#   CALLDATA_ONLY=true           - Print Safe calldata instead of sending/proposing
#   PROPOSE_TO_SAFE=true         - Use Filecoin Safe Transaction Service instead of direct send
#   DRY_RUN=true                 - With PROPOSE_TO_SAFE=true, validate and print proposal details only
#   INDEX                        - Optional override for ACTION=remove; auto-resolved if unset
#   SAFE_NONCE                   - Optional Safe nonce override when PROPOSE_TO_SAFE=true
#   SAFE_PROPOSER_PRIVATE_KEY    - Required when PROPOSE_TO_SAFE=true and DRY_RUN=false
#   SAFE_TX_SERVICE_URL          - Optional override for tx-service base URL
#   SAFE_TRANSACTION_SERVICE_API_KEY - Optional bearer token for tx-service
#   RATIONALE                    - Optional rationale for Safe proposal summary/origin
#   EVIDENCE_URL                 - Optional Dealbot or supporting evidence link
#
# Required for direct send when CALLDATA_ONLY != true and PROPOSE_TO_SAFE != true:
#   ETH_KEYSTORE
#   PASSWORD

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"
source "$SCRIPT_DIR/multisig.sh"

CALLDATA_ONLY="${CALLDATA_ONLY:-false}"
PROPOSE_TO_SAFE="${PROPOSE_TO_SAFE:-false}"
DRY_RUN="${DRY_RUN:-true}"
ACTION="${ACTION:-}"
PROVIDER_ID="${PROVIDER_ID:-}"
SERVICE_PROVIDER_ADDRESS="${SERVICE_PROVIDER_ADDRESS:-}"
INDEX="${INDEX:-}"
SAFE_NONCE="${SAFE_NONCE:-}"
SAFE_PROPOSER_PRIVATE_KEY="${SAFE_PROPOSER_PRIVATE_KEY:-}"
SAFE_TX_SERVICE_URL="${SAFE_TX_SERVICE_URL:-}"
SAFE_TRANSACTION_SERVICE_API_KEY="${SAFE_TRANSACTION_SERVICE_API_KEY:-}"
RATIONALE="${RATIONALE:-}"
EVIDENCE_URL="${EVIDENCE_URL:-}"

ZERO_ADDRESS="0x0000000000000000000000000000000000000000"

usage() {
  cat <<'EOF'
Usage examples:
  ACTION=list ETH_RPC_URL=https://api.calibration.node.glif.io/rpc/v1 ./warm-storage-manage-approved-provider.sh
  ACTION=status SERVICE_PROVIDER_ADDRESS=0xabc... ETH_RPC_URL=https://api.node.glif.io/rpc/v1 ./warm-storage-manage-approved-provider.sh
  ACTION=add PROVIDER_ID=9 CALLDATA_ONLY=true ETH_RPC_URL=https://api.calibration.node.glif.io/rpc/v1 ./warm-storage-manage-approved-provider.sh
  ACTION=remove PROVIDER_ID=9 CALLDATA_ONLY=true ETH_RPC_URL=https://api.calibration.node.glif.io/rpc/v1 ./warm-storage-manage-approved-provider.sh
  ACTION=add PROVIDER_ID=9 PROPOSE_TO_SAFE=true DRY_RUN=true ETH_RPC_URL=https://api.calibration.node.glif.io/rpc/v1 ./warm-storage-manage-approved-provider.sh
EOF
}

append_summary() {
  local content="$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$content" >> "$GITHUB_STEP_SUMMARY"
  fi
}

set_output() {
  local key="$1"
  local value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

short_provider_list() {
  local raw="$1"
  local shortened="$raw"
  if [ "${#shortened}" -gt 120 ]; then
    shortened="${shortened:0:117}..."
  fi
  echo "$shortened"
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: required command '$command_name' is not installed"
    exit 1
  fi
}

normalize_bool() {
  local normalized
  normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if [ "$normalized" = "true" ]; then
    echo "true"
  else
    echo "false"
  fi
}

CALLDATA_ONLY=$(normalize_bool "$CALLDATA_ONLY")
PROPOSE_TO_SAFE=$(normalize_bool "$PROPOSE_TO_SAFE")
DRY_RUN=$(normalize_bool "$DRY_RUN")

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

if [ -z "$ACTION" ]; then
  echo "Error: ACTION is not set"
  usage
  exit 1
fi

require_command cast
require_command curl
require_command jq

if [ -z "${CHAIN:-}" ]; then
  CHAIN=$(cast chain-id --rpc-url "$ETH_RPC_URL")
fi

if [ -z "$CHAIN" ]; then
  echo "Error: Failed to detect chain ID from RPC"
  exit 1
fi

case "$CHAIN" in
  314)
    NETWORK_NAME="Mainnet"
    DEFAULT_SAFE_TX_SERVICE_URL="https://transaction.safe.filecoin.io/api"
    SAFE_UI_URL="https://safe.filecoin.io"
    ;;
  314159)
    NETWORK_NAME="Calibnet"
    DEFAULT_SAFE_TX_SERVICE_URL="https://transaction-testnet.safe.filecoin.io/api"
    SAFE_UI_URL="https://safe.filecoin.io"
    ;;
  *)
    NETWORK_NAME="Chain $CHAIN"
    DEFAULT_SAFE_TX_SERVICE_URL=""
    SAFE_UI_URL=""
    ;;
esac

load_deployment_addresses "$CHAIN"

if [ -z "${FWSS_PROXY_ADDRESS:-}" ]; then
  echo "Error: FWSS_PROXY_ADDRESS is not set (not found in deployments.json or environment)"
  exit 1
fi

if [ -z "${FWSS_VIEW_ADDRESS:-}" ]; then
  FWSS_VIEW_ADDRESS=$(cast call --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS" "viewContractAddress()(address)" 2>/dev/null)
fi

if [ -z "${FWSS_VIEW_ADDRESS:-}" ] || [ "$FWSS_VIEW_ADDRESS" = "$ZERO_ADDRESS" ]; then
  echo "Error: FWSS_VIEW_ADDRESS is not set and proxy viewContractAddress() is empty"
  exit 1
fi

fwss_owner() {
  cast call --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS" "owner()(address)"
}

approved_length() {
  cast call --rpc-url "$ETH_RPC_URL" "$FWSS_VIEW_ADDRESS" "getApprovedProvidersLength()(uint256)"
}

approved_raw_list() {
  cast call --rpc-url "$ETH_RPC_URL" "$FWSS_VIEW_ADDRESS" "getApprovedProviders(uint256,uint256)(uint256[])" 0 0
}

provider_approved() {
  cast call --rpc-url "$ETH_RPC_URL" "$FWSS_VIEW_ADDRESS" "isProviderApproved(uint256)(bool)" "$1"
}

resolve_provider_id() {
  if [ -n "$PROVIDER_ID" ]; then
    return 0
  fi

  if [ -z "$SERVICE_PROVIDER_ADDRESS" ]; then
    return 0
  fi

  if [ -z "${SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS:-}" ]; then
    echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not set; cannot resolve SERVICE_PROVIDER_ADDRESS"
    exit 1
  fi

  PROVIDER_ID=$(cast call --rpc-url "$ETH_RPC_URL" "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    "getProviderIdByAddress(address)(uint256)" "$SERVICE_PROVIDER_ADDRESS")

  if [ "$PROVIDER_ID" = "0" ]; then
    echo "Error: SERVICE_PROVIDER_ADDRESS $SERVICE_PROVIDER_ADDRESS is not registered in ServiceProviderRegistry"
    exit 1
  fi
}

registry_provider_active() {
  cast call --rpc-url "$ETH_RPC_URL" "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    "isProviderActive(uint256)(bool)" "$PROVIDER_ID"
}

registry_provider_has_pdp() {
  cast call --rpc-url "$ETH_RPC_URL" "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    "providerHasProduct(uint256,uint8)(bool)" "$PROVIDER_ID" 0
}

provider_registry_summary() {
  if [ -z "${SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS:-}" ] || [ -z "$PROVIDER_ID" ]; then
    return 0
  fi

  local active
  local has_pdp

  if ! active=$(registry_provider_active 2>/dev/null); then
    echo "Registry: providerId=$PROVIDER_ID not found"
    return 0
  fi

  if ! has_pdp=$(registry_provider_has_pdp 2>/dev/null); then
    has_pdp="unknown"
  fi

  echo "Registry: providerId=$PROVIDER_ID active=$active hasPDP=$has_pdp"
}

normalize_approved_list() {
  local raw="$1"
  raw="${raw#[}"
  raw="${raw%]}"
  raw="${raw// /}"
  echo "$raw"
}

find_provider_index() {
  local target="$1"
  local raw
  raw=$(normalize_approved_list "$(approved_raw_list)")

  if [ -z "$raw" ]; then
    return 1
  fi

  IFS=',' read -r -a provider_ids <<< "$raw"
  for i in "${!provider_ids[@]}"; do
    if [ "${provider_ids[$i]}" = "$target" ]; then
      echo "$i"
      return 0
    fi
  done

  return 1
}

print_list_with_indexes() {
  local raw
  local length

  length=$(approved_length)
  raw=$(normalize_approved_list "$(approved_raw_list)")

  echo "Chain ID: $CHAIN"
  echo "FWSS Proxy: $FWSS_PROXY_ADDRESS"
  echo "FWSS View: $FWSS_VIEW_ADDRESS"
  echo "Owner: $(fwss_owner)"
  echo "Approved provider count: $length"

  if [ -z "$raw" ]; then
    echo "Approved providers: []"
    return 0
  fi

  IFS=',' read -r -a provider_ids <<< "$raw"
  echo "Approved providers:"
  for i in "${!provider_ids[@]}"; do
    echo "  [$i] ${provider_ids[$i]}"
  done
}

safe_tx_service_url() {
  if [ -n "$SAFE_TX_SERVICE_URL" ]; then
    echo "$SAFE_TX_SERVICE_URL"
    return 0
  fi

  if [ -z "$DEFAULT_SAFE_TX_SERVICE_URL" ]; then
    echo "Error: no default Safe transaction service is configured for chain $CHAIN"
    exit 1
  fi

  echo "$DEFAULT_SAFE_TX_SERVICE_URL"
}

tx_service_curl() {
  local method="$1"
  local url="$2"
  local data="${3:-}"

  local curl_args=(-sS -X "$method" "$url")

  if [ -n "$SAFE_TRANSACTION_SERVICE_API_KEY" ]; then
    curl_args+=(-H "Authorization: Bearer $SAFE_TRANSACTION_SERVICE_API_KEY")
  fi

  if [ -n "$data" ]; then
    curl_args+=(-H "Content-Type: application/json" --data "$data")
  fi

  curl "${curl_args[@]}"
}

safe_onchain_nonce() {
  local safe_address="$1"
  cast call --rpc-url "$ETH_RPC_URL" "$safe_address" "nonce()(uint256)"
}

safe_pending_next_nonce() {
  local safe_address="$1"
  local tx_service_url="$2"
  local pending_response
  local pending_nonce
  local current_nonce

  current_nonce=$(safe_onchain_nonce "$safe_address")
  pending_response=$(tx_service_curl GET \
    "$tx_service_url/v1/safes/$safe_address/multisig-transactions/?executed=false&ordering=-nonce&limit=1" \
    2>/dev/null || true)
  pending_nonce=$(printf '%s' "$pending_response" | jq -r '.results[0].nonce // empty' 2>/dev/null || true)

  if [ -n "$pending_nonce" ] && [ "$pending_nonce" -ge "$current_nonce" ]; then
    echo $((pending_nonce + 1))
  else
    echo "$current_nonce"
  fi
}

direct_send_transaction() {
  local function_sig="$1"
  shift

  if [ -z "${ETH_KEYSTORE:-}" ]; then
    echo "Error: ETH_KEYSTORE is not set"
    exit 1
  fi

  if [ -z "${PASSWORD:-}" ]; then
    echo "Error: PASSWORD is not set"
    exit 1
  fi

  local owner
  local sender
  local nonce
  local tx_hash

  owner=$(fwss_owner)
  sender=$(cast wallet address --password "$PASSWORD")

  if [ "$owner" != "$sender" ]; then
    echo "Error: signer ($sender) is not the FWSS owner ($owner). Use CALLDATA_ONLY=true or PROPOSE_TO_SAFE=true for Safe-owned contracts."
    exit 1
  fi

  nonce=$(cast nonce "$sender")
  tx_hash=$(cast send "$FWSS_PROXY_ADDRESS" "$function_sig" "$@" \
    --password "$PASSWORD" \
    --nonce "$nonce" \
    --json | jq -r '.transactionHash')

  if [ -z "$tx_hash" ] || [ "$tx_hash" = "null" ]; then
    echo "Error: Failed to send transaction"
    exit 1
  fi

  echo "Transaction sent: $tx_hash"
}

make_origin() {
  local base="filecoin-services/${ACTION}-approved-provider/${PROVIDER_ID}"
  local trimmed_rationale
  local origin

  trimmed_rationale=$(printf '%s' "$RATIONALE" | tr '\n\r\t' '   ' | tr -s ' ')

  if [ -n "$trimmed_rationale" ]; then
    origin="$base - $trimmed_rationale"
  else
    origin="$base"
  fi

  printf '%s' "${origin:0:180}"
}

propose_to_safe() {
  local function_sig="$1"
  shift

  local safe_address
  local tx_service_url
  local safe_nonce
  local calldata
  local safe_tx_hash
  local sender
  local signature
  local payload
  local response
  local response_body
  local response_code
  local approved_snapshot
  local provider_active="n/a"
  local provider_has_pdp="n/a"
  local approved_before="n/a"
  local approved_index_before="n/a"
  local approved_count_before="n/a"
  local title

  safe_address=$(fwss_owner)
  tx_service_url=$(safe_tx_service_url)

  calldata=$(cast calldata "$function_sig" "$@")
  if [ -n "$SAFE_NONCE" ]; then
    safe_nonce="$SAFE_NONCE"
  else
    safe_nonce=$(safe_pending_next_nonce "$safe_address" "$tx_service_url")
  fi

  safe_tx_hash=$(cast call --rpc-url "$ETH_RPC_URL" "$safe_address" \
    "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
    "$FWSS_PROXY_ADDRESS" \
    0 \
    "$calldata" \
    0 \
    0 \
    0 \
    0 \
    "$ZERO_ADDRESS" \
    "$ZERO_ADDRESS" \
    "$safe_nonce")

  if [ -n "$PROVIDER_ID" ]; then
    approved_before=$(provider_approved "$PROVIDER_ID")
    approved_count_before=$(approved_length)
    if current_index=$(find_provider_index "$PROVIDER_ID"); then
      approved_index_before="$current_index"
    else
      approved_index_before="not present"
    fi
    if [ -n "${SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS:-}" ]; then
      provider_active=$(registry_provider_active 2>/dev/null || echo "false")
      provider_has_pdp=$(registry_provider_has_pdp 2>/dev/null || echo "false")
    fi
  fi

  approved_snapshot=$(short_provider_list "$(approved_raw_list)")

  set_output "provider_id" "$PROVIDER_ID"
  set_output "calldata" "$calldata"
  set_output "safe_nonce" "$safe_nonce"
  set_output "fwss_proxy_address" "$FWSS_PROXY_ADDRESS"
  set_output "tx_service_url" "$tx_service_url"
  set_output "safe_tx_hash" "$safe_tx_hash"

  if [ "$DRY_RUN" = "true" ]; then
    title="Dry Run"
  else
    title="Proposal"
  fi

  local summary
  summary=$(cat <<EOF
## Approved SP $title

| Field | Value |
|---|---|
| Network | $NETWORK_NAME ($CHAIN) |
| Operation | $ACTION |
| Safe | \`$safe_address\` |
| FWSS Proxy | \`$FWSS_PROXY_ADDRESS\` |
| FWSS View | \`$FWSS_VIEW_ADDRESS\` |
| Registry | \`${SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS:-n/a}\` |
| Tx Service | $tx_service_url |
| Provider ID | \`$PROVIDER_ID\` |
| Provider Address | ${SERVICE_PROVIDER_ADDRESS:-n/a} |
| Registry Active | $provider_active |
| Registry PDP Product | $provider_has_pdp |
| Approved Before | $approved_before |
| Approved Index Before | $approved_index_before |
| Approved Count Before | $approved_count_before |
| Safe Nonce | $safe_nonce |
| Evidence URL | ${EVIDENCE_URL:-n/a} |
| Rationale | ${RATIONALE:-n/a} |

### Calldata

\`\`\`
$calldata
\`\`\`

### Approved Provider Snapshot

Current approved providers: [$approved_snapshot]

### Safe Transaction Hash

\`$safe_tx_hash\`
EOF
)

  echo "$summary"
  append_summary "$summary"

  if [ "$DRY_RUN" = "true" ]; then
    return 0
  fi

  if [ -z "$SAFE_PROPOSER_PRIVATE_KEY" ]; then
    echo "Error: SAFE_PROPOSER_PRIVATE_KEY is required when PROPOSE_TO_SAFE=true and DRY_RUN=false"
    exit 1
  fi

  sender=$(cast wallet address --private-key "$SAFE_PROPOSER_PRIVATE_KEY")
  signature=$(cast wallet sign --private-key "$SAFE_PROPOSER_PRIVATE_KEY" --no-hash "$safe_tx_hash")

  payload=$(jq -n \
    --arg safe "$safe_address" \
    --arg to "$FWSS_PROXY_ADDRESS" \
    --arg data "$calldata" \
    --arg hash "$safe_tx_hash" \
    --arg sender "$sender" \
    --arg signature "$signature" \
    --arg origin "$(make_origin)" \
    --argjson nonce "$safe_nonce" \
    '{
      safe: $safe,
      to: $to,
      value: 0,
      data: $data,
      operation: 0,
      baseGas: 0,
      gasPrice: 0,
      safeTxGas: 0,
      nonce: $nonce,
      contractTransactionHash: $hash,
      sender: $sender,
      signature: $signature,
      origin: (if $origin == "" then null else $origin end)
    }')

  response=$(curl -sS -w '\n%{http_code}' -X POST \
    "${tx_service_url}/v1/safes/${safe_address}/multisig-transactions/" \
    -H "Content-Type: application/json" \
    ${SAFE_TRANSACTION_SERVICE_API_KEY:+-H "Authorization: Bearer ${SAFE_TRANSACTION_SERVICE_API_KEY}"} \
    --data "$payload")

  response_body=$(printf '%s' "$response" | sed '$d')
  response_code=$(printf '%s' "$response" | tail -n1)

  if [ "$response_code" != "201" ]; then
    echo "Error: Safe tx-service proposal failed with HTTP $response_code"
    if [ -n "$response_body" ]; then
      echo "$response_body"
    fi
    exit 1
  fi

  local proposal_summary
  proposal_summary=$(cat <<EOF

### Proposed Transaction

| Field | Value |
|---|---|
| Sender Address | \`$sender\` |
| Safe Tx Hash | \`$safe_tx_hash\` |
| Safe UI | $SAFE_UI_URL |
EOF
)

  echo "$proposal_summary"
  append_summary "$proposal_summary"

  set_output "sender_address" "$sender"
}

send_transaction() {
  local function_sig="$1"
  shift

  if [ "$CALLDATA_ONLY" = "true" ]; then
    local calldata
    calldata=$(cast calldata "$function_sig" "$@")
    print_safe_transaction "$FWSS_PROXY_ADDRESS" "$function_sig" "$calldata"
    return 0
  fi

  if [ "$PROPOSE_TO_SAFE" = "true" ]; then
    propose_to_safe "$function_sig" "$@"
    return 0
  fi

  direct_send_transaction "$function_sig" "$@"
}

resolve_provider_id

case "$ACTION" in
  list)
    print_list_with_indexes
    ;;

  status)
    echo "Chain ID: $CHAIN"
    echo "FWSS Proxy: $FWSS_PROXY_ADDRESS"
    echo "FWSS View: $FWSS_VIEW_ADDRESS"
    echo "Owner: $(fwss_owner)"
    echo "Approved provider count: $(approved_length)"
    if [ -n "$SERVICE_PROVIDER_ADDRESS" ]; then
      echo "Service provider address: $SERVICE_PROVIDER_ADDRESS"
    fi
    if [ -n "$PROVIDER_ID" ]; then
      local_status=$(provider_approved "$PROVIDER_ID")
      echo "Provider ID: $PROVIDER_ID"
      provider_registry_summary
      echo "Approved in FWSS: $local_status"
      if current_index=$(find_provider_index "$PROVIDER_ID"); then
        echo "Current approved-provider index: $current_index"
      else
        echo "Current approved-provider index: not present"
      fi
    fi
    ;;

  add)
    if [ -z "$PROVIDER_ID" ]; then
      echo "Error: PROVIDER_ID or SERVICE_PROVIDER_ADDRESS is required for ACTION=add"
      exit 1
    fi

    if [ -z "${SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS:-}" ]; then
      echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not set; cannot validate provider"
      exit 1
    fi

    if [ "$(provider_approved "$PROVIDER_ID")" = "true" ]; then
      echo "Error: Provider $PROVIDER_ID is already approved"
      exit 1
    fi

    active=$(registry_provider_active 2>/dev/null || true)
    has_pdp=$(registry_provider_has_pdp 2>/dev/null || true)

    if [ "$active" != "true" ]; then
      echo "Error: Provider $PROVIDER_ID is not an active ServiceProviderRegistry entry"
      exit 1
    fi

    if [ "$has_pdp" != "true" ]; then
      echo "Error: Provider $PROVIDER_ID does not currently have an active PDP product"
      exit 1
    fi

    provider_registry_summary
    send_transaction "addApprovedProvider(uint256)" "$PROVIDER_ID"
    ;;

  remove)
    if [ -z "$PROVIDER_ID" ]; then
      echo "Error: PROVIDER_ID or SERVICE_PROVIDER_ADDRESS is required for ACTION=remove"
      exit 1
    fi

    if [ "$(provider_approved "$PROVIDER_ID")" != "true" ]; then
      echo "Error: Provider $PROVIDER_ID is not approved"
      exit 1
    fi

    if [ -z "$INDEX" ]; then
      if ! INDEX=$(find_provider_index "$PROVIDER_ID"); then
        echo "Error: Could not resolve current index for provider $PROVIDER_ID"
        exit 1
      fi
    fi

    provider_registry_summary
    echo "Resolved removal index: $INDEX"
    send_transaction "removeApprovedProvider(uint256,uint256)" "$PROVIDER_ID" "$INDEX"
    ;;

  *)
    echo "Error: Unsupported ACTION '$ACTION'"
    usage
    exit 1
    ;;
esac
