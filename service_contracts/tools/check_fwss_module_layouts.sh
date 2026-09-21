#!/usr/bin/env bash
# Require every production FWSSStorage descendant to have exactly the shared layout.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ $# -ne 0 ]]; then
    echo "Usage: check_fwss_module_layouts.sh (no arguments)" >&2
    exit 1
fi

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
artifact_dir=out/fwss-storage-check
inspect_args=(--json --out "$artifact_dir" --cache-path cache/fwss-storage-check)
base_target=src/storage/FWSSStorage.sol:FWSSStorage

# Compile only production sources and their dependencies, discarding stale artifacts.
forge build src --force --extra-output storageLayout \
    --out "$artifact_dir" --cache-path cache/fwss-storage-check
forge inspect "${inspect_args[@]}" "$base_target" storageLayout \
    | jq -f tools/storage_layout_snapshot.jq > "$temp_dir/base.json"
jq -e 'type == "array" and length > 0' "$temp_dir/base.json" >/dev/null

# Artifact metadata provides exact source:contract identifiers, without naming conventions.
for artifact in "$artifact_dir"/*.sol/*.json; do
    jq -r --arg artifact "$artifact" '
        (.metadata | if type == "string" then fromjson else . end)
        | .settings.compilationTarget | to_entries[]
        | select(.key | startswith("src/"))
        | [(.key + ":" + .value), $artifact] | @tsv
    ' "$artifact"
done > "$temp_dir/targets.tsv"

descendants=0
while IFS=$'\t' read -r target artifact; do
    [[ "$target" != "$base_target" ]] || continue
    forge inspect "${inspect_args[@]}" "$target" linearization > "$temp_dir/linearization.json"
    jq -e 'type == "array" and length > 0 and all(.[];
        (.source | type) == "string" and (.contract | type) == "string")' \
        "$temp_dir/linearization.json" >/dev/null
    if ! jq -e 'any(.[]; .source == "src/storage/FWSSStorage.sol" and .contract == "FWSSStorage")' \
        "$temp_dir/linearization.json" >/dev/null; then
        continue
    fi
    jq '.storageLayout' "$artifact" | jq -f tools/storage_layout_snapshot.jq > "$temp_dir/module.json"
    if ! jq -e -s '.[0] == .[1]' "$temp_dir/base.json" "$temp_dir/module.json" >/dev/null; then
        echo "Error: exact storage layout mismatch: $target" >&2
        diff -u "$temp_dir/base.json" "$temp_dir/module.json" >&2 || true
        exit 1
    fi
    echo "Exact storage layout matched FWSSStorage: $target"
    descendants=$((descendants + 1))
done < "$temp_dir/targets.tsv"

if [[ "$descendants" -eq 0 ]]; then
    echo "Error: no production FWSSStorage descendants found" >&2
    exit 1
fi
