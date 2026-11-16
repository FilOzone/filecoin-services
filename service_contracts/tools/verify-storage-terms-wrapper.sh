#!/bin/bash
# verify-storage-terms-wrapper.sh - Checks a deployed FWSSStorageTermsMigration against source
#
# The storage-terms introduction must announce and execute the wrapper, not the raw josuke
# migration: the raw migration installs the new routes without initializing storage terms
# record zero, and data sets with a pending fee then revert with UnknownStorageTerms.
# josuke verify checks the raw migration but not the wrapper, so this script rebuilds the
# wrapper with the raw migration from the reviewed josuke.json filled into its immutable and
# compares the complete runtime bytecode with the code at the given address.
#
# Usage:
#   ./tools/verify-storage-terms-wrapper.sh <wrapper_address>
#
# Run it from a clean checkout of the frozen deploy commit with the reviewed josuke.json.
# Exits non-zero, printing STOP, if the address does not hold the expected wrapper.
#
# Environment variables:
#   CHAIN - Chain ID of the deployment to read from josuke.json
#   ETH_RPC_URL - RPC endpoint of that chain
#   FWSS_PROXY_ADDRESS - FWSS proxy whose proposed migration the wrapper must wrap

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <wrapper_address>" >&2
    exit 1
fi
: "${CHAIN:?CHAIN must be set}"
: "${ETH_RPC_URL:?ETH_RPC_URL must be set}"
: "${FWSS_PROXY_ADDRESS:?FWSS_PROXY_ADDRESS must be set}"
if [ -n "${ETH_KEYSTORE:-}" ] || [ -n "${ETH_PASSWORD:-}" ]; then
    echo "Unset ETH_KEYSTORE and ETH_PASSWORD: this check is read-only (foundry-rs/foundry#17388)" >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=josuke.sh
source tools/josuke.sh

WRAPPER=$(cast to-check-sum-address "$1")
RAW_MIGRATION=$(josuke_proposed_migration "$FWSS_PROXY_ADDRESS")
if [ -z "$RAW_MIGRATION" ]; then
    echo "STOP: josuke.json has no proposed migration for $FWSS_PROXY_ADDRESS on chain $CHAIN" >&2
    exit 1
fi

forge build src/FWSSStorageTermsMigration.sol >/dev/null
ARTIFACT=out/FWSSStorageTermsMigration.sol/FWSSStorageTermsMigration.json
REFS=$(jq -c '.deployedBytecode.immutableReferences' "$ARTIFACT")
VALUES=$(jq -cn --argjson refs "$REFS" \
    --arg value "$(cast abi-encode 'f(address)' "$RAW_MIGRATION")" \
    '$refs | with_entries(.value = $value)')
EXPECTED=$(python3 tools/bytecode.py fill-imm \
    "$(jq -r '.deployedBytecode.object | ltrimstr("0x")' "$ARTIFACT")" \
    "$REFS" "$VALUES" | tr '[:upper:]' '[:lower:]')
ACTUAL=$(cast code --rpc-url "$ETH_RPC_URL" "$WRAPPER" | tr '[:upper:]' '[:lower:]')

if [ "$ACTUAL" != "0x$EXPECTED" ]; then
    echo "STOP: $WRAPPER is not the FWSSStorageTermsMigration wrapping $RAW_MIGRATION" >&2
    exit 1
fi
echo "Wrapper:       $WRAPPER $(cast keccak "$ACTUAL")"
echo "Raw migration: $RAW_MIGRATION $(cast keccak "$(cast code --rpc-url "$ETH_RPC_URL" "$RAW_MIGRATION")")"
echo "OK: storage-terms wrapper matches source"
