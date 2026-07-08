#!/bin/bash
# verify-deployments.sh — verifies deployed contracts by running their
# constructor through the EVM and comparing the resulting runtime bytecode
# to what is actually on-chain.  Also used to backfill bytecode metadata in
# deployments.json for existing deployments.
#
# Usage:
#   Verify all contracts with stored metadata:
#     ./tools/verify-deployments.sh [--chain CHAIN] [--eth-call]
#
#   Backfill (verify + record) a specific contract:
#     ./tools/verify-deployments.sh --backfill CONTRACT_KEY ARTIFACT LIBRARIES [ARG...]
#       CONTRACT_KEY  Key in the contracts table (e.g. FWSS_IMPLEMENTATION)
#       ARTIFACT      Artifact specifier, e.g. src/Foo.sol:Foo
#       LIBRARIES     Comma-separated "path:Name:addr,..." or "" if none
#       ARG...        Constructor arguments in order
#
# Environment:
#   ETH_RPC_URL  Required for on-chain lookup (cast code)
#   CHAIN        Chain ID; auto-detected from ETH_RPC_URL if unset
#
# Execution backends (constructor simulation):
#   Default:    evm -x  (local, no RPC needed; github:wjmelements/evm)
#               Pipe initcode into evm -x, output is the runtime bytecode.
#               Use this unless the constructor calls into another contract.
#   --eth-call  eth_call via ETH_RPC_URL.  Handles constructors that call
#               other contracts (e.g. proxy initialization via delegatecall).

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"

BACKFILL=false
USE_ETH_CALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backfill) BACKFILL=true; shift; break ;;
        --eth-call) USE_ETH_CALL=true ;;
        --chain)    CHAIN="$2"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ -z "${CHAIN:-}" ]; then
    CHAIN=$(cast chain-id)
fi

load_deployment_addresses "$CHAIN"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Replaces library placeholder bytes in initcode with the actual addresses,
# using the byte positions from the artifact's bytecode.linkReferences.
# Args: $1=hex (no 0x), $2=artifact_path, $3=libs_json ({"path:Name":"0xaddr"})
# Outputs the linked hex without 0x.
_link_bytecode() {
    local hex="$1" artifact="$2" libs_json="$3"
    python3 "$SCRIPT_DIR/bytecode.py" link \
        "$hex" \
        "$(jq -c '.bytecode.linkReferences' "$artifact")" \
        "$libs_json"
}

# Like _link_bytecode but uses deployedBytecode.linkReferences (for the fallback
# deployed-bytecode comparison path).
# Args: $1=hex (no 0x), $2=artifact_path, $3=libs_json
_link_deployed_bytecode() {
    local hex="$1" artifact="$2" libs_json="$3"
    python3 "$SCRIPT_DIR/bytecode.py" link \
        "$hex" \
        "$(jq -c '.deployedBytecode.linkReferences // {}' "$artifact")" \
        "$libs_json"
}

# ABI-encodes constructor arguments using types derived from the artifact ABI.
# Outputs hex without 0x, or nothing if the constructor takes no parameters.
_encode_constructor_args() {
    local artifact="$1"; shift
    local args=("$@")
    [ ${#args[@]} -eq 0 ] && return 0
    local types
    types=$(jq -r '[.abi[] | select(.type=="constructor") | .inputs[].type] | join(",")' "$artifact")
    [ -z "$types" ] && return 0
    # cast abi-encode outputs ABI-encoded data without a 4-byte selector
    printf '%s' "$(cast abi-encode "f($types)" "${args[@]}")" | sed 's/^0x//'
}

# Runs the full creation data (linked initcode + encoded constructor args)
# through the EVM and outputs the runtime bytecode hex without 0x.
_run_constructor() {
    local full_hex="$1"
    if [ "$USE_ETH_CALL" = "true" ]; then
        # eth_call with no 'to' field simulates a contract creation
        cast rpc eth_call "{\"data\":\"0x${full_hex}\"}" "latest" \
            | tr -d '"' | sed 's/^0x//'
    else
        printf '%s' "$full_hex" | evm -x | sed 's/^0x//'
    fi
}

# Patches any immutable position in simulated bytecode where the on-chain value
# equals the deployed address (padded to 32 bytes).  This handles both the
# library_deploy_address immutable (Solidity library delegatecall guard) and
# UUPSUpgradeable's __self immutable — both store address(this), which evm -x
# fills with the simulator address rather than the real deploy address.
# Args: $1=simulated_hex (no 0x), $2=artifact_path, $3=onchain_hex (no 0x), $4=deployed_address (0x-prefixed)
_patch_address_this_immutables() {
    local hex="$1" artifact="$2" onchain_hex="$3" deployed_addr="$4"
    python3 "$SCRIPT_DIR/bytecode.py" patch-lib \
        "$hex" \
        "$(jq -c '.deployedBytecode.immutableReferences // {}' "$artifact")" \
        "$onchain_hex" \
        "$deployed_addr"
}

# ---------------------------------------------------------------------------
# Core verify function
# ---------------------------------------------------------------------------

# Verifies a single deployed contract by simulating its constructor and
# comparing the result to the on-chain runtime bytecode.
# Returns 0 on match, 1 on mismatch or error.
# Args: $1=contract_key, $2=address, $3=artifact_contract, $4=libraries_str, $5...=constructor_args
_verify_contract() {
    local contract_key="$1" address="$2" artifact_contract="$3" libraries_str="$4"
    shift 4
    local constructor_args=("$@")

    local artifact_path
    artifact_path=$(_artifact_path "$artifact_contract")

    printf '  %-45s' "$contract_key"

    if [ ! -f "$artifact_path" ]; then
        echo "SKIP (artifact not found: $artifact_path)"
        return 1
    fi

    local onchain
    onchain=$(cast code "$address")
    if [ -z "$onchain" ] || [ "$onchain" = "0x" ]; then
        echo "FAIL (no code at $address)"
        return 1
    fi

    local libs_json initcode_hex linked_hex encoded_args simulated onchain_lc_hex
    libs_json=$(_build_libs_json "$libraries_str")
    initcode_hex=$(jq -r '.bytecode.object' "$artifact_path")
    linked_hex=$(_link_bytecode "${initcode_hex#0x}" "$artifact_path" "$libs_json")
    encoded_args=$(_encode_constructor_args "$artifact_path" "${constructor_args[@]+"${constructor_args[@]}"}")
    local raw_simulated
    raw_simulated=$(_run_constructor "${linked_hex}${encoded_args}")
    onchain_lc_hex=$(printf '%s' "${onchain#0x}" | tr '[:upper:]' '[:lower:]')
    simulated=$(_patch_address_this_immutables "$raw_simulated" "$artifact_path" "$onchain_lc_hex" "$address")

    local simulated_lc
    simulated_lc=$(printf '%s' "$simulated" | tr '[:upper:]' '[:lower:]')

    # Primary path: constructor simulation
    if [ -n "$simulated_lc" ] && [ "$(_strip_cbor "$simulated_lc")" = "$(_strip_cbor "$onchain_lc_hex")" ]; then
        echo "OK"
        return 0
    fi

    # Fallback: fill artifact's deployedBytecode with on-chain immutable values and
    # compare CBOR-stripped code logic.  This handles:
    #   - via_ir constructors with complex immutable write ordering (evm gives wrong order)
    #   - proxy constructors that revert in evm (delegatecall to unloaded implementation)
    #   - any other case where constructor simulation produces wrong or non-empty revert data
    local imm_refs_json onchain_imm_values filled_lc
    imm_refs_json=$(jq -c '.deployedBytecode.immutableReferences // {}' "$artifact_path")
    onchain_imm_values=$(python3 "$SCRIPT_DIR/bytecode.py" read-imm "$onchain_lc_hex" "$imm_refs_json")
    local deployed_hex linked_deployed_hex
    deployed_hex=$(jq -r '.deployedBytecode.object' "$artifact_path" | sed 's/^0x//')
    linked_deployed_hex=$(_link_deployed_bytecode "$deployed_hex" "$artifact_path" "$libs_json")
    filled_lc=$(python3 "$SCRIPT_DIR/bytecode.py" fill-imm \
        "$linked_deployed_hex" "$imm_refs_json" "$onchain_imm_values" \
        | tr '[:upper:]' '[:lower:]')
    if [ "$(_strip_cbor "$filled_lc")" = "$(_strip_cbor "$onchain_lc_hex")" ]; then
        echo "OK (deployed)"
        return 0
    fi

    echo "FAIL"
    echo "    on-chain:  0x${onchain_lc_hex:0:40}..."
    echo "    simulated: 0x${simulated_lc:0:40}..."
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$BACKFILL" = "true" ]; then
    # --backfill CONTRACT_KEY ARTIFACT LIBRARIES [ARGS...]
    contract_key="$1"; artifact_contract="$2"; libraries_str="$3"
    shift 3
    constructor_args=("$@")

    addr_var="${contract_key}_ADDRESS"
    address="${!addr_var:-}"
    [ -z "$address" ] && { echo "Error: ${addr_var} not set" >&2; exit 1; }

    echo "Verifying $contract_key ($address)..."
    if _verify_contract "$contract_key" "$address" "$artifact_contract" \
            "$libraries_str" "${constructor_args[@]+"${constructor_args[@]}"}"; then
        update_deployment_bytecode "$CHAIN" "$contract_key" "$artifact_contract" \
            "$libraries_str" "${constructor_args[@]+"${constructor_args[@]}"}"
    else
        exit 1
    fi

else
    # Verify all contracts that have stored metadata
    echo "Verifying chain $CHAIN deployments..."
    echo

    failures=0
    while IFS= read -r contract_key; do
        addr_var="${contract_key}_ADDRESS"
        address="${!addr_var:-}"
        [ -z "$address" ] && continue

        # Pinned contracts are managed out-of-band; skip ongoing verification.
        pinned=$(jq -r \
            ".[\"$CHAIN\"].contracts[\"$contract_key\"].pinned // false" \
            "$DEPLOYMENTS_JSON_PATH" 2>/dev/null)
        if [ "$pinned" = "true" ]; then
            printf '  %-45s SKIP (pinned)\n' "$contract_key"
            continue
        fi

        artifact_contract=$(jq -r \
            ".[\"$CHAIN\"].contracts[\"$contract_key\"].artifact_contract // empty" \
            "$DEPLOYMENTS_JSON_PATH" 2>/dev/null)
        if [ -z "$artifact_contract" ]; then
            printf '  %-45s SKIP (no artifact_contract; use --backfill)\n' "$contract_key"
            continue
        fi
        # Snapshot artifacts are frozen Sourcify-sourced bytecode for historical
        # deployments whose source diverged from the current repo.  They are only
        # usable for --backfill (to record the initcode_hash); the general verify
        # loop skips them because the on-chain code cannot be reproduced from
        # current source.
        case "$artifact_contract" in
            *.json)
                printf '  %-45s SKIP (snapshot artifact; source diverged from deployment)\n' "$contract_key"
                continue
                ;;
        esac

        # Rebuild "path:Name:addr,..." from stored {"path:Name": "addr"} JSON
        libraries_str=$(jq -r \
            ".[\"$CHAIN\"].contracts[\"$contract_key\"].libraries // {} | to_entries[] | \"\(.key):\(.value)\"" \
            "$DEPLOYMENTS_JSON_PATH" 2>/dev/null \
            | tr '\n' ',' | sed 's/,$//')

        stored_args=()
        while IFS= read -r arg; do
            stored_args+=("$arg")
        done < <(jq -r \
            ".[\"$CHAIN\"].contracts[\"$contract_key\"].constructor_args[]?" \
            "$DEPLOYMENTS_JSON_PATH" 2>/dev/null)

        _verify_contract "$contract_key" "$address" "$artifact_contract" \
            "$libraries_str" "${stored_args[@]+"${stored_args[@]}"}" \
            || failures=$((failures + 1))
    done < <(jq -r ".[\"$CHAIN\"].contracts | keys[]?" "$DEPLOYMENTS_JSON_PATH" 2>/dev/null)

    echo
    if [ "$failures" -eq 0 ]; then
        echo "All contracts verified OK"
    else
        echo "$failures contract(s) failed verification"
        exit 1
    fi
fi
