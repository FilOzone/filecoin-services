# FWSS Contract Upgrade Process

This document describes the upgrade process for FilecoinWarmStorageService (FWSS) and related contracts, organized as a phase-based runbook.

## Contract Upgradeability Overview

| Contract | Proxy Pattern | Upgrade Method |
|----------|---------------|----------------|
| FilecoinWarmStorageService (FWSS) | UUPS Proxy (two-step) | `announce-planned-upgrade.sh` + `upgrade.sh` |
| ServiceProviderRegistry | UUPS Proxy (two-step) | `announce-planned-upgrade-registry.sh` + `upgrade-registry.sh` |
| PDPVerifier | ERC1967 Proxy | Via [pdp repo](https://github.com/FilOzone/pdp) scripts |
| FilecoinPayV1 | None (immutable) | Not expected to be redeployed |
| SessionKeyRegistry | None (immutable) | Not expected to be redeployed |
| FilecoinWarmStorageServiceStateView | None (helper) | Redeployable via `deploy-warm-storage-view.sh` |

## Immutable Dependencies

FWSS stores several dependencies as `immutable` constructor parameters:

```solidity
IPDPVerifier public immutable pdpVerifier;
FilecoinPayV1 public immutable paymentsContract;
IERC20Metadata public immutable usdfcTokenAddress;
address public immutable filBeamBeneficiaryAddress;
ServiceProviderRegistry public immutable serviceProviderRegistry;
SessionKeyRegistry public immutable sessionKeyRegistry;
```

These immutable contracts are **not expected to be redeployed** under normal operations. If redeployment becomes necessary, announce it well ahead of time and follow the standard two-step upgrade process with an extended notice period.

## Two-Step Upgrade Process

Both FWSS and ServiceProviderRegistry use a two-step upgrade mechanism:

1. **Announce** - Call `announcePlannedUpgrade()` with the new implementation address and `AFTER_EPOCH`
2. **Execute** - After `AFTER_EPOCH` has passed, call `upgradeToAndCall()` to complete the upgrade

## Choosing AFTER_EPOCH

When announcing an upgrade, choose `AFTER_EPOCH` to give stakeholders adequate notice:

| Upgrade Type | Minimum Notice | Recommended |
|--------------|----------------|-------------|
| Routine (bug fixes, minor features) | ~24 hours (~5760 epochs) | 1-2 days |
| Breaking changes | ~1 week (~20160 epochs) | 1-2 weeks |
| Immutable dependency changes | ~2 weeks (~40320 epochs) | 2-4 weeks |

```bash
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL"); AFTER_EPOCH=$((CURRENT_EPOCH + 5760)); echo "Current: $CURRENT_EPOCH, Upgrade after: $AFTER_EPOCH"
```

Considerations:
- Allow time for stakeholder review
- Avoid weekends/holidays for mainnet upgrades
- Calibnet can use shorter notice periods for testing

## Phase 0: Decide Scope

1. Identify which contracts are changing:
   - FWSS implementation
   - ServiceProviderRegistry implementation
   - StateView contract (typically for breaking changes in the view)
2. If the change is breaking (including breaking changes to dependencies) , plan for longer notice and a migration guide.

## Phase 1: Prepare

1. **Prepare changelog entry** in [`CHANGELOG.md`](../../CHANGELOG.md):
   - Document all changes since last release (https://github.com/FilOzone/filecoin-services/releases)
   - Mark breaking changes clearly
   - Include migration notes if needed
2. **Create PR** with changelog updates
3. **Update the version** string in the contracts if applicable.
4. **Create tracking issue** using the [Create Upgrade Announcement](https://github.com/FilOzone/filecoin-services/actions/workflows/upgrade-announcement.yml) GitHub Action

## Phase 2: Calibnet Rehearsal

Always test the upgrade on Calibnet before mainnet.

### Deploy Implementations (Calibnet)

FWSS implementation:
```bash
./deploy-warm-storage-implementation-only.sh
```

Other contracts you might deploy during a upgrade can be:

ServiceProviderRegistry implementation (if needed):
```bash
./deploy-registry-calibnet.sh
```

FilecoinWarmStorageStateView update (if needed):
```bash
./deploy-warm-storage-view.sh
```

`deployments.json` is updated automatically by the scripts. Commit the updated file in the upgrade PR and document the new addresses in PR comments for traceability.


### Announce and Execute (Calibnet)

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export WARM_STORAGE_PROXY_ADDRESS="0x..."
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."
export AFTER_EPOCH="123456"

./announce-planned-upgrade.sh
```

After `AFTER_EPOCH`, execute:
```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export WARM_STORAGE_PROXY_ADDRESS="0x..."
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."

./upgrade.sh
```

## Phase 3: Mainnet Deployment

1. Deploy registry implementation (if needed):
   ```bash
   ./deploy-registry.sh
   ```
2. Deploy FWSS implementation:
   ```bash
   ./deploy-warm-storage-implementation-only.sh
   ```
3. Deploy StateView (if needed):
   ```bash
   ./deploy-warm-storage-view.sh
   ```

`deployments.json` is updated automatically by the scripts. Commit the updated file in the upgrade PR and document the new addresses in PR comments for traceability.

## Phase 4: Announce the Mainnet Upgrade

1. Choose `AFTER_EPOCH` based on the upgrade type.
2. Announce on-chain:
   ```bash
   export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
   export WARM_STORAGE_PROXY_ADDRESS="0x..."
   export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."
   export AFTER_EPOCH="123456"

   ./announce-planned-upgrade.sh
   ```
4. Notify stakeholders (see template below). Use the GitHub Action to create the announcement issue.

## Phase 5: Execute the Mainnet Upgrade

After `AFTER_EPOCH`, execute:

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export WARM_STORAGE_PROXY_ADDRESS="0x..."
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."
export NEW_WARM_STORAGE_VIEW_ADDRESS="0x..."  # Optional

./upgrade.sh
```

## Phase 6: Verify and Release

1. **Verify** upgrades on Blockscout.
2. **Confirm** `deployments.json` was updated (automatic via script).
3. **Merge** the changelog PR.
4. **Tag release** in GitHub (post-upgrade):
   ```bash
   git tag v1.X.0
   git push origin v1.X.0
   ```
5. **Create GitHub Release** with the changelog, ensure to point to the `deployments.json` for current addresses.
6. **Notify stakeholders** that the upgrade is complete.

## Stakeholder Communication

> **Tip**: Use the [Create Upgrade Announcement](../../.github/workflows/upgrade-announcement.yml) GitHub Action to automatically generate an announcement issue. Go to **Actions → Create Upgrade Announcement → Run workflow**.

### Upgrade Announcement Template

> **Automated**: The GitHub Action generates this template as an issue automatically.

When communicating an upgrade, include:

```
## FWSS Contract Upgrade Announcement

**Network**: [Mainnet/Calibnet]
**Upgrade Type**: [Routine/Breaking Change]
**Scheduled Execution**: After epoch [AFTER_EPOCH] (~[estimated date/time])

### Changes
- [Summary of changes]
- [Link to PR/release notes]

### Contracts Planned for Upgrade
- FilecoinWarmStorageService
- ServiceProviderRegistry (if applicable)
- FilecoinWarmStorageServiceStateView (if applicable)

### Action Required
[None / Describe any required actions for integrators]

### Resources
- Release: [link] (if applicable)
- Changelog: [link]
- Upgrade Process: [link to this document]
```

### Breaking Changes Communication

For upgrades involving immutable dependency changes or breaking API changes:
- Provide extended notice period
- Create a migration guide for affected integrators
- Offer a support channel for questions during migration
- Consider phased rollout: Calibnet first, then Mainnet after validation

## Environment Variables Reference

### Common Variables

| Variable | Description |
|----------|-------------|
| `ETH_RPC_URL` | RPC endpoint (e.g., `https://api.calibration.node.glif.io/rpc/v1`) |
| `ETH_KEYSTORE` | Path to Ethereum keystore file |
| `PASSWORD` | Keystore password |
| `CHAIN` | Chain ID (auto-detected if not set) |

### FWSS Upgrade Variables

| Variable | Description |
|----------|-------------|
| `WARM_STORAGE_PROXY_ADDRESS` | Address of FWSS proxy contract |
| `NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS` | Address of new implementation |
| `AFTER_EPOCH` | Block number after which upgrade can execute |
| `NEW_WARM_STORAGE_VIEW_ADDRESS` | (Optional) New StateView address |

### Registry Upgrade Variables

| Variable | Description |
|----------|-------------|
| `SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS` | Address of registry proxy |
| `REGISTRY_PROXY_ADDRESS` | Same as above (used by announce script) |
| `NEW_REGISTRY_IMPLEMENTATION_ADDRESS` | Address of new implementation |
| `AFTER_EPOCH` | Block number after which upgrade can execute |
| `NEW_VERSION` | (Optional) Version string for migrate() |

## Deployment Address Management

All deployment scripts automatically load and update addresses in `deployments.json`. See the main [README.md](./README.md) for details on:

- How addresses are loaded by chain ID
- Environment variable overrides
- Control flags (`SKIP_LOAD_DEPLOYMENTS`, `SKIP_UPDATE_DEPLOYMENTS`)
