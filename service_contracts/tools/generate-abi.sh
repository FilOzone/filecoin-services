#!/usr/bin/env bash
set -euo pipefail

# Require contract source folder as argument 1 and output file as argument 2
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <contracts_source_folder> <output_dir>"
  exit 1
fi

SRC_DIR="$1"
OUTPUT_DIR="$2"

# Check for required commands
for cmd in forge jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo >&2 "$cmd is required but not installed."
    exit 1
  fi
done

## Gather contract names from the source directory
if [[ -d "$SRC_DIR" ]]; then
    mapfile -t contracts < <(grep -rE '^contract ' "$SRC_DIR" 2>/dev/null | sed -E 's/.*contract ([A-Za-z0-9_]+).*/\1/')
else
    contracts=()
fi

# Exit early if none found
if [[ ${#contracts[@]} -eq 0 ]]; then
    echo "No contracts found in $SRC_DIR."
    exit 0
fi

# Build contract and extract ABI
forge clean || true
forge build --force

# Extract ABI for each contract in the source directory
for contract in "${contracts[@]}"; do
    mkdir -p ${OUTPUT_DIR}/
    jq '.abi' "${SRC_DIR}/../out/${contract}.sol/${contract}.json" > "${OUTPUT_DIR}/${contract}.json"
done