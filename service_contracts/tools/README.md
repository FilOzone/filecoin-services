# FilecoinWarmStorageService Deployment Scripts

This directory contains scripts for deploying and upgrading the FilecoinWarmStorageService contract on Calibration testnet and Mainnet.

## Scripts Overview

### Available Scripts

- `deploy-warm-storage-calibnet.sh` - Deploy FilecoinWarmStorageService only (requires existing PDPVerifier and Payments contracts)
- `deploy-all-warm-storage.sh` - Deploy all contracts to either Calibnet or Mainnet
- `upgrade-warm-storage-calibnet.sh` - Upgrade existing FilecoinWarmStorageService contract with new proving period parameters

### Usage

```bash
# Deploy to Calibnet
./tools/deploy-warm-storage-calibnet.sh

# Deploy all contracts
./tools/deploy-all-warm-storage.sh

# Upgrade existing deployment
./tools/upgrade-warm-storage-calibnet.sh
```

## Deployment Parameters

The following parameters are critical for proof generation and validation. They differ between **Mainnet** (production) and **Calibnet** (testing/iteration).

| Parameter | Mainnet (Production) | Calibnet (Testing) | Notes |
|-----------|----------------------|---------------------|-------|
| `DEFAULT_CHALLENGE_FINALITY` | `150` | `10` | **Security parameter.** Always set to `150` in production. Enforces that the challenge epoch is far enough in the future to prevent reorg-based attacks. See [PDP Implementation Design Doc](https://filoznotebook.notion.site/PDP-Implementation-Design-Doc-64a66516416441c69b9d8e5d63120f1c?pvs=21). |
| `DEFAULT_MAX_PROVING_PERIOD` | `2880` | `240` | **Product parameter.** Defines how often proofs must be submitted. Mainnet default is 2880 epochs ≈ 24h (one proof/day). On Calibnet we use shorter proving periods for faster iteration. See [Simple PDP Service Fault Model](https://filoznotebook.notion.site/Simple-PDP-Service-Fault-Model-1a9dc41950c180c4bdc7ef2d91db73b6?pvs=21). |
| `DEFAULT_CHALLENGE_WINDOW_SIZE` | `60` | `30` | **Security parameter.** Defines the grace window within the proving period. Typically ~2% of the proving period. On Mainnet: 60 epochs (≈2% of 2880). On Calibnet: 30 epochs. See [Simple PDP Service Fault Model](https://filoznotebook.notion.site/Simple-PDP-Service-Fault-Model-1a9dc41950c180c4bdc7ef2d91db73b6?pvs=21). |

### Quick Reference

- **Mainnet**
  ```bash
  DEFAULT_CHALLENGE_FINALITY="150"       # Production security value
  DEFAULT_MAX_PROVING_PERIOD="2880"      # 2880 epochs (≈1 proof per day)
  DEFAULT_CHALLENGE_WINDOW_SIZE="60"     # 60 epochs grace period
  ```

- **Calibnet**
  ```bash
  DEFAULT_CHALLENGE_FINALITY="10"        # Low value for fast testing (should be 150 in production)
  DEFAULT_MAX_PROVING_PERIOD="240"       # 240 epochs
  DEFAULT_CHALLENGE_WINDOW_SIZE="30"     # 30 epochs
  ```

## Environment Variables

### Required for all scripts:
These scripts now follow forge/cast's environment variable conventions. Set the following environment variables instead of passing flags:
- `ETH_KEYSTORE` - Path to the Ethereum keystore file (or keep using `KEYSTORE` and it will be mapped)
- `PASSWORD` - Password for the keystore (can be empty string if no password)
- `ETH_RPC_URL` - RPC endpoint for Calibration testnet (e.g. `https://api.calibration.node.glif.io/rpc/v1`)
- `ETH_FROM` - Optional: address to use as deployer (forge/cast default is taken from the keystore)

### Required for specific scripts:
- `deploy-warm-storage-calibnet.sh` requires:
  - `PDP_VERIFIER_PROXY_ADDRESS` - Address of deployed PDPVerifier contract
  - `PAYMENTS_CONTRACT_ADDRESS` - Address of deployed Payments contract

- `deploy-all-warm-storage.sh` requires:
  - `CHALLENGE_FINALITY` - Challenge finality parameter for PDPVerifier

- `upgrade-warm-storage-calibnet.sh` requires:
  - `WARM_STORAGE_SERVICE_PROXY_ADDRESS` - Address of existing FilecoinWarmStorageService proxy to upgrade

## Usage Examples

### Fresh Deployment (All Contracts)

```bash

export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export CHALLENGE_FINALITY="10"  # Use "150" for mainnet


# Optional: Custom proving periods
export MAX_PROVING_PERIOD="240"        # 240 epochs for calibnet, 2880 for mainnet
export CHALLENGE_WINDOW_SIZE="30"      # 30 epochs for calibnet, 60 for mainnet

./deploy-all-warm-storage.sh
```

### Deploy FilecoinWarmStorageService Only

```bash
export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export PDP_VERIFIER_ADDRESS="0x123..."
export PAYMENTS_CONTRACT_ADDRESS="0x456..."

./deploy-warm-storage-calibnet.sh
```

### Upgrade Existing Contract

```bash
export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export WARM_STORAGE_SERVICE_PROXY_ADDRESS="0x789..."

# Optional: Custom proving periods
export MAX_PROVING_PERIOD="240"        # 240 epochs for calibnet, 2880 for mainnet
export CHALLENGE_WINDOW_SIZE="30"      # 30 epochs for calibnet, 60 for mainnet

./upgrade-warm-storage-calibnet.sh
```

## Contract Upgrade Process

The FilecoinWarmStorageService contract uses OpenZeppelin's upgradeable pattern. When upgrading:

1. **Deploy new implementation**: The script deploys a new implementation contract
2. **Upgrade proxy**: Uses `upgradeToAndCall` to point the proxy to the new implementation

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
