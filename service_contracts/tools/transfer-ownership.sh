#!/bin/bash
set -euo pipefail

# transfer-ownership.sh: Transfer ownership of FWSS-scoped contracts to a new owner (e.g., Safe multisig)
#
# Transfers ownership of:
#   1. FilecoinWarmStorageService (FWSS) proxy
#   2. ServiceProviderRegistry proxy
#
# Required environment variables:
#   ETH_RPC_URL    - RPC endpoint
#   NEW_OWNER      - Address of the new owner (must be a contract, not an EOA)
#
# Required for execution (not needed for DRY_RUN):
#   ETH_KEYSTORE   - Path to keystore file
#   PASSWORD        - Keystore password
#
# Optional:
#   DRY_RUN        - Set to "true" to only show current owners and what would change (default: false)
#   CHAIN          - Chain ID (auto-detected from RPC if not set)

# Get script directory and source deployments.sh
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"

DRY_RUN="${DRY_RUN:-false}"

# Helper: convert string to lowercase
to_lowercase() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Helper: get Filfox explorer URL for a transaction
explorer_tx_url() {
  local chain_id="$1"
  local tx_hash="$2"
  case "$chain_id" in
    314)    echo "https://filfox.info/en/tx/$tx_hash" ;;
    314159) echo "https://calibration.filfox.info/en/tx/$tx_hash" ;;
    *)      echo "" ;;
  esac
}

# --- Validate common requirements ---

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

if [ -z "${NEW_OWNER:-}" ]; then
  echo "Error: NEW_OWNER is not set"
  exit 1
fi

# Auto-detect chain ID
if [ -z "${CHAIN:-}" ]; then
  CHAIN=$(cast chain-id)
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi
echo "Chain ID: $CHAIN"

# Load deployment addresses from deployments.json
load_deployment_addresses "$CHAIN"

# Validate proxy addresses are available
if [ -z "${FWSS_PROXY_ADDRESS:-}" ]; then
  echo "Error: FWSS_PROXY_ADDRESS is not set (not found in deployments.json or environment)"
  exit 1
fi

if [ -z "${SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS:-}" ]; then
  echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not set (not found in deployments.json or environment)"
  exit 1
fi

# Verify NEW_OWNER is a contract address (not an EOA)
echo "Verifying NEW_OWNER ($NEW_OWNER) is a contract..."
NEW_OWNER_CODE=$(cast code "$NEW_OWNER" 2>/dev/null || echo "0x")
if [ "$NEW_OWNER_CODE" = "0x" ] || [ -z "$NEW_OWNER_CODE" ]; then
  echo "Error: NEW_OWNER ($NEW_OWNER) has no code deployed — it appears to be an EOA, not a contract."
  echo "Refusing to transfer ownership to a non-contract address."
  exit 1
fi
echo "  NEW_OWNER is a contract (code size: ${#NEW_OWNER_CODE} chars)"

# Read current owners
echo ""
echo "Reading current owners..."
FWSS_OWNER=$(cast call -f 0x0000000000000000000000000000000000000000 "$FWSS_PROXY_ADDRESS" "owner()(address)" 2>/dev/null)
SPR_OWNER=$(cast call -f 0x0000000000000000000000000000000000000000 "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "owner()(address)" 2>/dev/null)

echo "  FWSS Proxy ($FWSS_PROXY_ADDRESS):"
echo "    Current owner: $FWSS_OWNER"
echo "  ServiceProviderRegistry Proxy ($SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS):"
echo "    Current owner: $SPR_OWNER"
echo "  New owner:       $NEW_OWNER"

# --- DRY_RUN: show what would happen and exit ---

if [ "$DRY_RUN" = "true" ]; then
  echo ""
  echo "=== DRY RUN ==="
  echo "Would transfer ownership of:"
  echo "  1. FWSS Proxy ($FWSS_PROXY_ADDRESS): $FWSS_OWNER -> $NEW_OWNER"
  echo "  2. ServiceProviderRegistry Proxy ($SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS): $SPR_OWNER -> $NEW_OWNER"
  echo ""
  echo "No transactions sent."
  exit 0
fi

# --- Execution mode: validate keystore requirements ---

if [ -z "${ETH_KEYSTORE:-}" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

if [ -z "${PASSWORD:-}" ]; then
  echo "Error: PASSWORD is not set"
  exit 1
fi

ADDR=$(cast wallet address --password "$PASSWORD")
echo ""
echo "Sender address: $ADDR"

# Verify sender is the current owner of both contracts
if [ "$FWSS_OWNER" != "$ADDR" ]; then
  echo "Error: Sender ($ADDR) is not the FWSS proxy owner ($FWSS_OWNER)"
  exit 1
fi

if [ "$SPR_OWNER" != "$ADDR" ]; then
  echo "Error: Sender ($ADDR) is not the ServiceProviderRegistry proxy owner ($SPR_OWNER)"
  exit 1
fi

# Get initial nonce
NONCE=$(cast nonce "$ADDR")

# --- Transfer 1: FWSS Proxy ---

echo ""
echo "=== Transfer 1/2: FWSS Proxy ==="
echo "  Contract: $FWSS_PROXY_ADDRESS"
echo "  From:     $ADDR"
echo "  To:       $NEW_OWNER"
echo "  Nonce:    $NONCE"

TX_HASH=$(cast send "$FWSS_PROXY_ADDRESS" "transferOwnership(address)" "$NEW_OWNER" \
  --password "$PASSWORD" \
  --nonce "$NONCE" \
  --async)

if [ -z "$TX_HASH" ] || [ "$TX_HASH" = "null" ]; then
  echo "Error: Failed to send transferOwnership transaction for FWSS proxy"
  exit 1
fi

EXPLORER_URL=$(explorer_tx_url "$CHAIN" "$TX_HASH")
echo "  TX sent: $TX_HASH"
[ -n "$EXPLORER_URL" ] && echo "  Explorer: $EXPLORER_URL"
echo "  Waiting for confirmation..."
cast receipt "$TX_HASH" --confirmations 1 > /dev/null

# Verify new owner
FWSS_NEW_OWNER=$(cast call -f 0x0000000000000000000000000000000000000000 "$FWSS_PROXY_ADDRESS" "owner()(address)" 2>/dev/null)
if [ "$(to_lowercase "$FWSS_NEW_OWNER")" != "$(to_lowercase "$NEW_OWNER")" ]; then
  echo "Error: FWSS proxy owner verification failed!"
  echo "  Expected: $NEW_OWNER"
  echo "  Got:      $FWSS_NEW_OWNER"
  exit 1
fi
echo "  Verified: FWSS proxy owner is now $FWSS_NEW_OWNER"

# Increment nonce for next transaction
NONCE=$((NONCE + 1))

# --- Transfer 2: ServiceProviderRegistry Proxy ---

echo ""
echo "=== Transfer 2/2: ServiceProviderRegistry Proxy ==="
echo "  Contract: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "  From:     $ADDR"
echo "  To:       $NEW_OWNER"
echo "  Nonce:    $NONCE"

TX_HASH=$(cast send "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "transferOwnership(address)" "$NEW_OWNER" \
  --password "$PASSWORD" \
  --nonce "$NONCE" \
  --async)

if [ -z "$TX_HASH" ] || [ "$TX_HASH" = "null" ]; then
  echo "Error: Failed to send transferOwnership transaction for ServiceProviderRegistry proxy"
  exit 1
fi

EXPLORER_URL=$(explorer_tx_url "$CHAIN" "$TX_HASH")
echo "  TX sent: $TX_HASH"
[ -n "$EXPLORER_URL" ] && echo "  Explorer: $EXPLORER_URL"
echo "  Waiting for confirmation..."
cast receipt "$TX_HASH" --confirmations 1 > /dev/null

# Verify new owner
SPR_NEW_OWNER=$(cast call -f 0x0000000000000000000000000000000000000000 "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" "owner()(address)" 2>/dev/null)
if [ "$(to_lowercase "$SPR_NEW_OWNER")" != "$(to_lowercase "$NEW_OWNER")" ]; then
  echo "Error: ServiceProviderRegistry proxy owner verification failed!"
  echo "  Expected: $NEW_OWNER"
  echo "  Got:      $SPR_NEW_OWNER"
  exit 1
fi
echo "  Verified: ServiceProviderRegistry proxy owner is now $SPR_NEW_OWNER"

# --- Summary ---

echo ""
echo "============================================================"
echo "  Ownership Transfer Complete"
echo "============================================================"
echo "  FWSS Proxy ($FWSS_PROXY_ADDRESS):"
echo "    Old owner: $ADDR"
echo "    New owner: $FWSS_NEW_OWNER"
echo ""
echo "  ServiceProviderRegistry Proxy ($SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS):"
echo "    Old owner: $ADDR"
echo "    New owner: $SPR_NEW_OWNER"
echo "============================================================"
echo ""
echo "All onlyOwner operations (upgrades, config changes) must now"
echo "go through the multisig at $NEW_OWNER."
