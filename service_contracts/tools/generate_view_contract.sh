#!/bin/bash

echo // SPDX-License-Identifier: Apache-2.0 OR MIT
echo pragma solidity ^0.8.20\;
echo
echo // Generated with $0 $@
echo

echo 'import "./FilecoinWarmStorageService.sol";'
echo 'import "./lib/FilecoinWarmStorageServiceStateLibrary.sol";'

echo contract FilecoinWarmStorageServiceStateView {
echo "    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;"
echo "    FilecoinWarmStorageService public immutable service;"
echo "    constructor(FilecoinWarmStorageService _service) {"
echo "        service = _service;"
echo "    }"

jq -rM 'reduce .abi.[] as {$type,$name,$inputs,$outputs} (
    null;
    if $type == "function"
    then
        . += "    function " + $name + "(" +
            ( reduce $inputs.[] as {$type,$name} (
                [];
                if $type != "FilecoinWarmStorageService"
                then
                    . += [$type + " " + $name]
                end
            ) | join(", ") ) +
        ") external view returns (" +
            ( reduce $outputs.[] as {$type,$name,$internalType} (
                []; 
                . += [
                    (
                        if ( $type | .[:5] ) == "tuple"
                        then
                            ( $internalType | .[7:] )
                        else
                            $type
                        end
                    )
                    + (
                        if ($type | .[-2:] ) == "[]" or $type == "string" or $type == "bytes" or $type == "tuple"
                        then
                            " memory"
                        else
                            ""
                        end
                    )
                    + (
                        if $name != ""
                        then
                            " " + $name
                        else
                            ""
                        end
                    )
                ]
            ) | join(", ") ) +
        ") {\n        return service." + $name + "(" +
            ( reduce $inputs.[] as {$name,$type} (
                [];
                if $type != "FilecoinWarmStorageService"
                then
                    . += [$name]
                end
            ) | join(", ") ) +
        ");\n    }\n"
    end
)' $1

echo }
