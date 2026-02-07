# FilecoinWarmStorageService Deployment Scripts

This directory contains scripts for deploying and upgrading the FilecoinWarmStorageService contract on Calibration testnet and Mainnet.

> **For detailed upgrade procedures**, see [UPGRADE-PROCESS.md](./UPGRADE-PROCESS.md).

## Scripts Overview

Scripts are organized with prefixes for better discoverability:

### Warm Storage Scripts

| Script | Description |
|--------|-------------|
| `warm-storage-deploy-all.sh` | Deploy all contracts (PDPVerifier, FilecoinPayV1, FWSS, etc.) |
| `warm-storage-deploy-implementation.sh` | Deploy FWSS implementation only (for upgrades) |
| `warm-storage-deploy-view.sh` | Deploy FilecoinWarmStorageServiceStateView |
| `warm-storage-deploy-calibnet.sh` | Deploy FWSS only (requires existing dependencies) |
| `warm-storage-announce-upgrade.sh` | Announce a planned FWSS upgrade |
| `warm-storage-execute-upgrade.sh` | Execute a previously announced FWSS upgrade |
| `warm-storage-set-view.sh` | Set the StateView address on FWSS |

### Service Provider Registry Scripts

| Script | Description |
|--------|-------------|
| `service-provider-registry-deploy.sh` | Deploy ServiceProviderRegistry |
| `service-provider-registry-announce-upgrade.sh` | Announce a planned registry upgrade |
| `service-provider-registry-execute-upgrade.sh` | Execute a previously announced registry upgrade |

### Other Scripts

| Script | Description |
|--------|-------------|
| `session-key-registry-deploy.sh` | Deploy SessionKeyRegistry |
| `provider-id-set-deploy.sh` | Deploy ProviderIdSet |

### Usage

```bash
# Deploy all contracts
./tools/warm-storage-deploy-all.sh

# Deploy to Calibnet (FWSS only)
./tools/warm-storage-deploy-calibnet.sh

# Upgrade existing deployment (see UPGRADE-PROCESS.md for details)
./tools/warm-storage-announce-upgrade.sh    # Step 1: Announce
./tools/warm-storage-execute-upgrade.sh     # Step 2: Execute (after AFTER_EPOCH)
```

## Deployment Parameters

The following parameters are critical for proof generation and validation. They differ between **Mainnet** (production) and **Calibnet** (testing/iteration).

| Parameter | Mainnet (Production) | Calibnet (Testing) | Notes |
|-----------|----------------------|---------------------|-------|
| `DEFAULT_CHALLENGE_FINALITY` | `150` | `10` | **Security parameter.** Always set to `150` in production. Enforces that the challenge epoch is far enough in the future to prevent reorg-based attacks. See [PDP Implementation Design Doc](https://filoznotebook.notion.site/PDP-Implementation-Design-Doc-64a66516416441c69b9d8e5d63120f1c?pvs=21). |
| `DEFAULT_MAX_PROVING_PERIOD` | `2880` | `240` | **Product parameter.** Defines how often proofs must be submitted. Mainnet default is 2880 epochs ≈ 24h (one proof/day). On Calibnet we use shorter proving periods for faster iteration. See [Simple PDP Service Fault Model](https://filoznotebook.notion.site/Simple-PDP-Service-Fault-Model-1a9dc41950c180c4bdc7ef2d91db73b6?pvs=21). |
| `DEFAULT_CHALLENGE_WINDOW_SIZE` | `20` | `20` | **Security parameter.** Defines the grace window within the proving period. On Mainnet: 60 epochs. On Calibnet: 20 epochs. See [Simple PDP Service Fault Model](https://filoznotebook.notion.site/Simple-PDP-Service-Fault-Model-1a9dc41950c180c4bdc7ef2d91db73b6?pvs=21). |

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
  DEFAULT_CHALLENGE_WINDOW_SIZE="20"     # 20 epochs
  ```

## Deployment Address Management

Deployment scripts automatically load and update contract addresses in `deployments.json`, keyed by chain ID. This makes deployments easier and reduces mistakes when updating addresses downstream.

### deployments.json Structure

The `deployments.json` file stores deployment addresses organized by chain ID:

```json
{
  "314": {
    "PDP_VERIFIER_PROXY_ADDRESS": "0x...",
    "FILECOIN_PAY_ADDRESS": "0x...",
    "FWSS_PROXY_ADDRESS": "0x...",
    "metadata": {
      "commit": "abc123...",
      "deployed_at": "2024-01-01T00:00:00Z"
    }
  },
  "314159": {
    ...
  }
}
```

### How It Works

1. **Loading addresses**: Scripts automatically load addresses from `deployments.json` for the detected chain ID. If an address doesn't exist in the JSON, the script will use environment variables or fail if required.

2. **Updating addresses**: When a script deploys a new contract, it automatically updates `deployments.json` with the new address.

3. **Environment variable override**: Environment variables take precedence over values loaded from JSON, allowing you to override specific addresses when needed.

4. **Metadata tracking**: The system automatically tracks the git commit hash and deployment timestamp for each chain.

### Control Flags

- `SKIP_LOAD_DEPLOYMENTS=true` - Skip loading addresses from JSON (use only environment variables)
- `SKIP_UPDATE_DEPLOYMENTS=true` - Skip updating JSON after deployment

### Querying Addresses

You can query addresses using `jq`:

```bash
# Get all addresses for a chain
jq '.["314"]' deployments.json

# Get a specific address
jq -r '.["314"].FWSS_PROXY_ADDRESS' deployments.json
```

### Version Control

The `deployments.json` file should be committed to version control. Updates to it should be tagged as version releases.

## Environment Variables

### Required for all scripts:
These scripts now follow forge/cast's environment variable conventions. Set the following environment variables instead of passing flags:
- `ETH_KEYSTORE` - Path to the Ethereum keystore file (or keep using `KEYSTORE` and it will be mapped)
- `PASSWORD` - Password for the keystore (can be empty string if no password)
- `ETH_RPC_URL` - RPC endpoint for Calibration testnet (e.g. `https://api.calibration.node.glif.io/rpc/v1`)
- `ETH_FROM` - Optional: address to use as deployer (forge/cast default is taken from the keystore)

### Required for specific scripts:
- `warm-storage-deploy-calibnet.sh` requires:
  - `PDP_VERIFIER_PROXY_ADDRESS` - Address of deployed PDPVerifier contract
  - `FILECOIN_PAY_ADDRESS` - Address of deployed FilecoinPayV1 contract

- `warm-storage-deploy-all.sh` requires:
  - `CHALLENGE_FINALITY` - Challenge finality parameter for PDPVerifier

- Upgrade scripts - see [UPGRADE-PROCESS.md](./UPGRADE-PROCESS.md) for complete environment variable reference

## Usage Examples

### Fresh Deployment (All Contracts)

```bash

export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export CHALLENGE_FINALITY="10"  # Use "150" for mainnet


# Optional: Custom proving periods
export MAX_PROVING_PERIOD="240"        # 240 epochs for calibnet, 2880 for mainnet
export CHALLENGE_WINDOW_SIZE="20"      # 20 epochs for calibnet, 60 for mainnet

./warm-storage-deploy-all.sh
```

### Deploy FilecoinWarmStorageService Only

```bash
export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export PDP_VERIFIER_PROXY_ADDRESS="0x123..."
export FILECOIN_PAY_ADDRESS="0x456..."

./warm-storage-deploy-calibnet.sh
```

### Upgrade Existing Contract

See [UPGRADE-PROCESS.md](./UPGRADE-PROCESS.md) for the complete two-step upgrade workflow.

## Contract Upgrade Process

The FilecoinWarmStorageService and ServiceProviderRegistry contracts use a **two-step upgrade process** for security:

1. **Announce**: Call `announcePlannedUpgrade()` with the new implementation address and a future epoch
2. **Execute**: After the announced epoch, call `upgradeToAndCall()` to complete the upgrade

This gives stakeholders time to review changes before execution.

**For complete upgrade documentation**, including:
- Step-by-step upgrade workflows
- Environment variable reference
- Immutable dependency handling
- Verification procedures

See [UPGRADE-PROCESS.md](./UPGRADE-PROCESS.md).

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
