#!/bin/bash

echo // SPDX-License-Identifier: Apache-2.0 OR MIT
echo pragma solidity ^0.8.20;
echo
echo // Generated with $0 $@
echo

forge inspect --json $1 storageLayout \
    | jq -rM 'reduce .storage.[] as {$label,$slot} (null; . += $label + "_SLOT = " + $slot + "\n")'
