# FilecoinWarmStorageService Deployment Scripts

This directory contains scripts for deploying, upgrading, and operating the FilecoinWarmStorageService contract on Calibration testnet and Mainnet.

> **For the self-contained FWSS upgrade runbook and release issue template**, see [UPGRADE-CHECKLIST.md](./UPGRADE-CHECKLIST.md).
>
> **For syncing a new PDPVerifier release** (bumping the submodule, ABI, and recorded address), see [PDP-VERIFIER-SYNC.md](./PDP-VERIFIER-SYNC.md).

## Scripts Overview

Scripts are organized with prefixes for better discoverability:

### Warm Storage Scripts

| Script | Description |
|--------|-------------|
| `warm-storage-deploy-all.sh` | Plan and deploy every changed, unpinned Warm Storage component using reviewed deployment metadata; pinned components are preserved |
| `warm-storage-deploy-implementation.sh` | Deploy FWSS implementation only (for upgrades) |
| `warm-storage-deploy-view.sh` | Deploy FilecoinWarmStorageServiceStateView |
| `warm-storage-announce-upgrade.sh` | Announce a planned FWSS upgrade |
| `warm-storage-execute-upgrade.sh` | Execute a previously announced FWSS upgrade |
| `warm-storage-manage-approved-provider.sh` | Inspect approved SPs, generate Safe calldata, or propose add/remove transactions through Filecoin Safe tx-service |
| `warm-storage-set-view.sh` | Set the StateView address on FWSS |

### ERC-8167 Transition Forge Scripts

These live in `../script/` and run with `forge script` from `service_contracts/`. See [ERC-8167 Dispatcher Transition](#erc-8167-dispatcher-transition) for the sequence.

| Script | Description |
|--------|-------------|
| `script/FWSSDispatcherTransitionDeploy.s.sol` | Deploy the ERC-8167 dispatcher if `deployments.json` has none, then `FWSSDispatcherTransition` pinned to josuke's proposed migration and the proxy's current implementation; records both in `deployments.json` |
| `script/FWSSDispatcherTransitionExecute.s.sol` | Check an announced transition against `josuke.json` and the proxy, then send `upgradeToAndCall(transition, migrate(migration))` or print Safe calldata |

### Service Provider Registry Scripts

| Script | Description |
|--------|-------------|
| `service-provider-registry-announce-upgrade.sh` | Announce a planned registry upgrade |
| `service-provider-registry-execute-upgrade.sh` | Execute a previously announced registry upgrade |

### Ownership Management Scripts

| Script | Description |
|--------|-------------|
| `transfer-ownership.sh` | Transfer ownership of FWSS and ServiceProviderRegistry proxies to a new owner |

### Code Generation Scripts

These scripts are invoked by `make gen` (via `Makefile` rules) and should not normally need to be run directly.

| Script | Description |
|--------|-------------|
| [`generate_storage_layout.sh`](generate_storage_layout.sh) `<contract-id>` | Reads the compiled storage layout of a contract via `forge inspect --json <contract-id> storageLayout` (where `<contract-id>` is a Forge contract identifier like `src/File.sol:ContractName`) and emits a Solidity file declaring one `bytes32 constant <VAR>_SLOT` per state variable. The constant value is the decimal slot index cast to `bytes32`. Used to produce [`src/lib/FilecoinWarmStorageServiceLayout.sol`](../src/lib/FilecoinWarmStorageServiceLayout.sol). |
| [`generate_view_contract.sh`](generate_view_contract.sh) `<abi.json>` | Reads a compiled contract's ABI JSON and emits a Solidity view contract that wraps each `function` entry by delegating to `FilecoinWarmStorageServiceStateInternalLibrary`. Used to produce [`src/FilecoinWarmStorageServiceStateView.sol`](../src/FilecoinWarmStorageServiceStateView.sol). |

#### When to regenerate

Run `make gen` (from the `service_contracts/` directory) and commit the results whenever you:
- Add, remove, or reorder state variables in [`src/FilecoinWarmStorageService.sol`](../src/FilecoinWarmStorageService.sol) (affects [`src/lib/FilecoinWarmStorageServiceLayout.sol`](../src/lib/FilecoinWarmStorageServiceLayout.sol))
- Add or modify public view functions in [`src/lib/FilecoinWarmStorageServiceStateLibrary.sol`](../src/lib/FilecoinWarmStorageServiceStateLibrary.sol) (affects [`src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol`](../src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol) and [`src/FilecoinWarmStorageServiceStateView.sol`](../src/FilecoinWarmStorageServiceStateView.sol))

The `check-gen` CI job ([`.github/workflows/check.yml`](../../.github/workflows/check.yml)) runs on every pull request and push to `main`. It regenerates all files and fails the build if the output differs from what is committed.

### Other Scripts

| Script | Description |
|--------|-------------|
| `session-key-registry-deploy.sh` | Deploy SessionKeyRegistry |
| `provider-id-set-deploy.sh` | Deploy ProviderIdSet |
| `check_deployments_checksums.sh` | Validate EIP-55 checksum casing for every address in `deployments.json`. Run by the `check-deployments` CI job. |

### GitHub Workflows

| Workflow | Description |
|--------|-------------|
| `.github/workflows/manage-approved-provider.yml` | Validate or propose add/remove Approved SP transactions through Filecoin Safe Transaction Service |

### Usage

```bash
# Plan every changed, unpinned component for an existing deployment
DEPLOYMENT_MODE=upgrade DRY_RUN=true ./tools/warm-storage-deploy-all.sh

# After approving the exact inventory, deploy it without replacing proxies
DEPLOYMENT_MODE=upgrade DRY_RUN=false ./tools/warm-storage-deploy-all.sh

# Upgrade existing deployment (see UPGRADE-CHECKLIST.md for the full runbook)
./tools/warm-storage-announce-upgrade.sh    # Step 1: Announce
./tools/warm-storage-execute-upgrade.sh     # Step 2: Execute (after the observed afterEpoch)
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
- `warm-storage-deploy-all.sh` requires:
  - Optional: `CHALLENGE_FINALITY` - Challenge finality parameter for PDPVerifier. Defaults to `10` on calibnet/devnet and `150` on mainnet.

- Upgrade scripts - see [UPGRADE-CHECKLIST.md](./UPGRADE-CHECKLIST.md) for the complete FWSS upgrade runbook

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

### Upgrade Existing Contract

See [UPGRADE-CHECKLIST.md](./UPGRADE-CHECKLIST.md) for the complete two-step FWSS upgrade workflow.

## Contract Upgrade Process

The FilecoinWarmStorageService and ServiceProviderRegistry contracts use a **two-step upgrade process** for security. The normal FWSS flow is:

1. **Announce**: Call `announceUpgradePlan()` with the new implementation address and a relative delay
2. **Observe**: Read `nextUpgrade()` after the announcement lands and record its exact `afterEpoch`
3. **Execute**: After the observed epoch, call `upgradeToAndCall()` to complete the upgrade

The delay is measured from the block in which the announcement executes, so Safe signing time does not consume the requested notice window.

**For complete FWSS upgrade documentation**, including:
- Step-by-step upgrade workflows
- Environment variable reference
- Immutable dependency handling
- Verification procedures

See [UPGRADE-CHECKLIST.md](./UPGRADE-CHECKLIST.md).

### ERC-8167 Dispatcher Transition

josuke deploys the FWSS modules and the migration that routes their selectors, and `josuke.json` records them per chain. The v1.4.0 monolith can only change its implementation through its own delayed UUPS upgrade, so `FWSSDispatcherTransition` carries josuke's migration through that upgrade. The transition scripts are forge scripts in `script/`; they read `josuke.json` and never write it. Run everything from `service_contracts/` with `ETH_RPC_URL` set and `make erc8167` done.

1. `josuke deploy`, then `josuke verify`. This records the modules and the migration under `proposed` in `josuke.json`.
2. Deploy the transition:

   ```bash
   GIT_COMMIT=$(git rev-parse HEAD) forge script script/FWSSDispatcherTransitionDeploy.s.sol \
     --rpc-url "$ETH_RPC_URL" --keystore "$ETH_KEYSTORE" --password-file "$ETH_PASSWORD" \
     --broadcast --verify --verifier blockscout --verifier-url https://filecoin.blockscout.com/api/
   ```

   The script reads `FWSS_PROXY_ADDRESS` for the connected chain from `deployments.json`, the proposed migration for that proxy from `josuke.json`, and the proxy's current ERC-1967 implementation as the rollback target. It deploys the dispatcher from `lib/erc8167/out/Proxy.evm/Proxy.json` unless `FWSS_DISPATCHER_ADDRESS` is set or recorded, checks the dispatcher code hash, and deploys `FWSSDispatcherTransition` unless the recorded one has the same initcode and constructor arguments and the contract at that address pins the same previous implementation, dispatcher and migration; a record whose address has no code or other code is redeployed, and `pinned: true` on the `contracts` entry makes a mismatch an error instead. It refuses to run once the proxy already points at the dispatcher, or at a transition installed with empty upgrade data: only `migrate(migration)` or `abortTransition()` on the proxy moves it on from there. With `--broadcast` it records `FWSS_DISPATCHER_ADDRESS`, `FWSS_DISPATCHER_TRANSITION_ADDRESS`, the `contracts.FWSS_DISPATCHER_TRANSITION` metadata and the chain `metadata` in `deployments.json`, in the format `deployments.sh` reads; `GIT_COMMIT` fills `metadata.commit`. Without `--broadcast` it simulates everything and writes nothing. Commit `deployments.json`.
3. Announce with `warm-storage-announce-upgrade.sh` and `NEW_FWSS_IMPLEMENTATION_ADDRESS` set to the transition.
4. During the delay, reviewers run `josuke verify` and compare the transition's `migration()`, `migrationCodeHash()`, `dispatcher()` and `previousImplementation()` with the ledger and the proxy. A dry run of the execute script does the same checks and reports that nothing was sent:

   ```bash
   forge script script/FWSSDispatcherTransitionExecute.s.sol --rpc-url "$ETH_RPC_URL" --sender <owner>
   ```

5. Execute after the announced epoch:

   ```bash
   forge script script/FWSSDispatcherTransitionExecute.s.sol \
     --rpc-url "$ETH_RPC_URL" --keystore "$ETH_KEYSTORE" --password-file "$ETH_PASSWORD" --broadcast
   ```

   It checks that the announced plan is the transition and ready, that the transition pins the migration `josuke.json` proposes, that the migration code is unchanged since the transition was deployed, that the rollback target is the proxy's current implementation and that the dispatcher is the pinned one, then sends `upgradeToAndCall(transition, migrate(migration))`, which points the proxy at the dispatcher and runs the migration in one call. The script's post-check runs on the simulation, so confirm on chain with `cast implementation $FWSS_PROXY_ADDRESS` before `josuke accept`. With a Safe owner, `CALLDATA_ONLY=true` simulates the upgrade as the owner, then prints the transaction for the Safe UI instead of sending it. The script leaves `deployments.json` alone: it tracks UUPS implementations, and `josuke.json` records the routes from here on.
6. `josuke accept`, then commit `josuke.json`.

After the transition, upgrades are josuke migrations: `josuke deploy`, then `announceMigration(migration, delay)` and `migrate(migration)` on the proxy, then `josuke accept`.

Script inputs, all optional: `FWSS_PROXY_ADDRESS`, `FWSS_DISPATCHER_ADDRESS`, `FWSS_DISPATCHER_TRANSITION_ADDRESS` and `FWSS_VIEW_ADDRESS` override `deployments.json`; `DEPLOYMENTS_JSON_PATH` and `JOSUKE_LEDGER` point at other files, which `fs_permissions` in `foundry.toml` must allow (scratch copies go under `out/`); `CALLDATA_ONLY=true` prints Safe calldata. An empty variable counts as unset and a malformed one is an error, so a typo cannot fall back to a fresh deployment. The legacy `SKIP_LOAD_DEPLOYMENTS` and `SKIP_UPDATE_DEPLOYMENTS` flags are not read. Only `--broadcast` runs need a wallet. A dry run uses forge's default sender unless `--sender` is given, so pass the owner's address to simulate the execute step. forge 1.7.1 does not unlock the keystore for a dry run. `cast call` does, even with `--from`, and then sends the call from the keystore address (foundry-rs/foundry#17388, see #621): run josuke and the legacy announce script with `ETH_PASSWORD` set to a password file, and keep `ETH_KEYSTORE` out of the environment for read-only `cast` steps.

Broadcasting on Filecoin: `forge script` simulates against the latest state before sending, and the `fevm-foundry-kit` recommends `--skip-simulation` when that simulation misbehaves; receipts can arrive late on 30-second blocks, so add `--retries 10` and rerun with `--resume` when forge reports an empty receipt or a dropped transaction. The deploy script records `deployments.json` during the simulation, before forge sends anything, so a broadcast that fails (no wallet, unfunded key, dropped transactions) leaves records whose addresses have no code. `--resume` sends the saved transactions to exactly those addresses without rerunning the script; a plain rerun notices the missing code and deploys again, overwriting the records. Verification: `--verify --verifier blockscout --verifier-url <api>` runs with the broadcast (`https://filecoin-testnet.blockscout.com/api/` on Calibration); run `forge script ... --resume --verify --verifier sourcify` for Sourcify, and `tools/verify-contracts.sh`'s `filfox-verifier` for Filfox. The dispatcher is raw bytecode with no source to verify; forge skips it.

`josuke check` runs offline against the working tree and reports what `josuke deploy` would do, including facets it cannot deploy. Today it fails on `FWSSFilBeamModule` and `FWSSProvingModule`, whose creation code links the public `Rails` library ([wjmelements/josuke#9](https://github.com/wjmelements/josuke/issues/9)). Do not run the transition on Calibration or Mainnet until `josuke check` passes and the business modules are in.

## Ownership Transfer

The `transfer-ownership.sh` script transfers ownership of the FWSS proxy and ServiceProviderRegistry proxy to a new owner (e.g., a Safe multisig). The transfer uses OpenZeppelin's `transferOwnership(address)` — immediate, one-step, irreversible.

### Dry Run (read-only)

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export NEW_OWNER="0x6386622B4915B027900d65560b0ab84F8a1ff2AA"
DRY_RUN=true ./transfer-ownership.sh
```

### Execute Transfer

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export NEW_OWNER="0x6386622B4915B027900d65560b0ab84F8a1ff2AA"
./transfer-ownership.sh
```

The script verifies `NEW_OWNER` is a contract (not an EOA), checks the sender is the current owner of both contracts, and verifies ownership after each transfer.

## Post-Transfer: Multisig Operations

After ownership is transferred to a multisig, the upgrade and management scripts can no longer send transactions directly from an owner EOA. Use `CALLDATA_ONLY=true` to generate calldata for the Safe transaction builder, or for approved-provider changes use the dedicated GitHub workflow / helper script Safe proposal flow.

The following scripts support `CALLDATA_ONLY=true`:
- `warm-storage-announce-upgrade.sh`
- `warm-storage-execute-upgrade.sh`
- `warm-storage-manage-approved-provider.sh`
- `service-provider-registry-announce-upgrade.sh`
- `service-provider-registry-execute-upgrade.sh`
- `warm-storage-set-view.sh`

### Example: Announce an upgrade via multisig

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="0x..."
export UPGRADE_DELAY_EPOCHS="2880"
CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

This prints a formatted transaction block with the target address, function signature, and calldata to paste into the Safe UI transaction builder.

ServiceProviderRegistry v1.2.0 and later use the same relative-delay announcement flow:

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS="0xf55dDbf63F1b55c3F1D4FA7e339a68AB7b64A5eB"
export NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS="0x..."
export UPGRADE_DELAY_EPOCHS="2880"
unset AFTER_EPOCH
CALLDATA_ONLY=true ./service-provider-registry-announce-upgrade.sh
```

The mainline ServiceProviderRegistry helper no longer accepts an absolute `AFTER_EPOCH`. If a proxy is rolled back to v1.1.0 and must be rolled forward again, use the immutable [`v1.3.1-rollout.1` legacy helper](https://github.com/FilOzone/filecoin-services/blob/v1.3.1-rollout.1/service_contracts/tools/service-provider-registry-announce-upgrade.sh).


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
