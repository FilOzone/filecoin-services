#!/bin/bash

echo // SPDX-License-Identifier: Apache-2.0 OR MIT
echo pragma solidity ^0.8.20\;
echo
echo // Code generated - DO NOT EDIT.
echo // This file is a generated binding and any changes will be lost.
echo // Generated with $0 $@
echo

echo 'import {IPDPProvingSchedule} from "@pdp/IPDPProvingSchedule.sol";'
echo

echo interface IFilecoinWarmStorageServiceStateView is IPDPProvingSchedule {
jq -rM 'reduce .abi.[] as {$type,$name,$inputs,$outputs,$stateMutability} (
    [];
    if $type == "function"
    then
        . += [ "    function " + $name + "(" +
            ( reduce $inputs.[] as {$type,$name} (
                [];
                if $type != "FilecoinWarmStorageService"
                then
                    . += [$type + " " + $name]
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
            ) | join(", ") ) + ");"
        ]
    end
) | join("\n")' $1

echo }
