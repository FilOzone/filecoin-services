#!/bin/bash
# deploy-pandora-implementation-only.sh - Deploy only PandoraService implementation (no proxy)
# This allows updating an existing proxy to point to the new implementation
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set
# Optional: PANDORA_PROXY_ADDRESS to automatically upgrade the proxy
# Assumption: forge, cast are in the PATH
# Assumption: called from service_contracts directory so forge paths work out

echo "Deploying PandoraService Implementation Only (no proxy)"

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

# Deploy PandoraService implementation
echo "Deploying PandoraService implementation..."
PANDORA_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 src/PandoraService.sol:PandoraService --optimizer-runs 1 --via-ir | grep "Deployed to" | awk '{print $3}')

if [ -z "$PANDORA_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to deploy PandoraService implementation"
    exit 1
fi

echo ""
echo "=== DEPLOYMENT COMPLETE ==="
echo "PandoraService Implementation deployed at: $PANDORA_IMPLEMENTATION_ADDRESS"
echo ""

# If proxy address is provided, perform the upgrade
if [ -n "$PANDORA_PROXY_ADDRESS" ]; then
    echo "Proxy address provided: $PANDORA_PROXY_ADDRESS"
    
    # First check if we're the owner
    echo "Checking proxy ownership..."
    PROXY_OWNER=$(cast call "$PANDORA_PROXY_ADDRESS" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
    
    if [ -z "$PROXY_OWNER" ]; then
        echo "Warning: Could not determine proxy owner. Attempting upgrade anyway..."
    else
        echo "Proxy owner: $PROXY_OWNER"
        echo "Your address: $ADDR"
        
        if [ "$PROXY_OWNER" != "$ADDR" ]; then
            echo ""
            echo "⚠️  WARNING: You are not the owner of this proxy!"
            echo "Only the owner ($PROXY_OWNER) can upgrade this proxy."
            echo ""
            echo "If you need to upgrade, you have these options:"
            echo "1. Have the owner run this script"
            echo "2. Have the owner transfer ownership to you first"
            echo "3. If the owner is a multisig, create a proposal"
            echo ""
            echo "To manually upgrade (as owner):"
            echo "cast send $PANDORA_PROXY_ADDRESS \"upgradeTo(address)\" $PANDORA_IMPLEMENTATION_ADDRESS --rpc-url \$RPC_URL"
            exit 1
        fi
    fi
    
    echo "Performing proxy upgrade..."
    
    # Increment nonce for next transaction
    NONCE=$(expr $NONCE + "1")
    
    # Call upgradeToAndCall on the proxy (works better on Filecoin)
    TX_HASH=$(cast send "$PANDORA_PROXY_ADDRESS" "upgradeToAndCall(address,bytes)" "$PANDORA_IMPLEMENTATION_ADDRESS" 0x \
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
    NEW_IMPL=$(cast rpc eth_getStorageAt "$PANDORA_PROXY_ADDRESS" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc latest --rpc-url "$RPC_URL" | sed 's/"//g' | sed 's/0x000000000000000000000000/0x/')
    
    if [ "$NEW_IMPL" = "$PANDORA_IMPLEMENTATION_ADDRESS" ]; then
        echo "✅ Upgrade successful! Proxy now points to: $PANDORA_IMPLEMENTATION_ADDRESS"
    else
        echo "⚠️  Warning: Could not verify upgrade. Please check manually."
        echo "Expected: $PANDORA_IMPLEMENTATION_ADDRESS"
        echo "Got: $NEW_IMPL"
    fi
else
    echo "No PANDORA_PROXY_ADDRESS provided. Skipping automatic upgrade."
    echo ""
    echo "To upgrade an existing proxy manually:"
    echo "1. Export the proxy address: export PANDORA_PROXY_ADDRESS=<your_proxy_address>"
    echo "2. Run this script again, or"
    echo "3. Run manually:"
    echo "   cast send <PROXY_ADDRESS> \"upgradeTo(address)\" $PANDORA_IMPLEMENTATION_ADDRESS --rpc-url \$RPC_URL --keystore \$KEYSTORE --password \$PASSWORD"
fi