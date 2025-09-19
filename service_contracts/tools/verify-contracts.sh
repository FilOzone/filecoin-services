#!/bin/bash

# Supports Filfox, Blockscout, and Sourcify verification with proper error handling

FILFOX_VERIFIER_VERSION="v1.4.4"

verify_filfox() {
    local address=$1
    local contract_path=$2
    local contract_name=$3
    local chain_id=${4:-314159}
    
    echo "🔍 Verifying $contract_name on Filfox..."
    if npm exec -y -- filfox-verifier@$FILFOX_VERIFIER_VERSION forge $address $contract_path --chain $chain_id; then
        echo "Filfox verification successful for $contract_name"
        return 0
    else
        echo "Filfox verification failed for $contract_name"
        return 1
    fi
}

verify_blockscout() {
    local address=$1
    local contract_path=$2
    local contract_name=$3
    local chain_id=${4:-314159}
    
    # Determine the correct Blockscout API URL based on chain ID
    local blockscout_url
    case $chain_id in
        314)
            blockscout_url="https://filecoin.blockscout.com/api/"
            ;;
        314159)
            blockscout_url="https://filecoin-testnet.blockscout.com/api/"
            ;;
        *)
            echo "Unknown chain ID $chain_id for Blockscout verification"
            return 1
            ;;
    esac
    
    echo "Verifying $contract_name on Blockscout..."
    if forge verify-contract $address $contract_path --chain-id $chain_id --verifier blockscout --verifier-url $blockscout_url 2>/dev/null; then
        echo "Blockscout verification successful for $contract_name"
        return 0
    else
        echo "Blockscout verification failed for $contract_name"
        return 1
    fi
}

verify_sourcify() {
    local address=$1
    local contract_path=$2
    local contract_name=$3
    local chain_id=${4:-314159}
    
    echo "Verifying $contract_name on Sourcify..."
    if forge verify-contract $address $contract_path --chain-id $chain_id --verifier sourcify 2>/dev/null; then
        echo "Sourcify verification successful for $contract_name"
        return 0
    else
        echo "Sourcify verification failed for $contract_name"
        return 1
    fi
}

verify_contract_all_platforms() {
    local address=$1
    local contract_path=$2
    local contract_name=$3
    local chain_id=${4:-314159}
    
    echo "Starting verification for $contract_name at $address"
    echo
    
    local filfox_success=0
    local blockscout_success=0
    local sourcify_success=0
    
    # Verify on Filfox (primary)
    verify_filfox $address $contract_path "$contract_name" $chain_id
    filfox_success=$?
    
    echo
    
    verify_blockscout $address $contract_path "$contract_name" $chain_id
    blockscout_success=$?
    
    echo
    
    verify_sourcify $address $contract_path "$contract_name" $chain_id
    sourcify_success=$?
    
    echo
    echo "Verification Summary for $contract_name:"
    echo "   Filfox: $([ $filfox_success -eq 0 ] && echo "Success" || echo "Failed")"
    echo "   Blockscout: $([ $blockscout_success -eq 0 ] && echo "Success" || echo "Failed")"
    echo "   Sourcify: $([ $sourcify_success -eq 0 ] && echo "Success" || echo "Failed")"
    echo
    
    # Return success if at least Filfox succeeded
    return $filfox_success
}

# Function to verify multiple contracts with delay
verify_contracts_batch() {
    local contracts=("$@")
    local total_contracts=$((${#contracts[@]} / 4))
    
    echo " Starting batch verification of $total_contracts contracts..."
    sleep 20
    echo
    
    local success_count=0
    local i=0
    
    while [ $i -lt ${#contracts[@]} ]; do
        local address=${contracts[$i]}
        local contract_path=${contracts[$((i+1))]}
        local contract_name=${contracts[$((i+2))]}
        local chain_id=${contracts[$((i+3))]}
        
        verify_contract_all_platforms $address $contract_path "$contract_name" $chain_id
        if [ $? -eq 0 ]; then
            success_count=$((success_count + 1))
        fi
        
        echo "----------------------------------------"
        i=$((i + 4))
    done
    
    if [ $success_count -eq $total_contracts ]; then
        echo "contracts successfully verified on Filfox"
        echo
    else
        echo "some contracts failed to verify on Filfox"
        echo
    fi
}
