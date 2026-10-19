#!/bin/bash
# warm-storage-deploy-all-test.sh runs warm-storage-deploy-all.sh against a fresh anvil devnet and checks the stack it
# deploys, the summary local devnet tooling parses, a rerun that reuses every address, and a dry run.
# Writes only under out/deploy-all-test; deployments.json is left alone.
# Assumption: forge, cast, anvil, jq and the evm assembler (make install-evm) are in the PATH
# Assumption: called from contracts directory so forge paths work out

set -euo pipefail

PORT="${ANVIL_PORT:-18545}"
export ETH_RPC_URL="http://127.0.0.1:$PORT"
CHAIN=31415926
# anvil's first default account
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SCRATCH=out/deploy-all-test

fail() {
    echo "❌ $*"
    exit 1
}

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

anvil --chain-id "$CHAIN" --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    if cast chain-id >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done
[ "$(cast chain-id)" = "$CHAIN" ] || fail "anvil did not start on port $PORT"

cast wallet import deployer --private-key "$DEPLOYER_KEY" --keystore-dir "$SCRATCH/keystore" \
    --unsafe-password '' >/dev/null
USDFC=$(forge create test/mocks/SharedMocks.sol:MockERC20 --broadcast --private-key "$DEPLOYER_KEY" |
    grep "Deployed to" | awk '{print $3}')
[ -n "$USDFC" ] || fail "MockUSDFC deployment failed"

# Devnet tooling clears the chain's cached addresses before deploying
jq --arg chain "$CHAIN" 'del(.[$chain])' deployments.json > "$SCRATCH/deployments.json"

deploy_all() {
    ETH_KEYSTORE="$SCRATCH/keystore/deployer" PASSWORD='' AUTO_VERIFY=false USDFC_TOKEN_ADDRESS="$USDFC" \
        DEPLOYMENTS_JSON_PATH="$1" DRY_RUN="$2" bash tools/warm-storage-deploy-all.sh
}

# Prints the address on a "<label>: 0x..." summary line, as devnet tooling reads it
summary() {
    grep -E "^$1: 0x[0-9a-fA-F]{40}$" "$SCRATCH/deploy.log" | awk '{print $NF}'
}

lower() {
    tr '[:upper:]' '[:lower:]'
}

echo "== Deploy"
deploy_all "$SCRATCH/deployments.json" false | tee "$SCRATCH/deploy.log"

for label in \
    "PDPVerifier Implementation" "PDPVerifier Proxy" "FilecoinPayV1 Contract" \
    "ServiceProviderRegistry Implementation" "ServiceProviderRegistry Proxy" "SessionKeyRegistry" \
    "FilecoinWarmStorageService Implementation" "FilecoinWarmStorageService Proxy" \
    "FilecoinWarmStorageService StateView" "Endorsements"; do
    address=$(summary "$label")
    [ -n "$address" ] || fail "summary has no address for $label"
    [ "$(cast code "$address")" != "0x" ] || fail "$label $address has no code"
done

FWSS=$(summary "FilecoinWarmStorageService Proxy")
[ "$(jq -r --arg chain "$CHAIN" '.[$chain].FWSS_PROXY_ADDRESS' "$SCRATCH/deployments.json")" = "$FWSS" ] ||
    fail "deployments.json does not record the FWSS proxy"

check() {
    local actual
    actual=$(cast call "$FWSS" "$1" | lower)
    [ "$actual" = "$(printf '%s' "$2" | lower)" ] || fail "$1 returned $actual, expected $2"
}

[ "$(cast implementation "$FWSS" | lower)" = "$(summary "FilecoinWarmStorageService Implementation" | lower)" ] ||
    fail "the FWSS proxy does not run the dispatcher"
check "owner()(address)" "$DEPLOYER"
check "pdpVerifierAddress()(address)" "$(summary "PDPVerifier Proxy")"
check "paymentsContractAddress()(address)" "$(summary "FilecoinPayV1 Contract")"
check "serviceProviderRegistry()(address)" "$(summary "ServiceProviderRegistry Proxy")"
check "sessionKeyRegistry()(address)" "$(summary "SessionKeyRegistry")"
check "usdfcTokenAddress()(address)" "$USDFC"
check "viewContractAddress()(address)" "$FWSS"
check "filBeamControllerAddress()(address)" 0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A
[ "$(cast call "$FWSS" "getPDPConfig()(uint64,uint256,uint256,uint256)" | head -2 | tr '\n' ' ')" = "120 10 " ] ||
    fail "FWSS does not use the devnet proving period"

echo "== Rerun reuses every address"
nonce=$(cast nonce "$DEPLOYER")
deploy_all "$SCRATCH/deployments.json" false > "$SCRATCH/rerun.log"
[ "$(cast nonce "$DEPLOYER")" = "$nonce" ] || fail "the rerun sent transactions"

echo "== SKIP_UPDATE_DEPLOYMENTS deploys without writing"
jq --arg chain "$CHAIN" 'del(.[$chain].FWSS_PROXY_ADDRESS)' "$SCRATCH/deployments.json" > "$SCRATCH/skip.json"
cp "$SCRATCH/skip.json" "$SCRATCH/skip.before.json"
SKIP_UPDATE_DEPLOYMENTS=true deploy_all "$SCRATCH/skip.json" false > "$SCRATCH/skip.log"
cmp -s "$SCRATCH/skip.json" "$SCRATCH/skip.before.json" || fail "SKIP_UPDATE_DEPLOYMENTS wrote deployments.json"
skipped=$(grep -E "^FilecoinWarmStorageService Proxy: 0x[0-9a-fA-F]{40}$" "$SCRATCH/skip.log" | awk '{print $NF}')
[ -n "$skipped" ] && [ "$skipped" != "$FWSS" ] || fail "SKIP_UPDATE_DEPLOYMENTS did not deploy a new FWSS proxy"
[ "$(cast call "$skipped" "owner()(address)" | lower)" = "$(printf '%s' "$DEPLOYER" | lower)" ] ||
    fail "the FWSS proxy deployed with SKIP_UPDATE_DEPLOYMENTS does not work"
nonce=$(cast nonce "$DEPLOYER")

echo "== Dry run plans without writing"
jq --arg chain "$CHAIN" 'del(.[$chain])' deployments.json > "$SCRATCH/dry.json"
cp "$SCRATCH/dry.json" "$SCRATCH/dry.before.json"
deploy_all "$SCRATCH/dry.json" true > "$SCRATCH/dry.log"
cmp -s "$SCRATCH/dry.json" "$SCRATCH/dry.before.json" || fail "the dry run wrote deployments.json"
[ "$(cast nonce "$DEPLOYER")" = "$nonce" ] || fail "the dry run sent transactions"

echo "✅ warm-storage-deploy-all.sh deployed a working stack"
