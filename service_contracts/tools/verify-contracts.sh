#!/bin/bash

# Supports Blockscout, and Sourcify verification with proper error handling

if [ -z "$CHAIN" ]; then
  export CHAIN=$(cast chain-id)
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

verify_blockscout() {
  local address="$1"
  local contract_path="$2"
  local display_name="$3"
  
  # Use display_name if provided, otherwise extract from contract_path
  if [ -z "$display_name" ]; then
    display_name=$(echo "$contract_path" | cut -d ':' -f 2)
  fi

  # Determine the correct Blockscout API URL based on chain ID
  local blockscout_url
  case $CHAIN in
  314)
    blockscout_url="https://filecoin.blockscout.com/api/"
    ;;
  314159)
    blockscout_url="https://filecoin-testnet.blockscout.com/api/"
    ;;
  *)
    echo "Unknown chain ID $CHAIN for Blockscout verification"
    return 1
    ;;
  esac

  echo "Verifying $display_name on Blockscout..."
  if forge verify-contract "$address" "$contract_path" --chain "$CHAIN" --verifier blockscout --verifier-url "$blockscout_url" 2>/dev/null; then
    echo "Blockscout verification successful for $display_name"
    return 0
  else
    echo "Blockscout verification failed for $display_name"
    return 1
  fi
}

verify_sourcify() {
  local address="$1"
  local contract_path="$2"
  local display_name="$3"
  
  # Use display_name if provided, otherwise extract from contract_path
  if [ -z "$display_name" ]; then
    display_name=$(echo "$contract_path" | cut -d ':' -f 2)
  fi

  echo "Verifying $display_name on Sourcify (chain ID: $CHAIN)..."
  if forge verify-contract "$address" "$contract_path" --chain "$CHAIN" --verifier sourcify 2>/dev/null; then
    echo "Sourcify verification successful for $display_name"
    return 0
  else
    echo "Sourcify verification failed for $display_name"
    return 1
  fi
}

# Function to verify multiple contracts with detailed error tracking
# Usage: verify_contracts_batch "address1,contract_path1" "address2,contract_path2" ...
# Contract names are automatically extracted from contract_path (part after ':')
verify_contracts_batch() {
  local contract_specs=("$@")
  local total_contracts=${#contract_specs[@]}
  local success_count=0

  local blockscout_failures=()
  local sourcify_failures=()
  local all_success_contracts=()

  echo "Starting batch verification of $total_contracts contracts on chain ID: $CHAIN..."
  echo

  # Process each contract
  for contract_spec in "${contract_specs[@]}"; do
    IFS=',' read -r address contract_path display_name <<<"$contract_spec"
    
    # Trim whitespace
    address=$(echo "$address" | xargs)
    contract_path=$(echo "$contract_path" | xargs)
    display_name=$(echo "$display_name" | xargs)
    
    # If no display name provided, extract from contract_path
    if [ -z "$display_name" ]; then
      display_name=$(echo "$contract_path" | cut -d ':' -f 2)
    fi
    
    echo "Processing: $display_name ($address)"
    
    # Track individual verification results
    local blockscout_ok=0 sourcify_ok=0
    
    if verify_blockscout "$address" "$contract_path" "$display_name" ; then
      blockscout_ok=1
    else
      blockscout_failures+=("$display_name ($address)")
    fi
    
    if verify_sourcify "$address" "$contract_path" "$display_name" ; then
      sourcify_ok=1
    else
      sourcify_failures+=("$display_name ($address)")
    fi
    
    # Track fully successful verifications
    if [ $blockscout_ok -eq 1 ] && [ $sourcify_ok -eq 1 ]; then
      all_success_contracts+=("$display_name")
      success_count=$((success_count + 1))
    fi
  done

  # Print summary
  echo "Verification Summary for $total_contracts contracts:"
  echo "----------------------------------------"
  
  # Show successful verifications
  if [ ${#all_success_contracts[@]} -gt 0 ]; then
    echo "Successfully verified on all platforms (${#all_success_contracts[@]}/$total_contracts):"
    printf ' - %s\n' "${all_success_contracts[@]}"
  fi
  
  # Show Blockscout failures
  if [ ${#blockscout_failures[@]} -gt 0 ]; then
    echo "Blockscout verification failed for (${#blockscout_failures[@]}):"
    printf ' - %s\n' "${blockscout_failures[@]}"
  fi
  
  # Show Sourcify failures
  if [ ${#sourcify_failures[@]} -gt 0 ]; then
    echo "Sourcify verification failed for (${#sourcify_failures[@]}):"
    printf ' - %s\n' "${sourcify_failures[@]}"
  fi
  
  echo "----------------------------------------"
  
  # Return appropriate exit code
  if [ $success_count -eq $total_contracts ]; then
    echo "All contracts verified successfully on all platforms!"
    return 0
  else
    local failed_count=$((total_contracts - success_count))
    echo "$failed_count out of $total_contracts contracts had verification failures"
    return 1
  fi
}
