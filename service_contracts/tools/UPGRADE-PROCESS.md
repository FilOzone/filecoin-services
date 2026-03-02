# FWSS Contract Upgrade Process

This document describes the upgrade process for FilecoinWarmStorageService (FWSS), organized as a phase-based runbook. This runbook is optimized for FWSS upgrades and assumes deployment via GitHub Actions and owner actions through Safe multisig.

## Scope and Defaults

- Scope: FWSS-only main path (ServiceProviderRegistry and StateView are optional; see [Upgrading Other Contracts](#upgrading-other-contracts)).
- Deployment path: GitHub Actions [Deploy Contract](https://github.com/FilOzone/filecoin-services/actions/workflows/deploy-contract.yml).
- Owner actions (`onlyOwner`): Safe multisig via `CALLDATA_ONLY=true`.
- Notice defaults: routine `2880` epochs (~24h), breaking `20160` epochs (~1 week).

## Architecture Reference

For contract relationships and dependencies, see the [System Diagram in SPEC.md](../../SPEC.md#system-diagram).

## Multisig Ownership

FWSS contracts are owned by a Safe multisig. All owner operations must be submitted as multisig transactions.

### Safe Address

| Network | Safe Address |
|---------|--------------|
| Mainnet (314) | [0x6386622B4915B027900d65560b0ab84F8a1ff2AA](https://filfox.info/en/address/0x6386622B4915B027900d65560b0ab84F8a1ff2AA) |
| Calibnet (314159) | [0x6386622B4915B027900d65560b0ab84F8a1ff2AA](https://calibration.filfox.info/en/address/0x6386622B4915B027900d65560b0ab84F8a1ff2AA) |

### Proxies under multisig ownership

| Contract | Mainnet | Calibnet |
|----------|---------|----------|
| FWSS Proxy | `0x8408502033C418E1bbC97cE9ac48E5528F371A9f` | `0x02925630df557F957f70E112bA06e50965417CA0` |
| ServiceProviderRegistry Proxy | `0xf55dDbf63F1b55c3F1D4FA7e339a68AB7b64A5eB` | `0x839e5c9988e4e9977d40708d0094103c0839Ac9D` |

## Two-Step Upgrade Mechanism

FWSS uses two-step UUPS upgrades:
1. `announcePlannedUpgrade((address,uint96))`
2. After `AFTER_EPOCH`, `upgradeToAndCall(address,bytes)`

## Choosing `AFTER_EPOCH`

| Upgrade Type | Minimum Notice | Recommended |
|--------------|----------------|-------------|
| Routine (bug fixes, minor features) | ~24 hours (~2880 epochs) | 1-2 days |
| Breaking changes | ~1 week (~20160 epochs) | 1-2 weeks |

```bash
UPGRADE_WAIT_DURATION_EPOCHS=2880
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
AFTER_EPOCH=$((CURRENT_EPOCH + UPGRADE_WAIT_DURATION_EPOCHS))
echo "Current: $CURRENT_EPOCH, Upgrade after: $AFTER_EPOCH"
```

## Phase 1: Branch, PR, and Checks

1. Create the release issue via [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) in the GitHub Actions UI.
2. If some values are unknown at issue creation time (`AFTER_EPOCH`, changelog PR number, summary, action required), set placeholders and update the issue later.
3. Ensure all intended contract changes have landed in `main` and your local `main` is up to date.
4. Create a new branch from `main`.
5. Add release-prep updates in this branch:
- Changelog update in [`CHANGELOG.md`](../../CHANGELOG.md).
- Version bump in [`src/FilecoinWarmStorageService.sol`](../src/FilecoinWarmStorageService.sol).
6. Open your PR with the title: `feat: FWSS vX.Y.Z upgrade`.
7. Run checks:

```bash
cd /Users/phi/filecoin-services/service_contracts
forge test --match-contract FilecoinWarmStorageServiceUpgradeTest
forge inspect src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService storageLayout
```

## Phase 2: Deploy Implementations (Calibnet and Mainnet)

Deploy new implementation contracts on both networks before announce/execute.

1. Deploy Calibnet implementation (dry-run, then real) via `Deploy Contract` workflow; capture `CALI_NEW_IMPL`.
2. Deploy Mainnet implementation (dry-run, then real) via `Deploy Contract` workflow; capture `MAIN_NEW_IMPL`.
3. Keep `deployments.json` updates in the same PR (do not merge yet).

## Phase 3: Calibnet Announce + Execute (SAFE path)

1. Compute Calibnet `AFTER_EPOCH` (example: `240` epochs for rehearsal):

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
AFTER_EPOCH=$((CURRENT_EPOCH + 240))
echo "$CURRENT_EPOCH -> $AFTER_EPOCH"
```

2. Generate announce calldata:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
export AFTER_EPOCH="$AFTER_EPOCH"
CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

3. Submit/sign/execute announce tx in Safe UI.
4. Wait until `AFTER_EPOCH`.
5. Generate execute calldata:

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
```

6. Submit/sign/execute upgrade tx in Safe UI.
7. Verify on-chain:

```bash
cast call --rpc-url "https://api.calibration.node.glif.io/rpc/v1" \
  "0x02925630df557F957f70E112bA06e50965417CA0" "version()(string)"
```

## Phase 4: Mainnet Announce + Execute (SAFE path)

1. Compute Mainnet `AFTER_EPOCH`:

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
AFTER_EPOCH=$((CURRENT_EPOCH + 2880)) # use 20160 for breaking changes
echo "$CURRENT_EPOCH -> $AFTER_EPOCH"
```

2. Generate announce calldata:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
export AFTER_EPOCH="$AFTER_EPOCH"
CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

3. Submit/sign/execute announce in Safe UI.
4. Notify stakeholders (see [Stakeholder Communication](#stakeholder-communication)).
5. Wait until `AFTER_EPOCH`.
6. Generate execute calldata:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
```

7. Submit/sign/execute upgrade in Safe UI.
8. Verify on-chain and explorer.

## Phase 5: Merge and Release

1. Merge the upgrade PR.
2. Tag release:

```bash
git tag v1.X.0
git push origin v1.X.0
```

3. Create GitHub Release.
4. Update and close release issue.

---

## Stakeholder Communication

Use the [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) workflow to generate the public checklist and announcement.

For breaking changes:
- Use longer notice (`AFTER_EPOCH`).
- Include migration notes in changelog/release issue.
- Keep Calibnet-to-Mainnet staged rollout.

---

## Upgrading Other Contracts

These are optional/rare for FWSS releases.

### ServiceProviderRegistry (optional)

Deploy new implementation (workflow `ServiceProviderRegistry` or locally):

```bash
./service-provider-registry-deploy.sh
```

Announce (Safe calldata):

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS="0xf55dDbf63F1b55c3F1D4FA7e339a68AB7b64A5eB"
export NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS="0x..."
export AFTER_EPOCH="123456"
CALLDATA_ONLY=true ./service-provider-registry-announce-upgrade.sh
```

Execute (after `AFTER_EPOCH`, Safe calldata):

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS="0xf55dDbf63F1b55c3F1D4FA7e339a68AB7b64A5eB"
export NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS="0x..."
CALLDATA_ONLY=true ./service-provider-registry-execute-upgrade.sh
```

### FilecoinWarmStorageServiceStateView (optional)

StateView is not upgradeable. Redeploy only when view logic changes.

Deploy:

```bash
./warm-storage-deploy-view.sh
```

If you want to set a new view in a separate Safe tx:

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export FWSS_VIEW_ADDRESS="0x..."
CALLDATA_ONLY=true ./warm-storage-set-view.sh
```

Or during FWSS upgrade execute:

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."
export NEW_FWSS_VIEW_ADDRESS="0x..."
CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
```

### Immutable dependencies

FWSS has immutable constructor dependencies that are not expected to change:

```solidity
IPDPVerifier public immutable pdpVerifier;
FilecoinPayV1 public immutable paymentsContract;
IERC20Metadata public immutable usdfcTokenAddress;
address public immutable filBeamBeneficiaryAddress;
ServiceProviderRegistry public immutable serviceProviderRegistry;
SessionKeyRegistry public immutable sessionKeyRegistry;
```

Changing these requires full FWSS redeploy/migration.

---

## Manual Deployment with Local Scripts (alternative)

If you cannot use GitHub Actions, deploy locally:

```bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1" # or mainnet
./warm-storage-deploy-implementation.sh
```

Local deployment scripts update `deployments.json` automatically.

## Notes on `deployments.json`

- GitHub Actions deployment workflow does not commit `deployments.json`; update it manually in your PR.
- `CALLDATA_ONLY=true` scripts do not update `deployments.json`.
- Direct-send execution scripts can update `deployments.json`, but this is legacy flow for owner actions.

---

## Legacy direct-send flow (EOA owner)

Direct-send owner mode remains in scripts for backward compatibility but is not the default runbook path. Use it only if proxy ownership is not a Safe Msig.

---

## Environment Variables Reference

### Common

| Variable | Description |
|----------|-------------|
| `ETH_RPC_URL` | RPC endpoint |
| `ETH_KEYSTORE` | Keystore path (direct-send only) |
| `PASSWORD` | Keystore password (direct-send only) |
| `CHAIN` | Chain ID (auto-detected if unset) |
| `CALLDATA_ONLY` | `true` to print Safe calldata instead of sending tx |
| `AFTER_EPOCH` | Earliest epoch for execute step |

### FWSS

| Variable | Description |
|----------|-------------|
| `FWSS_PROXY_ADDRESS` | FWSS proxy address |
| `NEW_FWSS_IMPLEMENTATION_ADDRESS` | New FWSS implementation (announce script) |
| `NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS` | New FWSS implementation (execute script) |
| `NEW_FWSS_VIEW_ADDRESS` | Optional new StateView during FWSS execute |
| `FWSS_VIEW_ADDRESS` | StateView address (for `warm-storage-set-view.sh`) |

### ServiceProviderRegistry

| Variable | Description |
|----------|-------------|
| `SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS` | Registry proxy address |
| `NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS` | New registry implementation |
| `NEW_VERSION` | Optional migrate version string on execute |
