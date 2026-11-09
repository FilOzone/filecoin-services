# Renders a Solidity interface from the ABI `josuke abi` merges from a proxy's facets.
# Unlike `cast interface`, it imports the structs and enums the facets share instead of redeclaring them, and inherits
# the standard interfaces the proxy implements, declaring only the rest.
#
# Input: the ABI
# $name: the interface name; it is generated at src/interfaces/$name.sol
# $bases: [{name, path, abi}] for each interface the proxy implements
# $sources: {type: import path} for each type the ABI names, relative to src/interfaces
# $excluded: signatures (`error Name(types)`) of members a facet declares but the proxy never uses, such as errors
#   whose names clash with errors it does raise

def sources: $sources + ($bases | map({(.name): .path}) | add);

def canonical: if .type | startswith("tuple")
    then "(\(.components | map(canonical) | join(",")))\(.type | ltrimstr("tuple"))"
    else .type end;
def signature: "\(.type) \(.name)(\(.inputs | map(canonical) | join(",")))";

# Solidity declarations
def param($location): [
    (.internalType | sub("^(struct|enum|contract) "; "")),
    (select($location and (.type | test("^(string|bytes)$|\\[|^tuple"))) | $location),
    (select(.indexed) | "indexed"),
    (select(.name != "") | .name)
] | join(" ");
def params($location): map(param($location)) | join(", ");
def declaration:
    if .type == "event" then "event \(.name)(\(.inputs | params(null)))\(if .anonymous then " anonymous" else "" end);"
    elif .type == "error" then "error \(.name)(\(.inputs | params(null)));"
    else "function \(.name)(\(.inputs | params("calldata"))) external"
        + (if .stateMutability == "nonpayable" then "" else " \(.stateMutability)" end)
        + (if .outputs == [] then "" else " returns (\(.outputs | params("memory")))" end)
        + ";"
    end;
def declarations($type): map(select(.type == $type)) | sort_by(signature)[] | "    " + declaration;

def fail_unless_empty($message): if length > 0 then error("\($message): \(join(", "))") else empty end;

map(select(.type | IN("function", "event", "error"))) as $abi
| ($abi | map(signature)) as $signatures
| ($bases | map(.abi[] | select(.type != "constructor") | signature) | unique) as $inherited
| ($abi | map(select(signature | IN($inherited[], $excluded[]) | not))) as $declared
| ($declared | map(.inputs[]?, .outputs[]? | .internalType | capture("^(struct|enum|contract) (?<name>\\w+)").name)
    + ($bases | map(.name)) | unique) as $types
| ($excluded - $signatures | fail_unless_empty("No facet declares these; drop them from the exclusions")),
  ($inherited - $signatures | fail_unless_empty("A base interface declares these, but the facets do not route them")),
  ($declared | map(select(.type == "error")) | group_by(.name) | map(select(length > 1)[0].name)
    | fail_unless_empty("These errors share a name; exclude the ones the proxy never raises")),
  ($types - (sources | keys) | fail_unless_empty("Add these types to the sources")),
  "// SPDX-License-Identifier: Apache-2.0 OR MIT",
  "pragma solidity ^0.8.20;",
  "",
  "// Code generated - DO NOT EDIT.",
  "// This file is a generated binding and any changes will be lost.",
  "// Generated with make src/interfaces/\($name).sol",
  "",
  ($types | group_by(sources[.])[] | "import {\(join(", "))} from \"\(sources[.[0]])\";"),
  "",
  "/// @title \($name)",
  "/// @notice The functions, events and errors of the facets the proxy routes to, per josuke abi.",
  "interface \($name) is \($bases | map(.name) | join(", ")) {",
  ($declared | declarations("event")),
  "",
  ($declared | declarations("error")),
  "",
  ($declared | declarations("function")),
  "}"
