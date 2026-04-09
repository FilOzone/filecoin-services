# FWSS Contract Upgrade Process

This document describes the upgrade process for FilecoinWarmStorageService (FWSS), organized as a phase-based runbook. This runbook is optimized for FWSS upgrades and assumes deployment via GitHub Actions and owner actions through Safe multisig.

## Scope and Defaults

- Scope: FWSS-only main path (ServiceProviderRegistry and StateView are optional; see [Upgrading Other Contracts](#upgrading-other-contracts)).
- Release issue template: [`UPGRADE-CHECKLIST.md`](./UPGRADE-CHECKLIST.md).
- Deployment path: GitHub Actions [Deploy Contract](https://github.com/FilOzone/filecoin-services/actions/workflows/deploy-contract.yml).
- Owner actions (`onlyOwner`): Safe multisig via `CALLDATA_ONLY=true`.
- Notice defaults: routine `2880` epochs (~24h), breaking `20160` epochs (~1 week).

## Architecture Reference

For contract relationships and dependencies, see the [System Diagram in SPEC.md](../../SPEC.md#system-diagram).

## Release Issue Source of Truth

The release issue should be rendered from [`UPGRADE-CHECKLIST.md`](./UPGRADE-CHECKLIST.md).

Recommended flow:
1. Create your release branch from the latest `main`.
2. Update [`UPGRADE-CHECKLIST.md`](./UPGRADE-CHECKLIST.md) on that branch if this rollout needs checklist or wording improvements.
3. Run [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) from that same branch in GitHub Actions.

That workflow checks out the selected ref and renders the issue body from that branch's copy of [`UPGRADE-CHECKLIST.md`](./UPGRADE-CHECKLIST.md), so the issue and the release-prep branch stay aligned.

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

## Phase 1: Branch, Issue, PR, and Checks

1. Ensure all intended contract changes have landed in `main`.
2. Update local `main` and create a release branch from it.
3. Update [`UPGRADE-CHECKLIST.md`](./UPGRADE-CHECKLIST.md) in that branch if you want to improve the release issue structure for this rollout.
4. Run [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) from that same branch.
5. Add release-prep updates in the release branch:
- Changelog update in [`CHANGELOG.md`](../../CHANGELOG.md).
- Version bump in [`src/FilecoinWarmStorageService.sol`](../src/FilecoinWarmStorageService.sol).
6. Open your upgrade PR with the title: `feat: FWSS vX.Y.Z upgrade`.
7. Update the release issue Overview with the PR link, summary of changes, and any integrator action required.
8. Run checks:

```bash
cd /Users/phi/filecoin-services/service_contracts
forge test --match-contract FilecoinWarmStorageServiceUpgradeTest
forge inspect src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService storageLayout
```

## Phase 2: Deploy Implementations (Calibnet and Mainnet)

Deploy new implementation contracts on both networks before announce/execute.

1. Deploy Calibnet implementation (dry-run, then real) via `Deploy Contract` workflow; capture `CALI_NEW_IMPL`.
2. Verify the Calibnet implementation on Sourcify and Blockscout. Attempt FilFox verification and record the result.
3. Deploy Mainnet implementation (dry-run, then real) via `Deploy Contract` workflow; capture `MAIN_NEW_IMPL`.
4. Verify the Mainnet implementation on Sourcify and Blockscout. Attempt FilFox verification and record the result.
5. Update the open upgrade PR with the new implementation addresses in [`deployments.json`](../deployments.json).

Example verification commands:

```bash
cd /Users/phi/filecoin-services/service_contracts
export CHAIN=314159 # use 314 for mainnet
export FWSS_IMPL="$CALI_NEW_IMPL" # or "$MAIN_NEW_IMPL" on mainnet
source tools/verify-contracts.sh

verify_blockscout "$FWSS_IMPL" "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService"
verify_sourcify "$FWSS_IMPL" "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService"
verify_filfox "$FWSS_IMPL" "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService"
```

## Phase 3: Calibnet Announce + Execute (SAFE path)

1. Compute Calibnet `AFTER_EPOCH`:

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
AFTER_EPOCH=$((CURRENT_EPOCH + 240)) # use a longer window if desired

echo "$CURRENT_EPOCH -> $AFTER_EPOCH"
```

2. Update the release issue schedule table with the Calibnet `AFTER_EPOCH`.
3. Generate announce calldata:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
export AFTER_EPOCH="$AFTER_EPOCH"
CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

4. Submit/sign/execute announce tx in Safe UI.
5. Record the Calibnet announce transaction link in the release issue.
6. Wait until `AFTER_EPOCH`.
7. Generate execute calldata:

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
```

8. Submit/sign/execute upgrade tx in Safe UI.
9. Verify on-chain:

```bash
CURRENT_VIEW=$(cast call --rpc-url "https://api.calibration.node.glif.io/rpc/v1" \
  0x02925630df557F957f70E112bA06e50965417CA0 \
  'viewContractAddress()(address)')

cast rpc --rpc-url "https://api.calibration.node.glif.io/rpc/v1" \
  eth_getStorageAt \
  0x02925630df557F957f70E112bA06e50965417CA0 \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  latest

cast call --rpc-url "https://api.calibration.node.glif.io/rpc/v1" \
  0x02925630df557F957f70E112bA06e50965417CA0 \
  'VERSION()(string)'

cast call --rpc-url "https://api.calibration.node.glif.io/rpc/v1" \
  "$CURRENT_VIEW" \
  'nextUpgrade()(address,uint96)'
```

10. Verify on Blockscout.

## Phase 4: Mainnet Announce + Execute (SAFE path)

1. Compute Mainnet `AFTER_EPOCH`:

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
AFTER_EPOCH=$((CURRENT_EPOCH + 2880)) # use 20160 for breaking changes

echo "$CURRENT_EPOCH -> $AFTER_EPOCH"
```

2. Update the release issue schedule table with the Mainnet `AFTER_EPOCH` and post stakeholder communication.
3. Generate announce calldata:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
export AFTER_EPOCH="$AFTER_EPOCH"
CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

4. Submit/sign/execute announce in Safe UI.
5. Record the Mainnet announce transaction link in the release issue.
6. Wait until `AFTER_EPOCH`.
7. Generate execute calldata:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
```

8. Submit/sign/execute upgrade in Safe UI.
9. Verify on-chain and explorer:

```bash
CURRENT_VIEW=$(cast call --rpc-url "https://api.node.glif.io/rpc/v1" \
  0x8408502033C418E1bbC97cE9ac48E5528F371A9f \
  'viewContractAddress()(address)')

cast rpc --rpc-url "https://api.node.glif.io/rpc/v1" \
  eth_getStorageAt \
  0x8408502033C418E1bbC97cE9ac48E5528F371A9f \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  latest

cast call --rpc-url "https://api.node.glif.io/rpc/v1" \
  0x8408502033C418E1bbC97cE9ac48E5528F371A9f \
  'VERSION()(string)'

cast call --rpc-url "https://api.node.glif.io/rpc/v1" \
  "$CURRENT_VIEW" \
  'nextUpgrade()(address,uint96)'
```

10. Verify on Blockscout.

## Phase 5: Merge and Release

1. Finalize any draft or follow-up changelog PRs.
2. Commit and push the updated [`deployments.json`](../deployments.json).
3. Tag release:

```bash
git tag v1.X.0
git push origin v1.X.0
```

4. Create GitHub Release.
5. Merge auto-generated PRs in `filecoin-cloud`.
6. Create the "Upgrade Synapse to use newest contracts" issue.
7. Update and close the release issue.

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
