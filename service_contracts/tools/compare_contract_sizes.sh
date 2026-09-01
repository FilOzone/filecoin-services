#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <current_sizes.json> <base_sizes.json>" >&2
    exit 2
fi

CURRENT="$1"
BASE="$2"

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }

for report in "$CURRENT" "$BASE"; do
    [[ -f "$report" ]] || { echo "Error: size report not found: $report" >&2; exit 1; }
    if ! jq -e '
        .schema_version == 1
        and (.contracts | type == "object")
        and all(
            .contracts[];
            type == "object"
            and (.runtime_size | type == "number")
            and (.init_size | type == "number")
            and (.runtime_limit | type == "number")
            and (.initcode_limit | type == "number")
            and (.minimum_runtime_headroom | type == "number")
            and (.runtime_headroom | type == "number")
        )
    ' "$report" >/dev/null; then
        echo "Error: invalid normalized contract-size report: $report" >&2
        exit 1
    fi
done

jq -nr --rawfile current "$CURRENT" --rawfile base "$BASE" '
    ($current | fromjson) as $current_report
    | ($base | fromjson) as $base_report
    | $current_report.contracts as $current_contracts
    | $base_report.contracts as $base_contracts
    | (($current_contracts | keys) + ($base_contracts | keys) | unique) as $keys
    | def bytes($value):
        if $value == null then "—" else "\($value) B" end;
    def delta($current; $base):
        if $current == null or $base == null then "—"
        else
            ($current - $base) as $change
            | (if $change > 0 then "+" else "" end) + "\($change) B"
        end;
    def status($current; $base):
        if $current == null then "Removed"
        elif $current.runtime_size > $current.runtime_limit
            or $current.init_size > $current.initcode_limit
            or $current.runtime_headroom < $current.minimum_runtime_headroom
        then "Policy exceeded"
        elif $base == null then "New"
        elif $current.runtime_size == $base.runtime_size and $current.init_size == $base.init_size then "Unchanged"
        elif $current.runtime_size == $base.runtime_size then
            if $current.init_size > $base.init_size then "Initcode increased" else "Initcode decreased" end
        elif $current.init_size == $base.init_size then
            if $current.runtime_size > $base.runtime_size then "Runtime increased" else "Runtime decreased" end
        else "Runtime/initcode changed"
        end;
    "| Contract | Current runtime | Base runtime | Runtime delta | Current initcode | Base initcode | Initcode delta | Current headroom | Required headroom | Status |",
    "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    (
        $keys[] as $key
        | ($current_contracts[$key] // null) as $current_contract
        | ($base_contracts[$key] // null) as $base_contract
        | "| \($key) | \(bytes($current_contract.runtime_size)) | \(bytes($base_contract.runtime_size)) | \(delta($current_contract.runtime_size; $base_contract.runtime_size)) | \(bytes($current_contract.init_size)) | \(bytes($base_contract.init_size)) | \(delta($current_contract.init_size; $base_contract.init_size)) | \(bytes($current_contract.runtime_headroom)) | \(bytes($current_contract.minimum_runtime_headroom)) | \(status($current_contract; $base_contract)) |"
    )
'
