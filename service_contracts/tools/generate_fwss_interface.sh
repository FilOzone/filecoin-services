#!/bin/bash
# Generates IFilecoinWarmStorageService from the ABI `josuke abi` merges from the facets josuke.json lists.
# Unlike `cast interface`, it imports the structs and enums the facets share instead of redeclaring them, so the
# interface and the modules agree on one type each. It inherits the standard interfaces FWSS implements, so callers
# can pass it where those are expected, and declares only the rest.
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

# Errors a facet declares but FWSS never raises, whose names clash with errors it does raise. One interface cannot
# declare two errors with the same name.
EXCLUDED_ERRORS=(
    # From erc8167's Migrate, which FWSSMigrateModule implements; it reverts with OwnableUnauthorizedAccount instead
    "Unauthorized(address)"
)

abi=$(cat "${1:-/dev/stdin}")
bases=$(
    for base in "${BASES[@]}"; do
        name=${base%%|*}
        forge inspect "$name" abi --json | jq --arg name "$name" --arg path "${base#*|}" '{name: $name, path: $path, abi: .}'
    done | jq -s .
)

excluded=$(printf 'error %s\n' "${EXCLUDED_ERRORS[@]}" | jq -R . | jq -s .)

jq -r --argjson bases "$bases" --argjson excluded "$excluded" '
    # Where each type the ABI names is declared, relative to src/interfaces
    def sources: {
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
    } + ($bases | map({(.name): .path}) | add);

    def canonical: if .type | startswith("tuple")
        then "(" + (.components | map(canonical) | join(",")) + ")" + (.type | ltrimstr("tuple"))
        else .type end;
    def signature: .type + " " + .name + "(" + (.inputs | map(canonical) | join(",")) + ")";
    def solType: .internalType | sub("^(struct|enum|contract) "; "");
    def located($location): if $location != "" and (.type | test("^(string|bytes)$|\\[|^tuple")) then " " + $location else "" end;
    def named: if .name == "" then "" else " " + .name end;
    def params($location): map(solType + located($location) + named) | join(", ");
    def eventParams: map(solType + (if .indexed then " indexed" else "" end) + named) | join(", ");
    def mutability: if .stateMutability == "nonpayable" then "" else " " + .stateMutability end;
    def returns: if (.outputs | length) == 0 then "" else " returns (" + (.outputs | params("memory")) + ")" end;

    map(select(.type == "function" or .type == "event" or .type == "error")) as $all
    | ($excluded - ($all | map(signature))) as $stale
    | if ($stale | length) > 0 then error("no facet declares " + ($stale | join(", ")) + "; drop it from EXCLUDED_ERRORS")
      else . end
    | ($all | map(select(signature as $s | $excluded | index($s) | not))) as $members
    | ([$bases[].abi[] | select(.type != "constructor") | signature] | unique) as $inherited
    | ($inherited - ($members | map(signature))) as $unrouted
    | if ($unrouted | length) > 0 then
        error("the facets do not route " + ($unrouted | join(", ")) + ", which a base interface declares")
      else . end
    | ($members | map(select(signature as $s | $inherited | index($s) | not))) as $declared
    | ($declared | map(select(.type == "error")) | group_by(.name) | map(select(length > 1) | .[0].name)) as $clashes
    | if ($clashes | length) > 0 then
        error("errors share a name: " + ($clashes | join(", ")) + "; add the ones FWSS never raises to EXCLUDED_ERRORS")
      else . end
    | (($declared | [.[] | (.inputs // [])[], (.outputs // [])[] | .internalType
        | capture("^(struct|enum|contract) (?<name>[A-Za-z0-9_]+)").name]) + ($bases | map(.name)) | unique) as $types
    | ($types - (sources | keys)) as $unknown
    | if ($unknown | length) > 0 then
        error("no source for " + ($unknown | join(", ")) + "; add it to sources in tools/generate_fwss_interface.sh")
      else . end
    | (
        "// SPDX-License-Identifier: Apache-2.0 OR MIT",
        "pragma solidity ^0.8.20;",
        "",
        "// Code generated - DO NOT EDIT.",
        "// This file is a generated binding and any changes will be lost.",
        "// Generated with make src/interfaces/IFilecoinWarmStorageService.sol",
        "",
        ($types | group_by(sources[.]) | sort_by(sources[.[0]]) | .[]
            | "import {" + join(", ") + "} from \"" + sources[.[0]] + "\";"),
        "",
        "/// @title IFilecoinWarmStorageService",
        "/// @notice The functions, events and errors of the facets FWSS routes to, per josuke abi.",
        "interface IFilecoinWarmStorageService is " + ($bases | map(.name) | join(", ")) + " {",
        ($declared | map(select(.type == "event")) | sort_by(.name) | .[]
            | "    event " + .name + "(" + (.inputs | eventParams) + ")" + (if .anonymous then " anonymous" else "" end) + ";"),
        "",
        ($declared | map(select(.type == "error")) | sort_by(.name) | .[] | "    error " + .name + "(" + (.inputs | params("")) + ");"),
        "",
        ($declared | map(select(.type == "function")) | sort_by(.name, (.inputs | map(canonical) | join(","))) | .[]
            | "    function " + .name + "(" + (.inputs | params("calldata")) + ") external" + mutability + returns + ";"),
        "}"
    )
' <<<"$abi"
