#!/bin/bash
# warm-storage-deploy-dispatcher-transition.sh - Deploy the one-shot implementation that moves the FWSS
# proxy from the v1.4.0 monolith to the ERC-8167 dispatcher
#
# Run `josuke deploy` first: the transition pins the migration it proposed for this proxy and chain.
# Then announce the transition with warm-storage-announce-upgrade.sh and complete it with
# warm-storage-execute-upgrade.sh.
#
# Assumption: ETH_KEYSTORE, PASSWORD, ETH_RPC_URL env vars are set
# Assumption: forge, cast, jq are in the PATH, and `make erc8167` has built the dispatcher
# Assumption: called from service_contracts directory so forge paths work out
# Optional: FWSS_DISPATCHER_ADDRESS to reuse a deployed dispatcher; deployed and recorded otherwise

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"
source "$SCRIPT_DIR/josuke.sh"

DISPATCHER_ARTIFACT="lib/erc8167/out/Proxy.evm/Proxy.json"
# Runtime hash of Proxy.evm at the pinned ERC-8167 revision, as FWSSDispatcherTransition requires.
DISPATCHER_CODE_HASH="0x108d179021d554c7ad078adb0e30b9afbe6e022acfcd59ac878b2b684f29550a"

echo "Deploying the FWSS ERC-8167 dispatcher transition"

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi

if [ -z "$CHAIN" ]; then
  export CHAIN=$(cast chain-id)
  if [ -z "$CHAIN" ]; then
    echo "Error: Failed to detect chain ID from RPC"
    exit 1
  fi
fi

load_deployment_addresses "$CHAIN"

if [ -z "$FWSS_PROXY_ADDRESS" ]; then
  echo "Error: FWSS_PROXY_ADDRESS is not set"
  exit 1
fi

MIGRATION_ADDRESS=$(josuke_proposed_migration "$CHAIN" "$FWSS_PROXY_ADDRESS")
if [ -z "$MIGRATION_ADDRESS" ]; then
  echo "Error: $JOSUKE_LEDGER has no proposed migration for $FWSS_PROXY_ADDRESS on chain $CHAIN; run josuke deploy"
  exit 1
fi
echo "Josuke proposed migration: $MIGRATION_ADDRESS"

ADDR=$(cast wallet address --password "$PASSWORD")
echo "Deploying from address: $ADDR"
NONCE="$(cast nonce "$ADDR")"
BROADCAST_FLAG="--broadcast"

if [ -z "$FWSS_DISPATCHER_ADDRESS" ]; then
  if [ ! -f "$DISPATCHER_ARTIFACT" ]; then
    echo "Error: $DISPATCHER_ARTIFACT not found; run make erc8167"
    exit 1
  fi

  echo "Deploying the ERC-8167 dispatcher"
  FWSS_DISPATCHER_ADDRESS=$(cast send --password "$PASSWORD" --nonce "$NONCE" --json \
    --create "$(jq -r '.bytecode.object' "$DISPATCHER_ARTIFACT")" | jq -r '.contractAddress // empty')
  if [ -z "$FWSS_DISPATCHER_ADDRESS" ]; then
    echo "Error: Failed to deploy the dispatcher"
    exit 1
  fi
  NONCE=$((NONCE + 1))
  echo "  Deployed at: $FWSS_DISPATCHER_ADDRESS"
  update_deployment_address "$CHAIN" "FWSS_DISPATCHER_ADDRESS" "$FWSS_DISPATCHER_ADDRESS"
fi

DEPLOYED_CODE_HASH=$(cast keccak "$(cast code "$FWSS_DISPATCHER_ADDRESS")")
if [ "$DEPLOYED_CODE_HASH" != "$DISPATCHER_CODE_HASH" ]; then
  echo "Error: $FWSS_DISPATCHER_ADDRESS is not the pinned ERC-8167 dispatcher (code hash $DEPLOYED_CODE_HASH)"
  exit 1
fi

deploy_implementation_if_needed \
    "FWSS_DISPATCHER_TRANSITION_ADDRESS" \
    "src/FWSSDispatcherTransition.sol:FWSSDispatcherTransition" \
    "FWSSDispatcherTransition" \
    "dispatcher=$FWSS_DISPATCHER_ADDRESS" \
    "migration=$MIGRATION_ADDRESS"

echo ""
echo "# DEPLOYMENT COMPLETE"
echo "ERC-8167 dispatcher: $FWSS_DISPATCHER_ADDRESS"
echo "Josuke migration: $MIGRATION_ADDRESS"
echo "FWSSDispatcherTransition: $FWSS_DISPATCHER_TRANSITION_ADDRESS"
echo ""
echo "Next: josuke verify, then announce with NEW_FWSS_IMPLEMENTATION_ADDRESS=$FWSS_DISPATCHER_TRANSITION_ADDRESS"
echo ""

update_deployment_metadata "$CHAIN"

if [ "${AUTO_VERIFY:-true}" = "true" ]; then
  echo
  echo "🔍 Starting automatic contract verification..."

  pushd "$(dirname $0)/.." >/dev/null
  source $SCRIPT_DIR/verify-contracts.sh
  verify_contracts_batch \
    "$FWSS_DISPATCHER_TRANSITION_ADDRESS,src/FWSSDispatcherTransition.sol:FWSSDispatcherTransition"
  popd >/dev/null
else
  echo
  echo "⏭️  Skipping automatic verification (export AUTO_VERIFY=true to enable)"
fi
