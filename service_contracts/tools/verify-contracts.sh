#!/bin/bash

# Supports Filfox, Blockscout, and Sourcify verification with proper error handling

FILFOX_VERIFIER_VERSION="v1.4.4"

verify_filfox() {
  local address=$1
  local contract_path=$2
  local contract_name=$3
  local chain_id=${4:-314159}

  echo "Verifying $contract_name on Filfox..."
  if npm exec -y -- filfox-verifier@$FILFOX_VERIFIER_VERSION forge "$address" "$contract_path" --chain "$chain_id"; then
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
  if forge verify-contract "$address" "$contract_path" --chain-id "$chain_id" --verifier blockscout --verifier-url "$blockscout_url" 2>/dev/null; then
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
  if forge verify-contract "$address" "$contract_path" --chain-id "$chain_id" --verifier sourcify 2>/dev/null; then
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
  verify_filfox "$address" "$contract_path" "$contract_name" "$chain_id"
  filfox_success=$?

  echo

  verify_blockscout "$address" "$contract_path" "$contract_name" "$chain_id"
  blockscout_success=$?

  echo

  verify_sourcify "$address" "$contract_path" "$contract_name" "$chain_id"
  sourcify_success=$?

  echo
  echo "Verification Summary for $contract_name:"
  echo "   Filfox: $([ $filfox_success -eq 0 ] && echo "Success" || echo "Failed")"
  echo "   Blockscout: $([ $blockscout_success -eq 0 ] && echo "Success" || echo "Failed")"
  echo "   Sourcify: $([ $sourcify_success -eq 0 ] && echo "Success" || echo "Failed")"
  echo

  # Return success if all verifications succeeded
  if [ $filfox_success -eq 0 ] && [ $blockscout_success -eq 0 ] && [ $sourcify_success -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

# Function to verify multiple contracts with delay
# Usage: verify_contracts_batch "address1,contract_path1,contract_name1,chain_id1" "address2,contract_path2,contract_name2,chain_id2" ...
verify_contracts_batch() {
  local contract_specs=("$@")
  local total_contracts=${#contract_specs[@]}

  echo " Starting batch verification of $total_contracts contracts..."
  echo

  local success_count=0

  for contract_spec in "${contract_specs[@]}"; do
    IFS=',' read -r address contract_path contract_name chain_id <<<"$contract_spec"

    if verify_contract_all_platforms "$address" "$contract_path" "$contract_name" "$chain_id"; then
      success_count=$((success_count + 1))
    fi

    echo "----------------------------------------"
  done

  if [ "$success_count" -eq "$total_contracts" ]; then
    echo "contracts successfully verified"
    echo
  else
    echo "some contracts failed to verify see previous logs"
    echo
  fi
}
