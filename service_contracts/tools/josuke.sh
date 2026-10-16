#!/bin/bash
# josuke.sh - Reads the josuke ledger (josuke.json) for the ERC-8167 transition scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")/josuke.sh"
#   josuke_proposed_migration "$FWSS_PROXY_ADDRESS"
#   josuke_move_entry "$FROM_ADDRESS" "$TO_ADDRESS"
#
# Environment variables:
#   CHAIN - Chain ID of the deployment to read
#   JOSUKE_LEDGER - Path to the ledger (default: service_contracts/josuke.json)

JOSUKE_LEDGER="${JOSUKE_LEDGER:-$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")/../josuke.json}"

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

# Moves a ledger entry from one address to another, keeping its facets and deployments
# Args: $1=from_address, $2=to_address
josuke_move_entry() {
    local to tmp
    to=$(cast to-check-sum-address "$2") || return 1
    tmp=$(mktemp) || return 1
    if jq --indent 4 --arg from "$1" --arg to "$to" '
        def listed($address): any(.[]; (.address | ascii_downcase) == ($address | ascii_downcase));
        if (listed($from) | not) then error("\($from) is not in the ledger")
        elif listed($to) then error("\($to) is already in the ledger")
        else map(if (.address | ascii_downcase) == ($from | ascii_downcase) then .address = $to else . end)
        end' "$JOSUKE_LEDGER" > "$tmp"; then
        mv "$tmp" "$JOSUKE_LEDGER"
    else
        rm -f "$tmp"
        return 1
    fi
}
