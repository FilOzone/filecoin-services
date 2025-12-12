#!/bin/bash
# deployments.sh - Shared functions for loading and updating deployment addresses
# 
# This script provides functions to:
# - Load deployment addresses from deployments.json (keyed by chain-id)
# - Update deployment addresses in deployments.json when contracts are deployed
# - Handle missing chains gracefully
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/deployments.sh"
#   load_deployment_addresses "$CHAIN"
#   update_deployment_address "$CHAIN" "CONTRACT_NAME" "$ADDRESS"
#
# Environment variables:
#   SKIP_LOAD_DEPLOYMENTS - If set to "true", skip loading from JSON (default: false)
#   SKIP_UPDATE_DEPLOYMENTS - If set to "true", skip updating JSON (default: false)
#   DEPLOYMENTS_JSON_PATH - Path to deployments.json (default: service_contracts/deployments.json)

# Get the script directory to find deployments.json relative to tools/
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
DEPLOYMENTS_JSON_PATH="${DEPLOYMENTS_JSON_PATH:-$SCRIPT_DIR/../deployments.json}"

# Ensure deployments.json exists with proper structure
ensure_deployments_json() {
    if [ ! -f "$DEPLOYMENTS_JSON_PATH" ]; then
        echo "Creating deployments.json at $DEPLOYMENTS_JSON_PATH"
        echo '{}' > "$DEPLOYMENTS_JSON_PATH"
    fi
    
    # Ensure it's valid JSON
    if ! jq empty "$DEPLOYMENTS_JSON_PATH" 2>/dev/null; then
        echo "Error: deployments.json is not valid JSON"
        exit 1
    fi
}

# Load deployment addresses from deployments.json for a given chain
# Args: $1=chain_id
# Sets environment variables for all addresses found in the JSON
load_deployment_addresses() {
    local chain_id="$1"
    
    if [ -z "$chain_id" ]; then
        echo "Error: chain_id is required for load_deployment_addresses"
        return 1
    fi
    
    # Check if we should skip loading
    if [ "${SKIP_LOAD_DEPLOYMENTS:-false}" = "true" ]; then
        echo "⏭️  Skipping loading from deployments.json (SKIP_LOAD_DEPLOYMENTS=true)"
        return 0
    fi
    
    ensure_deployments_json
    
    # Check if chain exists in JSON
    if ! jq -e ".[\"$chain_id\"]" "$DEPLOYMENTS_JSON_PATH" > /dev/null 2>&1; then
        echo "ℹ️  Chain $chain_id not found in deployments.json, will use environment variables"
        return 0
    fi
    
    echo "📖 Loading deployment addresses from deployments.json for chain $chain_id"
    
    # Load all addresses from the chain's section
    # Extract all keys that are not "metadata"
    local addresses=$(jq -r ".[\"$chain_id\"] | to_entries | .[] | select(.key != \"metadata\") | \"\(.key)=\(.value)\"" "$DEPLOYMENTS_JSON_PATH" 2>/dev/null)
    
    if [ -z "$addresses" ]; then
        echo "ℹ️  No addresses found for chain $chain_id in deployments.json"
        return 0
    fi
    
    # Export each address as an environment variable
    while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ] && [ "$value" != "null" ]; then
            # Only set if not already set (allow env vars to override)
            if [ -z "${!key}" ]; then
                export "$key=$value"
                echo "  ✓ Loaded $key=$value"
            else
                echo "  ⊘ Skipped $key (already set to ${!key})"
            fi
        fi
    done <<< "$addresses"
}

# Update a deployment address in deployments.json
# Args: $1=chain_id, $2=contract_name (env var name), $3=address
update_deployment_address() {
    local chain_id="$1"
    local contract_name="$2"
    local address="$3"
    
    if [ -z "$chain_id" ]; then
        echo "Error: chain_id is required for update_deployment_address"
        return 1
    fi
    
    if [ -z "$contract_name" ]; then
        echo "Error: contract_name is required for update_deployment_address"
        return 1
    fi
    
    if [ -z "$address" ]; then
        echo "Error: address is required for update_deployment_address"
        return 1
    fi
    
    # Check if we should skip updating
    if [ "${SKIP_UPDATE_DEPLOYMENTS:-false}" = "true" ]; then
        echo "⏭️  Skipping update to deployments.json (SKIP_UPDATE_DEPLOYMENTS=true)"
        return 0
    fi
    
    ensure_deployments_json
    
    echo "💾 Updating deployments.json: chain=$chain_id, contract=$contract_name, address=$address"
    
    # Update the JSON file using jq
    # This ensures the chain entry exists and updates the specific contract address
    local temp_file=$(mktemp)
    jq --arg chain "$chain_id" \
       --arg contract "$contract_name" \
       --arg addr "$address" \
       'if .[$chain] then .[$chain][$contract] = $addr else .[$chain] = {($contract): $addr} end' \
       "$DEPLOYMENTS_JSON_PATH" > "$temp_file"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to update deployments.json"
        rm -f "$temp_file"
        return 1
    fi
    
    mv "$temp_file" "$DEPLOYMENTS_JSON_PATH"
    echo "  ✓ Updated $contract_name=$address for chain $chain_id"
}

# Update deployment metadata (commit hash, deployment timestamp, etc.)
# Args: $1=chain_id, $2=commit_hash (optional), $3=deployed_at (optional, defaults to current timestamp)
update_deployment_metadata() {
    local chain_id="$1"
    local commit_hash="${2:-}"
    local deployed_at="${3:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
    
    if [ -z "$chain_id" ]; then
        echo "Error: chain_id is required for update_deployment_metadata"
        return 1
    fi
    
    # Check if we should skip updating
    if [ "${SKIP_UPDATE_DEPLOYMENTS:-false}" = "true" ]; then
        return 0
    fi
    
    ensure_deployments_json
    
    # Get current commit hash if not provided
    if [ -z "$commit_hash" ]; then
        if command -v git >/dev/null 2>&1; then
            commit_hash=$(git rev-parse HEAD 2>/dev/null || echo "")
        fi
    fi
    
    local temp_file=$(mktemp)
    local jq_cmd="if .[\"$chain_id\"] then .[\"$chain_id\"].metadata = {} else .[\"$chain_id\"] = {metadata: {}} end"
    
    if [ -n "$commit_hash" ]; then
        jq_cmd="$jq_cmd | .[\"$chain_id\"].metadata.commit = \"$commit_hash\""
    fi
    
    jq_cmd="$jq_cmd | .[\"$chain_id\"].metadata.deployed_at = \"$deployed_at\""
    
    jq "$jq_cmd" "$DEPLOYMENTS_JSON_PATH" > "$temp_file"
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to update deployment metadata"
        rm -f "$temp_file"
        return 1
    fi
    
    mv "$temp_file" "$DEPLOYMENTS_JSON_PATH"
    
    if [ -n "$commit_hash" ]; then
        echo "  ✓ Updated metadata: commit=$commit_hash, deployed_at=$deployed_at"
    else
        echo "  ✓ Updated metadata: deployed_at=$deployed_at"
    fi
}

# Get a deployment address from JSON (useful for scripts that just need to read)
# Args: $1=chain_id, $2=contract_name
# Outputs: address or empty string if not found
get_deployment_address() {
    local chain_id="$1"
    local contract_name="$2"
    
    if [ -z "$chain_id" ] || [ -z "$contract_name" ]; then
        return 1
    fi
    
    ensure_deployments_json
    
    jq -r ".[\"$chain_id\"][\"$contract_name\"] // empty" "$DEPLOYMENTS_JSON_PATH" 2>/dev/null
}


