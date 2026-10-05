#!/bin/bash
# josuke.sh - Reads the josuke ledger (josuke.json) for the ERC-8167 transition scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/josuke.sh"
#   josuke_proposed_migration "$FWSS_PROXY_ADDRESS"
#
# Environment variables:
#   CHAIN - Chain ID of the deployment to read
#   JOSUKE_LEDGER - Path to the ledger (default: service_contracts/josuke.json)

JOSUKE_LEDGER="${JOSUKE_LEDGER:-$(dirname "${BASH_SOURCE[0]}")/../josuke.json}"

# Prints the EIP-55 migration `josuke deploy` proposed for a proxy on $CHAIN, or nothing if there is none
# Args: $1=proxy_address
josuke_proposed_migration() {
    local migration
    migration=$(jq -r --arg chain "$CHAIN" --arg proxy "$1" \
        '.[] | select((.address | ascii_downcase) == ($proxy | ascii_downcase))
            | .deployments[$chain].proposed.migration.address // empty' \
        "$JOSUKE_LEDGER")
    if [ -n "$migration" ]; then
        cast to-check-sum-address "$migration"
    fi
}
