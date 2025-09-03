#!/bin/bash
# deploy-warm-storage-implementation-only.sh - Deploy only FilecoinWarmStorageService implementation (no proxy)
# This allows updating an existing proxy to point to the new implementation
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set
# Optional: WARM_STORAGE_PROXY_ADDRESS to automatically upgrade the proxy
# Optional: DEPLOY_VIEW_CONTRACT=true to deploy a new view contract during upgrade
# Optional: VIEW_CONTRACT_ADDRESS=0x... to use an existing view contract during upgrade
# Assumption: forge, cast are in the PATH
# Assumption: called from service_contracts directory so forge paths work out

echo "Deploying FilecoinWarmStorageService Implementation Only (no proxy)"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

# Get deployer address
ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying from address: $ADDR"

# Get current nonce
NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

# Get required addresses from environment or use defaults
if [ -z "$PDP_VERIFIER_ADDRESS" ]; then
  echo "Error: PDP_VERIFIER_ADDRESS is not set"
  exit 1
fi

if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
  echo "Error: PAYMENTS_CONTRACT_ADDRESS is not set"
  exit 1
fi

if [ -z "$FILCDN_CONTROLLER_ADDRESS" ]; then
  echo "Warning: FILCDN_CONTROLLER_ADDRESS not set, using default"
  FILCDN_CONTROLLER_ADDRESS="0xff0000000000000000000000000000000002870c"
fi

if [ -z "$FILCDN_BENEFICIARY_ADDRESS" ]; then
  echo "Warning: FILCDN_BENEFICIARY_ADDRESS not set, using default"
  FILCDN_BENEFICIARY_ADDRESS="0xff0000000000000000000000000000000002870c"
fi

if [ -z "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" ]; then
  echo "Error: SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS is not set"
  exit 1
fi

if [ -z "$SESSION_KEY_REGISTRY_ADDRESS" ]; then
  echo "Error: SESSION_KEY_REGISTRY_ADDRESS is not set"
  exit 1
fi

USDFC_TOKEN_ADDRESS="0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"    # USDFC token address on calibnet

# Deploy FilecoinWarmStorageService implementation
echo "Deploying FilecoinWarmStorageService implementation..."
echo "Constructor arguments:"
echo "  PDPVerifier: $PDP_VERIFIER_ADDRESS"
echo "  Payments: $PAYMENTS_CONTRACT_ADDRESS"
echo "  USDFC Token: $USDFC_TOKEN_ADDRESS"
echo "  FilCDN Controller Address: $FILCDN_CONTROLLER_ADDRESS"
echo "  FilCDN Beneficiary Address: $FILCDN_BENEFICIARY_ADDRESS"
echo "  ServiceProviderRegistry: $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "  SessionKeyRegistry: $SESSION_KEY_REGISTRY_ADDRESS"

WARM_STORAGE_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService --constructor-args $PDP_VERIFIER_ADDRESS $PAYMENTS_CONTRACT_ADDRESS $USDFC_TOKEN_ADDRESS $FILCDN_CONTROLLER_ADDRESS $FILCDN_BENEFICIARY_ADDRESS $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS $SESSION_KEY_REGISTRY_ADDRESS | grep "Deployed to" | awk '{print $3}')

if [ -z "$WARM_STORAGE_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to deploy FilecoinWarmStorageService implementation"
    exit 1
fi

echo ""
echo "# DEPLOYMENT COMPLETE"
echo "FilecoinWarmStorageService Implementation deployed at: $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
echo ""

# If proxy address is provided, perform the upgrade
if [ -n "$WARM_STORAGE_PROXY_ADDRESS" ]; then
    echo "Proxy address provided: $WARM_STORAGE_PROXY_ADDRESS"

    # First check if we're the owner
    echo "Checking proxy ownership..."
    PROXY_OWNER=$(cast call "$WARM_STORAGE_PROXY_ADDRESS" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")

    if [ -z "$PROXY_OWNER" ]; then
        echo "Warning: Could not determine proxy owner. Attempting upgrade anyway..."
    else
        echo "Proxy owner: $PROXY_OWNER"
        echo "Your address: $ADDR"

        if [ "$PROXY_OWNER" != "$ADDR" ]; then
            echo
            echo "⚠️  WARNING: You are not the owner of this proxy!"
            echo "Only the owner ($PROXY_OWNER) can upgrade this proxy."
            echo
            echo "If you need to upgrade, you have these options:"
            echo "1. Have the owner run this script"
            echo "2. Have the owner transfer ownership to you first"
            echo "3. If the owner is a multisig, create a proposal"
            echo
            echo "To manually upgrade (as owner):"
            echo "cast send $WARM_STORAGE_PROXY_ADDRESS \"upgradeTo(address)\" $WARM_STORAGE_IMPLEMENTATION_ADDRESS --rpc-url \$RPC_URL"
            exit 1
        fi
    fi

    echo "Performing proxy upgrade..."

    # Check if we should deploy and set a new view contract
    if [ -n "$DEPLOY_VIEW_CONTRACT" ] && [ "$DEPLOY_VIEW_CONTRACT" = "true" ]; then
        echo "Deploying new view contract for upgraded proxy..."
        NONCE=$(expr $NONCE + "1")
        export WARM_STORAGE_SERVICE_ADDRESS=$WARM_STORAGE_PROXY_ADDRESS
        source tools/deploy-warm-storage-view.sh
        echo "New view contract deployed at: $WARM_STORAGE_VIEW_ADDRESS"

        # Prepare migrate call with view contract address
        MIGRATE_DATA=$(cast calldata "migrate(address)" "$WARM_STORAGE_VIEW_ADDRESS")
    else
        # Check if a view contract address was provided
        if [ -n "$VIEW_CONTRACT_ADDRESS" ]; then
            echo "Using provided view contract address: $VIEW_CONTRACT_ADDRESS"
            MIGRATE_DATA=$(cast calldata "migrate(address)" "$VIEW_CONTRACT_ADDRESS")
        else
            echo "No view contract address provided, using address(0) in migrate"
            MIGRATE_DATA=$(cast calldata "migrate(address)" "0x0000000000000000000000000000000000000000")
        fi
    fi

    # Increment nonce for next transaction
    NONCE=$(expr $NONCE + "1")

    # Call upgradeToAndCall on the proxy with migrate function
    echo "Upgrading proxy and calling migrate..."
    TX_HASH=$(cast send "$WARM_STORAGE_PROXY_ADDRESS" "upgradeToAndCall(address,bytes)" "$WARM_STORAGE_IMPLEMENTATION_ADDRESS" "$MIGRATE_DATA" \
        --rpc-url "$RPC_URL" \
        --keystore "$KEYSTORE" \
        --password "$PASSWORD" \
        --nonce "$NONCE" \
        --chain-id 314159 \
        --json | jq -r '.transactionHash')

    if [ -z "$TX_HASH" ]; then
        echo "Error: Failed to send upgrade transaction"
        echo "The transaction may have failed due to:"
        echo "- Insufficient permissions (not owner)"
        echo "- Proxy is paused or locked"
        echo "- Implementation address is invalid"
        exit 1
    fi

    echo "Upgrade transaction sent: $TX_HASH"
    echo "Waiting for confirmation..."

    # Wait for transaction receipt
    cast receipt --rpc-url "$RPC_URL" "$TX_HASH" --confirmations 1 > /dev/null

    # Verify the upgrade by checking the implementation address
    echo "Verifying upgrade (waiting for Filecoin 30s block time)..."
    sleep 35
    NEW_IMPL=$(cast rpc eth_getStorageAt "$WARM_STORAGE_PROXY_ADDRESS" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc latest --rpc-url "$RPC_URL" | sed 's/"//g' | sed 's/0x000000000000000000000000/0x/')

    if [ "$NEW_IMPL" = "$WARM_STORAGE_IMPLEMENTATION_ADDRESS" ]; then
        echo "✅ Upgrade successful! Proxy now points to: $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
    else
        echo "⚠️  Warning: Could not verify upgrade. Please check manually."
        echo "Expected: $WARM_STORAGE_IMPLEMENTATION_ADDRESS"
        echo "Got: $NEW_IMPL"
    fi
else
    echo "No WARM_STORAGE_PROXY_ADDRESS provided. Skipping automatic upgrade."
    echo ""
    echo "To upgrade an existing proxy manually:"
    echo "1. Export the proxy address: export WARM_STORAGE_PROXY_ADDRESS=<your_proxy_address>"
    echo "2. Run this script again, or"
    echo "3. Run manually:"
    echo "   cast send <PROXY_ADDRESS> \"upgradeTo(address)\" $WARM_STORAGE_IMPLEMENTATION_ADDRESS --rpc-url \$RPC_URL --keystore \$KEYSTORE --password \$PASSWORD"
fi
