#!/bin/bash

echo // SPDX-License-Identifier: Apache-2.0 OR MIT
echo pragma solidity ^0.8.20\;
echo
echo // Code generated - DO NOT EDIT.
echo // This file is a generated binding and any changes will be lost.
echo // Generated with $0 $@
echo

echo 'import "./FilecoinWarmStorageService.sol";'
echo 'import "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";'
echo 'import "@pdp/IPDPProvingSchedule.sol";'

echo contract FilecoinWarmStorageServiceStateView is IPDPProvingSchedule {
echo "    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;"
echo "    FilecoinWarmStorageService public immutable service;"
echo "    constructor(FilecoinWarmStorageService _service) {"
echo "        service = _service;"
echo "    }"

jq -rM 'reduce .abi.[] as {$type,$name,$inputs,$outputs,$stateMutability} (
    null;
    if $type == "function"
    then
        . += "    function " + $name + "(" +
            ( reduce $inputs.[] as {$type,$name} (
                [];
                if $type != "FilecoinWarmStorageService"
                then
                    . += [
                        $type +
                        (
                            if ($type | .[-2:] ) == "[]" or $type == "string" or $type == "bytes"
                            then
                                " memory"
                            else
                                ""
                            end
                        ) +
                        " " + $name
                    ]
                end
            ) | join(", ") ) +
        ") external " +  $stateMutability + " returns (" +
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
            ") {\n        return " + (
                if $inputs.[0].type == "FilecoinWarmStorageService"
                then
                    "service"
                else
                    "FilecoinWarmStorageServiceStateInternalLibrary"
                end
            ) +"." + $name + "(" +
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
