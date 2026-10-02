#!/bin/bash
# josuke.sh - Reads the josuke ledger (josuke.json) for the ERC-8167 transition scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/josuke.sh"
#   josuke_proposed_migration "$CHAIN" "$FWSS_PROXY_ADDRESS"
#
# Environment variables:
#   JOSUKE_LEDGER - Path to the ledger (default: service_contracts/josuke.json)

JOSUKE_LEDGER="${JOSUKE_LEDGER:-$(dirname "${BASH_SOURCE[0]}")/../josuke.json}"

# Prints the migration `josuke deploy` proposed for a proxy on a chain, or nothing if there is none
# Args: $1=chain_id, $2=proxy_address
josuke_proposed_migration() {
    jq -r --arg chain "$1" --arg proxy "$2" \
        '.[] | select((.address | ascii_downcase) == ($proxy | ascii_downcase))
            | .deployments[$chain].proposed.migration.address // empty' \
        "$JOSUKE_LEDGER"
}
