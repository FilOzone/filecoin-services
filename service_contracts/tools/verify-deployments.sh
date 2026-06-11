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
    python3 - "$hex" "$(jq -c '.bytecode.linkReferences' "$artifact")" "$libs_json" <<'PYEOF'
import sys, json
hex_str = sys.argv[1]
link_refs = json.loads(sys.argv[2])
libs = json.loads(sys.argv[3])
chars = list(hex_str)
for sol_file, contracts in link_refs.items():
    for name, positions in contracts.items():
        key = f"{sol_file}:{name}"
        addr = libs.get(key)
        if addr is None:
            print(f"missing library address for {key}", file=sys.stderr)
            sys.exit(1)
        addr_hex = addr.lower().removeprefix('0x').zfill(40)
        for pos in positions:
            start = pos['start'] * 2
            chars[start:start+40] = list(addr_hex)
print(''.join(chars), end='')
PYEOF
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

# Strips the Solidity CBOR metadata trailer from a hex bytecode string (no 0x).
# The last 2 bytes are a big-endian length N; the N bytes before them are the
# CBOR data.  Stripping makes bytecode comparison metadata-hash-agnostic.
_strip_cbor() {
    local hex="$1"
    local len=${#hex}
    [ "$len" -lt 4 ] && { printf '%s' "$hex"; return; }
    local cbor_len
    cbor_len=$(printf '%d' "0x${hex: -4}")
    local strip=$(( (cbor_len + 2) * 2 ))
    [ "$strip" -ge "$len" ] && { printf '%s' "$hex"; return; }
    printf '%s' "${hex:0:$(( len - strip ))}"
}

# Patches the compiler-generated library_deploy_address immutable in a
# simulated bytecode hex string (no 0x) with the actual deployed address.
# The Solidity IR codegen stores address(this) as an immutable for all library
# contracts (for delegatecall protection); evm -x fills it with the simulator
# address rather than the real deploy address.  We know the real address, so
# patch it in before comparison to get exact verification.
# Args: $1=hex (no 0x), $2=artifact_path, $3=deployed_address (0x-prefixed)
_patch_library_deploy_address() {
    local hex="$1" artifact="$2" deployed_addr="$3"
    python3 - "$hex" "$(jq -c '.deployedBytecode.immutableReferences // {}' "$artifact")" "$deployed_addr" <<'PYEOF'
import sys, json
hex_str = sys.argv[1]
imm_refs = json.loads(sys.argv[2])
if 'library_deploy_address' not in imm_refs:
    print(hex_str, end='')
    sys.exit(0)
addr = sys.argv[3].lower().removeprefix('0x').zfill(64)
chars = list(hex_str)
for pos in imm_refs['library_deploy_address']:
    start = pos['start'] * 2
    length = pos['length'] * 2
    chars[start:start+length] = list(addr.zfill(length))
print(''.join(chars), end='')
PYEOF
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

    local libs_json initcode_hex linked_hex encoded_args simulated
    libs_json=$(_build_libs_json "$libraries_str")
    initcode_hex=$(jq -r '.bytecode.object' "$artifact_path")
    linked_hex=$(_link_bytecode "${initcode_hex#0x}" "$artifact_path" "$libs_json")
    encoded_args=$(_encode_constructor_args "$artifact_path" "${constructor_args[@]+"${constructor_args[@]}"}")
    simulated=$(_run_constructor "${linked_hex}${encoded_args}")
    simulated=$(_patch_library_deploy_address "$simulated" "$artifact_path" "$address")

    if [ "$(_strip_cbor "$simulated")" = "$(_strip_cbor "${onchain#0x}")" ]; then
        echo "OK"
        return 0
    else
        echo "FAIL"
        echo "    on-chain:  ${onchain:0:42}..."
        echo "    simulated: 0x${simulated:0:40}..."
        return 1
    fi
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

        artifact_contract=$(jq -r \
            ".[\"$CHAIN\"].contracts[\"$contract_key\"].artifact_contract // empty" \
            "$DEPLOYMENTS_JSON_PATH" 2>/dev/null)
        if [ -z "$artifact_contract" ]; then
            printf '  %-45s SKIP (no artifact_contract; use --backfill)\n' "$contract_key"
            continue
        fi

        # Rebuild "path:Name:addr,..." from stored {"path:Name": "addr"} JSON
        libraries_str=$(jq -r \
            ".[\"$CHAIN\"].contracts[\"$contract_key\"].libraries | to_entries[] | \"\(.key):\(.value)\"" \
            "$DEPLOYMENTS_JSON_PATH" 2>/dev/null \
            | tr '\n' ',' | sed 's/,$//')

        mapfile -t stored_args < <(jq -r \
            ".[\"$CHAIN\"].contracts[\"$contract_key\"].constructor_args[]?" \
            "$DEPLOYMENTS_JSON_PATH" 2>/dev/null)

        _verify_contract "$contract_key" "$address" "$artifact_contract" \
            "$libraries_str" "${stored_args[@]}" \
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
