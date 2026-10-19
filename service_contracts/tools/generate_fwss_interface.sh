#!/bin/bash
# Generates IFilecoinWarmStorageService from the ABI `josuke abi` merges from the facets josuke.json lists, with
# generate_interface.jq. It inherits the standard interfaces FWSS implements, so callers can pass it where those are
# expected, and imports the types the facets share, so the interface and the modules agree on one type each.
#
# Usage: josuke abi <proxy> | tools/generate_fwss_interface.sh

set -euo pipefail

# The interfaces FWSS implements, as `name|import path relative to src/interfaces`
BASES=(
    "IFilecoinServiceMetadata|../IFilecoinServiceMetadata.sol"
    "IPDPProvingSchedule|@pdp/IPDPProvingSchedule.sol"
    "IValidator|@fws-payments/FilecoinPayV1.sol"
    "PDPListener|@pdp/PDPVerifier.sol"
)

# Where each type the ABI names is declared, relative to src/interfaces
SOURCES='{
    "Cids": "@pdp/Cids.sol",
    "DataSetInfoView": "../lib/FWSSViewTypes.sol",
    "DataSetStatus": "../lib/FWSSViewTypes.sol",
    "Errors": "../Errors.sol",
    "FWSSDataSetModule": "../modules/FWSSDataSetModule.sol",
    "FWSSStorage": "../storage/FWSSStorage.sol",
    "IERC20Metadata": "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol",
    "IValidator": "@fws-payments/FilecoinPayV1.sol",
    "PriceList": "../lib/PriceList.sol",
    "ServiceProviderRegistry": "../ServiceProviderRegistry.sol",
    "SessionKeyRegistry": "@session-key-registry/SessionKeyRegistry.sol"
}'

# Errors a facet declares but FWSS never raises, whose names clash with errors it does raise. One interface cannot
# declare two errors with the same name.
EXCLUDED=(
    # From erc8167's Migrate, which FWSSMigrateModule implements; it reverts with OwnableUnauthorizedAccount instead
    "error Unauthorized(address)"
)

bases=$(
    for base in "${BASES[@]}"; do
        name=${base%%|*}
        forge inspect "$name" abi --json | jq --arg name "$name" --arg path "${base#*|}" '{name: $name, path: $path, abi: .}'
    done | jq -s .
)
excluded=$(printf '%s\n' "${EXCLUDED[@]}" | jq -R . | jq -s .)

jq -r --arg name IFilecoinWarmStorageService --argjson bases "$bases" --argjson sources "$SOURCES" \
    --argjson excluded "$excluded" -f "$(dirname "$0")/generate_interface.jq" "${1:-/dev/stdin}"
