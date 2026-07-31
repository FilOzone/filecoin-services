#!/bin/bash

set -o pipefail

# Deploys a ServiceProviderRegistry implementation for an existing proxy.
# This script never deploys or replaces a proxy.
#
# Required:
#   ETH_RPC_URL
#   SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS (loaded from deployments.json when unset)
# Required for a live deployment (DRY_RUN=false):
#   ETH_KEYSTORE, PASSWORD
# Optional:
#   CHAIN, DRY_RUN=true|false, AUTO_VERIFY=true|false
#   EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION (default: 1.1.0)
#   EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION (default: 1.2.0)
#   EXPECTED_REINITIALIZER_VERSION (default: 3)

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/deployments.sh"

DRY_RUN="${DRY_RUN:-false}"
AUTO_VERIFY="${AUTO_VERIFY:-true}"
EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION="${EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION:-1.1.0}"
EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION="${EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION:-1.2.0}"
EXPECTED_REINITIALIZER_VERSION="${EXPECTED_REINITIALIZER_VERSION:-3}"
IMPLEMENTATION_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
CONTRACT_SPEC="src/ServiceProviderRegistry.sol:ServiceProviderRegistry"
ARTIFACT_PATH="out/ServiceProviderRegistry.sol/ServiceProviderRegistry.json"

usage() {
  cat <<'EOF'
Usage: service-provider-registry-deploy.sh

Deploys only a new ServiceProviderRegistry implementation for the existing
proxy. Set DRY_RUN=true to validate live state, derive the constructor argument,
and print the deployment plan without broadcasting.

Proxy deployment/replacement is intentionally unsupported by this upgrade tool.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h | --help)
      usage
      exit 0
      ;;
    --with-proxy)
      echo "Error: --with-proxy is not supported; this rollout must preserve the existing proxy"
      exit 1
      ;;
    *)
      echo "Error: Unknown option '$arg'"
      usage
      exit 1
      ;;
  esac
done

case "$DRY_RUN" in
  true | false) ;;
  *)
    echo "Error: DRY_RUN must be 'true' or 'false'"
    exit 1
    ;;
esac

case "$AUTO_VERIFY" in
  true | false) ;;
  *)
    echo "Error: AUTO_VERIFY must be 'true' or 'false'"
    exit 1
    ;;
esac

is_address() {
  [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

read_implementation_slot() {
  local proxy_address="$1"
  local raw_slot
  if ! raw_slot=$(cast rpc --rpc-url "$ETH_RPC_URL" \
    eth_getStorageAt "$proxy_address" "$IMPLEMENTATION_SLOT" latest 2>/dev/null); then
    return 1
  fi
  raw_slot=$(printf '%s' "$raw_slot" | tr -d '"')
  if [[ ! "$raw_slot" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    return 1
  fi
  printf '0x%s\n' "${raw_slot: -40}"
}

if [ -z "$ETH_RPC_URL" ]; then
  echo "Error: ETH_RPC_URL is not set"
  exit 1
fi

if [ -z "$CHAIN" ]; then
  if ! CHAIN=$(cast chain-id --rpc-url "$ETH_RPC_URL"); then
    echo "Error: Failed to detect chain ID from ETH_RPC_URL"
    exit 1
  fi
fi

if [[ ! "$CHAIN" =~ ^[0-9]+$ ]]; then
  echo "Error: CHAIN must be a base-10 integer"
  exit 1
fi

load_deployment_addresses "$CHAIN"

if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
  echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not set and was not found in deployments.json"
  exit 1
fi
if ! is_address "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"; then
  echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not a valid address"
  exit 1
fi

if ! CURRENT_IMPLEMENTATION=$(read_implementation_slot "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"); then
  echo "Error: Failed to read the current ServiceProviderRegistry implementation slot"
  exit 1
fi
if ! CURRENT_PROXY_VERSION=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" 'VERSION()(string)' 2>/dev/null); then
  echo "Error: Failed to read VERSION() from the ServiceProviderRegistry proxy"
  exit 1
fi
CURRENT_PROXY_VERSION=$(printf '%s' "$CURRENT_PROXY_VERSION" | tr -d '"')
if [ "$CURRENT_PROXY_VERSION" != "$EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION" ]; then
  echo "Error: Current ServiceProviderRegistry VERSION() is $CURRENT_PROXY_VERSION; expected $EXPECTED_CURRENT_SERVICE_PROVIDER_REGISTRY_VERSION"
  exit 1
fi

if ! CURRENT_REINITIALIZER_VERSION=$("$SCRIPT_DIR/get-initialized-counter.sh" \
  "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"); then
  echo "Error: Failed to read the ServiceProviderRegistry initializer counter"
  exit 1
fi
if [[ ! "$CURRENT_REINITIALIZER_VERSION" =~ ^[0-9]+$ ]]; then
  echo "Error: Invalid initializer counter returned: $CURRENT_REINITIALIZER_VERSION"
  exit 1
fi

TARGET_REINITIALIZER_VERSION=$((CURRENT_REINITIALIZER_VERSION + 1))
if [ "$TARGET_REINITIALIZER_VERSION" -ne "$EXPECTED_REINITIALIZER_VERSION" ]; then
  echo "Error: Derived reinitializer version is $TARGET_REINITIALIZER_VERSION; expected $EXPECTED_REINITIALIZER_VERSION"
  echo "The live proxy may have changed. Do not deploy or announce until the release plan is updated."
  exit 1
fi

if [ ! -f "$ARTIFACT_PATH" ]; then
  echo "Error: Contract artifact not found at $ARTIFACT_PATH; run forge build first"
  exit 1
fi
if ! jq -e '
  .abi[]
  | select(.type == "constructor")
  | (.inputs | length == 1 and .[0].type == "uint64")
' "$ARTIFACT_PATH" >/dev/null; then
  echo "Error: ServiceProviderRegistry artifact does not have the expected constructor(uint64)"
  exit 1
fi

if ! CONSTRUCTOR_ARGS=$(cast abi-encode 'constructor(uint64)' "$TARGET_REINITIALIZER_VERSION"); then
  echo "Error: Failed to encode ServiceProviderRegistry constructor arguments"
  exit 1
fi

BYTECODE=$(jq -r '.bytecode.object // empty' "$ARTIFACT_PATH")
if [[ ! "$BYTECODE" =~ ^0x[0-9a-fA-F]+$ ]]; then
  echo "Error: ServiceProviderRegistry artifact has no deployable bytecode"
  exit 1
fi
INITCODE="${BYTECODE}${CONSTRUCTOR_ARGS#0x}"
if ! INITCODE_HASH=$(cast keccak "$INITCODE"); then
  echo "Error: Failed to hash planned ServiceProviderRegistry initcode"
  exit 1
fi

echo "ServiceProviderRegistry implementation deployment plan"
echo "  Chain: $CHAIN"
echo "  Existing proxy: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "  Current implementation: $CURRENT_IMPLEMENTATION"
echo "  Current VERSION(): $CURRENT_PROXY_VERSION"
echo "  Current initializer counter: $CURRENT_REINITIALIZER_VERSION"
echo "  New implementation VERSION(): $EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION"
echo "  Constructor reinitializer version: $TARGET_REINITIALIZER_VERSION"
echo "  Constructor args: $CONSTRUCTOR_ARGS"
echo "  Planned initcode hash: $INITCODE_HASH"
echo "  Proxy deployment/replacement: disabled"

if [ "$DRY_RUN" = "true" ]; then
  echo "Dry run complete: live state, artifact, and constructor plan validated; nothing was broadcast"
  exit 0
fi

if [ -z "$ETH_KEYSTORE" ]; then
  echo "Error: ETH_KEYSTORE is not set"
  exit 1
fi
if [ -z "$PASSWORD" ]; then
  echo "Error: PASSWORD is not set"
  exit 1
fi

if ! ADDR=$(cast wallet address --keystore "$ETH_KEYSTORE" --password "$PASSWORD"); then
  echo "Error: Failed to read the deployer address from ETH_KEYSTORE"
  exit 1
fi
if ! BALANCE=$(cast balance --rpc-url "$ETH_RPC_URL" "$ADDR"); then
  echo "Error: Failed to read the deployer balance"
  exit 1
fi
if ! NONCE=$(cast nonce --rpc-url "$ETH_RPC_URL" "$ADDR"); then
  echo "Error: Failed to read the deployer nonce"
  exit 1
fi

echo "Deploying implementation from $ADDR (balance $BALANCE, nonce $NONCE)"
if ! DEPLOY_OUTPUT=$(forge create \
  --keystore "$ETH_KEYSTORE" \
  --password "$PASSWORD" \
  --rpc-url "$ETH_RPC_URL" \
  --broadcast \
  --nonce "$NONCE" \
  "$CONTRACT_SPEC" \
  --constructor-args "$TARGET_REINITIALIZER_VERSION" 2>&1); then
  echo "$DEPLOY_OUTPUT"
  echo "Error: ServiceProviderRegistry implementation deployment failed"
  exit 1
fi
echo "$DEPLOY_OUTPUT"

SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS=$(printf '%s\n' "$DEPLOY_OUTPUT" \
  | awk '/Deployed to:/ {print $3}' \
  | tail -n 1)
if ! is_address "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"; then
  echo "Error: Failed to extract the deployed ServiceProviderRegistry implementation address"
  exit 1
fi

if ! DEPLOYED_CODE=$(cast code --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"); then
  echo "Error: Failed to read deployed implementation bytecode"
  exit 1
fi
if [ "$DEPLOYED_CODE" = "0x" ]; then
  echo "Error: No bytecode found at the deployed implementation address"
  exit 1
fi

if ! DEPLOYED_VERSION=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" 'VERSION()(string)' 2>/dev/null); then
  echo "Error: Failed to read VERSION() from the deployed implementation"
  exit 1
fi
DEPLOYED_VERSION=$(printf '%s' "$DEPLOYED_VERSION" | tr -d '"')
if [ "$DEPLOYED_VERSION" != "$EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION" ]; then
  echo "Error: Deployed implementation VERSION() is $DEPLOYED_VERSION; expected $EXPECTED_NEW_SERVICE_PROVIDER_REGISTRY_VERSION"
  echo "Do not announce this implementation."
  exit 1
fi

if ! PROXIABLE_UUID=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" 'proxiableUUID()(bytes32)' 2>/dev/null); then
  echo "Error: Deployed implementation does not expose proxiableUUID()"
  exit 1
fi
if [ "$(printf '%s' "$PROXIABLE_UUID" | tr '[:upper:]' '[:lower:]')" != "$IMPLEMENTATION_SLOT" ]; then
  echo "Error: Deployed implementation returned unexpected proxiableUUID(): $PROXIABLE_UUID"
  exit 1
fi

echo "ServiceProviderRegistry implementation deployed at: $SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS"
echo "Verified VERSION(): $DEPLOYED_VERSION"
echo "Verified constructor reinitializer version from deployment plan: $TARGET_REINITIALIZER_VERSION"
echo "deployments.json was not updated; update it only after the proxy upgrade is live and verified"

if [ "$AUTO_VERIFY" = "true" ]; then
  BLOCKSCOUT_URL=""
  case "$CHAIN" in
    314) BLOCKSCOUT_URL="https://filecoin.blockscout.com/api/" ;;
    314159) BLOCKSCOUT_URL="https://filecoin-testnet.blockscout.com/api/" ;;
  esac

  echo "Submitting constructor-aware source verification"
  if ! forge verify-contract "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" "$CONTRACT_SPEC" \
    --chain "$CHAIN" \
    --constructor-args "$CONSTRUCTOR_ARGS" \
    --verifier sourcify; then
    echo "Warning: Sourcify verification submission failed"
  fi

  if [ -n "$BLOCKSCOUT_URL" ]; then
    if ! forge verify-contract "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" "$CONTRACT_SPEC" \
      --chain "$CHAIN" \
      --constructor-args "$CONSTRUCTOR_ARGS" \
      --verifier blockscout \
      --verifier-url "$BLOCKSCOUT_URL"; then
      echo "Warning: Blockscout verification submission failed"
    fi
  else
    echo "Warning: No Blockscout verifier configured for chain $CHAIN"
  fi

  # FilFox's verifier reconstructs constructor arguments from the creation
  # transaction, so no encoded-args flag is required here.
  source "$SCRIPT_DIR/verify-contracts.sh"
  if ! verify_filfox "$SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS" "$CONTRACT_SPEC"; then
    echo "Warning: FilFox verification failed"
  fi
fi
