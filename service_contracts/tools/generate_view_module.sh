#!/bin/bash
# Generates FWSSViewModule from FilecoinWarmStorageServiceStateLibrary.
# The library reads FWSS storage through service.extsload; the module runs at the proxy,
# so it reads the same slots with sload instead.
# Calls through service are external calls to self; the module must not make them,
# so dependencies come from immutables and any other service call fails generation.

set -euo pipefail

PRELUDE=$(
    cat <<'EOF'
/// @title FWSSViewModule
/// @notice Exposes FilecoinWarmStorageServiceStateLibrary getters at the FWSS proxy.
contract FWSSViewModule is IPDPProvingSchedule {
    IERC20 internal immutable usdfcTokenAddress;

    /// @param _usdfc The USDFC token reported by getPriceList.
    constructor(IERC20 _usdfc) {
        require(_usdfc != IERC20(address(0)), Errors.ZeroAddress(Errors.AddressField.USDFC));
        usdfcTokenAddress = _usdfc;
    }

    function sload(bytes32 slot) internal view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function sloadStruct(bytes32 slot, uint256 size) internal view returns (bytes32[] memory values) {
        values = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            values[i] = sload(bytes32(uint256(slot) + i));
        }
    }

    function getString(bytes32 loc) internal pure returns (string memory) {
        string storage str;
        assembly ("memory-safe") {
            str.slot := loc
        }
        return str;
    }
EOF
)

awk '
    # getString staticcalls extsloadStruct; the prelude replaces it with a storage pointer
    /^\/\/ bytes32\(bytes4\(keccak256\(abi.encodePacked\("extsloadStruct/ { next }
    /^bytes32 constant EXTSLOAD_STRUCT_SELECTOR/ { next }
    /^library FilecoinWarmStorageServiceStateLibrary \{/ { print "LIBRARY"; next }
    /^    function getString\(/ { skip = 1 }
    skip { if ($0 == "    }") { skip = 0 } next }
    { print }
' "$1" | sed \
    -e 's/^pragma solidity .*/pragma solidity 0.8.37;\
\
\/\/ Code generated - DO NOT EDIT.\
\/\/ This file is a generated binding and any changes will be lost.\
\/\/ Generated with tools\/generate_view_module.sh/' \
    -e 's#from "\./#from "../lib/#' \
    -e 's#^import "\./#import "../lib/#' \
    -e '/^import {IFilecoinWarmStorageService}/d' \
    -e '/^import {IERC20}/a\
import {IPDPProvingSchedule} from "@pdp/IPDPProvingSchedule.sol";' \
    -e 's/service\.extsloadStruct(/sloadStruct(/g' \
    -e 's/service\.extsload(/sload(/g' \
    -e 's/IERC20(address(service\.usdfcTokenAddress()))/usdfcTokenAddress/g' \
    -e 's/(IFilecoinWarmStorageService service, /(/g' \
    -e 's/(IFilecoinWarmStorageService service)/()/g' \
    -e 's/(IFilecoinWarmStorageService)/()/g' \
    -e 's/(service, /(/g' \
    -e 's/(service)/()/g' \
    -e '/@param service /d' \
    -e '/function _getDataSetMetadataValue(/,/returns/s/^        view$/        pure/' |
    # The prelude is already in module form, so it skips the rewrites above
    PRELUDE="$PRELUDE" awk -v source="$1" '
        /service\./ { print source ": unhandled external call to self: " $0 > "/dev/stderr"; failed = 1 }
        $0 == "LIBRARY" { print ENVIRON["PRELUDE"]; next }
        { print }
        END { exit failed }
    '
