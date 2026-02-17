#!/bin/bash
# multisig.sh - Shared helpers for Safe multisig operations
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/multisig.sh"
#   print_safe_transaction "$TARGET" "functionSig(...)" "$CALLDATA"

# Print a formatted Safe multisig transaction block
# Args: $1=target_address, $2=function_signature, $3=calldata, $4=value (optional, defaults to 0)
print_safe_transaction() {
    local target="$1"
    local func_sig="$2"
    local calldata="$3"
    local value="${4:-0}"

    echo ""
    echo "============================================================"
    echo "  Safe Multisig Transaction"
    echo "============================================================"
    echo "  Target:    $target"
    echo "  Function:  $func_sig"
    echo "  Calldata:  $calldata"
    echo "  Value:     $value"
    echo "============================================================"
    echo ""
    echo "Paste the calldata above into the Safe UI transaction builder."
    echo ""
}
