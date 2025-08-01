# FilecoinWarmStorageService Deployment Scripts

This directory contains scripts for deploying and upgrading the FilecoinWarmStorageService contract on Calibration testnet.

## Scripts Overview

- `deploy-warm-storage-calibnet.sh` - Deploy FilecoinWarmStorageService only (requires existing PDPVerifier and Payments contracts)
- `deploy-all-warm-storage-calibnet.sh` - Deploy all contracts (PDPVerifier, Payments, and FilecoinWarmStorageService)
- `upgrade-warm-storage-calibnet.sh` - Upgrade existing FilecoinWarmStorageService contract with new proving period parameters

## Environment Variables

### Required for all scripts:
- `KEYSTORE` - Path to the Ethereum keystore file
- `PASSWORD` - Password for the keystore (can be empty string if no password)
- `RPC_URL` - RPC endpoint for Calibration testnet

### Required for specific scripts:
- `deploy-warm-storage-calibnet.sh` requires:
  - `PDP_VERIFIER_ADDRESS` - Address of deployed PDPVerifier contract
  - `PAYMENTS_CONTRACT_ADDRESS` - Address of deployed Payments contract

- `deploy-all-warm-storage-calibnet.sh` requires:
  - `CHALLENGE_FINALITY` - Challenge finality parameter for PDPVerifier

- `upgrade-warm-storage-calibnet.sh` requires:
  - `WARM_STORAGE_SERVICE_PROXY_ADDRESS` - Address of existing FilecoinWarmStorageService proxy to upgrade

### Optional proving period configuration:
- `MAX_PROVING_PERIOD` - Maximum epochs between proofs (default: 30 epochs = 15 minutes on calibnet)
- `CHALLENGE_WINDOW_SIZE` - Challenge window size in epochs (default: 15 epochs)

## Usage Examples

### Fresh Deployment (All Contracts)

```bash
export KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export CHALLENGE_FINALITY="900"

# Optional: Custom proving periods
export MAX_PROVING_PERIOD="60"        # 30 minutes instead of default 15 minutes
export CHALLENGE_WINDOW_SIZE="20"     # 20 epochs instead of default 15

./deploy-all-warm-storage-calibnet.sh
```

### Deploy FilecoinWarmStorageService Only

```bash
export KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export PDP_VERIFIER_ADDRESS="0x123..."
export PAYMENTS_CONTRACT_ADDRESS="0x456..."

./deploy-warm-storage-calibnet.sh
```

### Upgrade Existing Contract

```bash
export KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export WARM_STORAGE_SERVICE_PROXY_ADDRESS="0x789..."

# Optional: Set new proving period parameters
export MAX_PROVING_PERIOD="120"       # 1 hour
export CHALLENGE_WINDOW_SIZE="30"     # 30 epochs

./upgrade-warm-storage-calibnet.sh
```

## Contract Upgrade Process

The FilecoinWarmStorageService contract uses OpenZeppelin's upgradeable pattern. When upgrading:

1. **Deploy new implementation**: The script deploys a new implementation contract
2. **Upgrade proxy**: Uses `upgradeToAndCall` to point the proxy to the new implementation

### Important Notes for Upgrades:

- The original `initialize` function can only be called once during initial deployment
- Use `configureProvingPeriod` to set the new proving period parameters
- Storage layout is preserved - new variables are added at the end of existing storage

## Proving Period Parameters

- **Max Proving Period**: Maximum number of epochs between consecutive proofs
  - Calibnet default: 30 epochs (≈15 minutes, since calibnet has ~30 second epochs)
  - Mainnet typical: 2880 epochs (≈24 hours, since mainnet has ~30 second epochs)

- **Challenge Window Size**: Number of epochs at the end of each proving period during which proofs can be submitted
  - Calibnet default: 15 epochs
  - Must be less than Max Proving Period
  - Must be greater than 0

## Testing

Run the upgrade tests:
```bash
forge test --match-contract FilecoinWarmStorageServiceUpgradeTest
```

## Storage Layout Verification

To verify storage layout compatibility:
```bash
forge inspect src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService storageLayout
```
