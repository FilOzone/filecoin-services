#!/usr/bin/env bash

set -euo pipefail

POLICY="contract-size-policy.json"
OUTPUT=""
CHECK=false
WRITE_GITHUB_SUMMARY=false
OFFLINE=false

usage() {
    cat <<EOF
Usage: $0 [options]

Build and measure only the deployment targets in the contract-size policy.

Options:
  --policy PATH       Policy file (default: contract-size-policy.json)
  --output PATH       Write the normalized size report to PATH
  --check             Fail when a target violates its effective policy
  --github-summary    Append the report to GITHUB_STEP_SUMMARY when available
  --offline           Pass --offline to forge build
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --policy)
            [[ $# -ge 2 ]] || { echo "Error: --policy requires a path" >&2; exit 2; }
            POLICY="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { echo "Error: --output requires a path" >&2; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        --check)
            CHECK=true
            shift
            ;;
        --github-summary)
            WRITE_GITHUB_SUMMARY=true
            shift
            ;;
        --offline)
            OFFLINE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }
command -v forge >/dev/null 2>&1 || { echo "Error: forge is required" >&2; exit 1; }

[[ -f "$POLICY" ]] || { echo "Error: policy not found: $POLICY" >&2; exit 1; }
if ! jq empty "$POLICY" >/dev/null 2>&1; then
    echo "Error: policy is not valid JSON: $POLICY" >&2
    exit 1
fi

if ! jq -e '
    def uint: type == "number" and . >= 0 and floor == .;
    def abi_size: uint and . % 32 == 0;
    def only($allowed): (keys - $allowed | length) == 0;

    type == "object"
    and only(["defaults", "targets"])
    and (
        .defaults
        | type == "object"
        and only(["runtimeLimit", "initcodeLimit", "minimumRuntimeHeadroom", "maximumConstructorArgsSize"])
        and (.runtimeLimit | uint and . > 0)
        and (.initcodeLimit | uint and . > 0)
        and (.minimumRuntimeHeadroom | uint)
        and (.maximumConstructorArgsSize | abi_size)
        and (.minimumRuntimeHeadroom <= .runtimeLimit)
    )
    and (
        .targets
        | type == "object"
        and length > 0
        and all(
            to_entries[];
            (.key | type == "string" and test("^[^\\t\\r\\n]+$"))
            and (
                .value
                | type == "object"
                and only(["artifact", "runtimeLimit", "initcodeLimit", "minimumRuntimeHeadroom", "maximumConstructorArgsSize"])
                and (.artifact | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9_./-]*\\.sol:[A-Za-z_][A-Za-z0-9_]*$"))
                and ((has("runtimeLimit") | not) or (.runtimeLimit | uint and . > 0))
                and ((has("initcodeLimit") | not) or (.initcodeLimit | uint and . > 0))
                and ((has("minimumRuntimeHeadroom") | not) or (.minimumRuntimeHeadroom | uint))
                and ((has("maximumConstructorArgsSize") | not) or (.maximumConstructorArgsSize | abi_size))
            )
        )
    )
    and (([.targets[].artifact] | length) == ([.targets[].artifact] | unique | length))
    and (
        .defaults as $defaults
        | all(
            .targets[];
            (.runtimeLimit // $defaults.runtimeLimit) as $runtime_limit
            | (.minimumRuntimeHeadroom // $defaults.minimumRuntimeHeadroom) as $headroom
            | $headroom <= $runtime_limit
        )
    )
' "$POLICY" >/dev/null; then
    echo "Error: invalid contract-size policy: $POLICY" >&2
    exit 1
fi

mapfile -t sources < <(
    jq -r '.targets[].artifact | split(":")[0]' "$POLICY" | sort -u
)

echo "Building ${#sources[@]} deployable source files..."
forge_args=(build)
if [[ "$OFFLINE" == true ]]; then
    forge_args+=(--offline)
fi
forge_args+=("${sources[@]}")
forge "${forge_args[@]}"

entries_file=$(mktemp)
temporary_report=$(mktemp)
report_file="$temporary_report"
output_tmp=""
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
    rm -f "$entries_file" "$temporary_report"
    if [[ -n "$output_tmp" ]]; then
        rm -f "$output_tmp"
    fi
}
trap cleanup EXIT

while IFS=$'\t' read -r name artifact; do
    source_path="${artifact%:*}"
    contract_name="${artifact##*:}"
    source_file="${source_path##*/}"
    artifact_file="out/${source_file}/${contract_name}.json"

    if [[ ! -f "$artifact_file" ]]; then
        echo "Error: artifact not produced for $artifact: $artifact_file" >&2
        exit 1
    fi

    creation_bytecode=$(jq -er '.bytecode.object | select(type == "string")' "$artifact_file")
    runtime_bytecode=$(jq -er '.deployedBytecode.object | select(type == "string")' "$artifact_file")

    for bytecode in "$creation_bytecode" "$runtime_bytecode"; do
        if [[ "$bytecode" != 0x* || $(( (${#bytecode} - 2) % 2 )) -ne 0 ]]; then
            echo "Error: malformed bytecode in $artifact_file" >&2
            exit 1
        fi
    done

    creation_size=$(( (${#creation_bytecode} - 2) / 2 ))
    runtime_size=$(( (${#runtime_bytecode} - 2) / 2 ))
    if [[ $creation_size -eq 0 || $runtime_size -eq 0 ]]; then
        echo "Error: deployable target has empty bytecode: $artifact" >&2
        exit 1
    fi

    IFS=$'\t' read -r runtime_limit initcode_limit minimum_runtime_headroom maximum_constructor_args_size < <(
        jq -r --arg name "$name" '
            .defaults as $defaults
            | .targets[$name]
            | [
                .runtimeLimit // $defaults.runtimeLimit,
                .initcodeLimit // $defaults.initcodeLimit,
                .minimumRuntimeHeadroom // $defaults.minimumRuntimeHeadroom,
                .maximumConstructorArgsSize // $defaults.maximumConstructorArgsSize
            ]
            | @tsv
        ' "$POLICY"
    )
    init_size=$(( creation_size + maximum_constructor_args_size ))
    minimum_constructor_args_size=$(jq -r '
        [.abi[] | select(.type == "constructor") | (.inputs | length * 32)]
        | first // 0
    ' "$artifact_file")
    if [[ $maximum_constructor_args_size -lt $minimum_constructor_args_size ]]; then
        echo "Error: maximumConstructorArgsSize for $artifact is $maximum_constructor_args_size bytes; its constructor ABI requires at least $minimum_constructor_args_size bytes" >&2
        exit 1
    fi
    runtime_headroom=$(( runtime_limit - runtime_size ))

    jq -n \
        --arg name "$name" \
        --arg artifact "$artifact" \
        --argjson runtime_size "$runtime_size" \
        --argjson creation_size "$creation_size" \
        --argjson maximum_constructor_args_size "$maximum_constructor_args_size" \
        --argjson init_size "$init_size" \
        --argjson runtime_limit "$runtime_limit" \
        --argjson initcode_limit "$initcode_limit" \
        --argjson minimum_runtime_headroom "$minimum_runtime_headroom" \
        --argjson runtime_headroom "$runtime_headroom" \
        '{
            name: $name,
            artifact: $artifact,
            runtime_size: $runtime_size,
            creation_size: $creation_size,
            maximum_constructor_args_size: $maximum_constructor_args_size,
            init_size: $init_size,
            runtime_limit: $runtime_limit,
            initcode_limit: $initcode_limit,
            minimum_runtime_headroom: $minimum_runtime_headroom,
            runtime_headroom: $runtime_headroom
        }' >> "$entries_file"
done < <(jq -r '.targets | to_entries[] | [.key, .value.artifact] | @tsv' "$POLICY")

jq -s '{
    schema_version: 1,
    contracts: (
        map({key: .name, value: del(.name)})
        | from_entries
    )
}' "$entries_file" > "$report_file"

if [[ -n "$OUTPUT" ]]; then
    output_tmp="${OUTPUT}.tmp.$$"
    cp "$report_file" "$output_tmp"
    mv "$output_tmp" "$OUTPUT"
    output_tmp=""
    report_file="$OUTPUT"
fi

echo
printf "%-42s %12s %12s %12s %12s\n" \
    "Contract" "Runtime" "Initcode" "Headroom" "Required"
printf "%-42s %12s %12s %12s %12s\n" \
    "------------------------------------------" "------------" "------------" "------------" "------------"
jq -r '
    .contracts
    | to_entries[]
    | [.key, .value.runtime_size, .value.init_size, .value.runtime_headroom, .value.minimum_runtime_headroom]
    | @tsv
' "$report_file" |
while IFS=$'\t' read -r name runtime_size init_size runtime_headroom minimum_runtime_headroom; do
    printf "%-42s %9s B %9s B %9s B %9s B\n" \
        "$name" "$runtime_size" "$init_size" "$runtime_headroom" "$minimum_runtime_headroom"
done

if [[ "$WRITE_GITHUB_SUMMARY" == true && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Contract size policy"
        echo
        echo "| Contract | Runtime | Initcode | Runtime headroom | Required headroom | Status |"
        echo "|---|---:|---:|---:|---:|---|"
        jq -r '
            .contracts
            | to_entries[]
            | .value as $v
            | (
                if $v.runtime_size > $v.runtime_limit or $v.init_size > $v.initcode_limit
                    or $v.runtime_headroom < $v.minimum_runtime_headroom
                then "FAIL"
                else "PASS"
                end
            ) as $status
            | (($v.runtime_headroom * 10000 / $v.runtime_limit | round) / 100) as $headroom_percent
            | "| \(.key) | \($v.runtime_size) B | \($v.init_size) B | \($v.runtime_headroom) B (\($headroom_percent)%) | \($v.minimum_runtime_headroom) B | \($status) |"
        ' "$report_file"
        echo
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$CHECK" != true ]]; then
    exit 0
fi

status=0
violations=$(jq -r '
    .contracts
    | to_entries[]
    | .key as $name
    | .value as $v
    | [
        if $v.runtime_size > $v.runtime_limit then
            "ERROR: \($name) runtime is \($v.runtime_size) bytes, exceeding the \($v.runtime_limit)-byte EIP-170 limit"
        elif $v.runtime_headroom < $v.minimum_runtime_headroom then
            "ERROR: \($name) runtime leaves \($v.runtime_headroom) bytes of headroom; policy requires at least \($v.minimum_runtime_headroom) bytes"
        else empty end,
        if $v.init_size > $v.initcode_limit then
            "ERROR: \($name) initcode is \($v.init_size) bytes, exceeding the \($v.initcode_limit)-byte EIP-3860 limit"
        else empty end
    ]
    | .[]
' "$report_file")

if [[ -n "$violations" ]]; then
    echo
    echo "$violations" >&2
    status=1
else
    echo
    echo "All deployable contracts satisfy the contract-size policy."
fi

exit "$status"
