#!/usr/bin/env bash
# Validate every Ethereum address in deployments.json uses EIP-55 checksum casing.
# Catches transcription errors from manual edits (e.g. PDPVerifier sync).
#
# Usage: check_deployments_checksums.sh [<deployments.json>]
# Requires: jq, cast (Foundry)

set -euo pipefail

JSON_PATH="${1:-service_contracts/deployments.json}"
ZERO="0x0000000000000000000000000000000000000000"
FAIL=0
N=0

while IFS=$'\t' read -r path value; do
    [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || continue
    [ "${value,,}" = "$ZERO" ] && continue
    N=$((N + 1))
    expected=$(cast to-check-sum-address "$value")
    if [ "$expected" != "$value" ]; then
        echo "Bad EIP-55 checksum at $path: $value (expected $expected)"
        FAIL=1
    fi
done < <(jq -r 'paths(strings) as $p | [($p | join(".")), getpath($p)] | @tsv' "$JSON_PATH")

if [ $FAIL -ne 0 ]; then
    echo "Fix with: cast to-check-sum-address <address>" >&2
    exit 1
fi

echo "All $N address(es) in $JSON_PATH are EIP-55 checksummed"
