# FWSS Contract Upgrade Process

This document describes the upgrade process for FilecoinWarmStorageService (FWSS), organized as a phase-based runbook. Most upgrades only involve the FWSS implementation contract.

## Contract Overview

| Contract | Upgradeable? | Notes |
|----------|--------------|-------|
| **FilecoinWarmStorageService (FWSS)** | Yes (UUPS, two-step) | Primary contract, most upgrades are here |
| ServiceProviderRegistry | Yes (UUPS, two-step) | Rarely upgraded separately |
| FilecoinWarmStorageServiceStateView | No (redeploy) | Helper contract, redeploy if view logic changes |
| PDPVerifier | Yes (ERC1967) | Via [pdp repo](https://github.com/FilOzone/pdp) |
| FilecoinPayV1, SessionKeyRegistry | No (immutable) | Not expected to change |

**UUPS, two-step** — These contracts use the [UUPS (ERC-1822)](https://eips.ethereum.org/EIPS/eip-1822) proxy pattern via OpenZeppelin's `UUPSUpgradeable`, where the upgrade authorization logic lives in the *implementation* contract rather than the proxy. On top of standard UUPS, we add a **two-step upgrade mechanism**: the owner must first call `announcePlannedUpgrade()` to record the new implementation address and a future epoch, then wait for that epoch to pass before `upgradeToAndCall()` will succeed.

> For upgrading ServiceProviderRegistry or redeploying StateView, see [Upgrading Other Contracts](#upgrading-other-contracts).

## Two-Step Upgrade Mechanism

FWSS uses a two-step upgrade to give stakeholders notice:

1. **Announce** - Call `announcePlannedUpgrade()` with the new implementation address and `AFTER_EPOCH`
2. **Execute** - After `AFTER_EPOCH` passes, call `upgradeToAndCall()` to complete the upgrade

## Choosing AFTER_EPOCH

| Upgrade Type | Minimum Notice | Recommended |
|--------------|----------------|-------------|
| Routine (bug fixes, minor features) | ~24 hours (~2880 epochs) | 1-2 days |
| Breaking changes | ~1 week (~20160 epochs) | 1-2 weeks |

Calculate an `AFTER_EPOCH`:
```bash
UPGRADE_WAIT_DURATION_EPOCHS=2880  # ~24 hours
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
AFTER_EPOCH=$((CURRENT_EPOCH + UPGRADE_WAIT_DURATION_EPOCHS))
echo "Current: $CURRENT_EPOCH, Upgrade after: $AFTER_EPOCH"
```

**Considerations:**
- Allow time for stakeholder review
- Avoid weekends/holidays for mainnet upgrades
- Calibnet can use shorter notice periods for testing

---

## Phase 1: Prepare

1. **Prepare changelog entry** in [`CHANGELOG.md`](../../CHANGELOG.md):
   - Document all changes since [last release](https://github.com/FilOzone/filecoin-services/releases)
   - Mark breaking changes clearly
   - Include migration notes if needed

2. **Update the [version](https://github.com/FilOzone/filecoin-services/blob/main/service_contracts/src/FilecoinWarmStorageService.sol#L63)** string in the contract.

3. **Create an upgrade PR** with your changelog updates.
   - Example title: `feat: FWSS v1.2.0 upgrade`

4. **Create release issue** using the [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) GitHub Action.
   - Or preview locally: `node .github/scripts/create-upgrade-announcement.js --dry-run`

## Phase 2: Calibnet Rehearsal

Always test the upgrade on Calibnet before mainnet.

### Deploy Implementation

```bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"

./deploy-warm-storage-implementation-only.sh
```

The script updates `deployments.json` automatically. Commit the changes in the branch of the "upgrade PR" above.

### Announce Upgrade

```bash
export WARM_STORAGE_PROXY_ADDRESS="0x..."
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."
export AFTER_EPOCH="123456"

./announce-planned-upgrade.sh
```

### Execute Upgrade

After `AFTER_EPOCH` passes:

```bash
export WARM_STORAGE_PROXY_ADDRESS="0x..."
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."

./upgrade.sh
```

Verify the upgrade on [Calibnet Blockscout](https://calibration.filfox.info/).

## Phase 3: Mainnet Deployment

```bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"

./deploy-warm-storage-implementation-only.sh
```

Commit the updated `deployments.json` in the branch of the "upgrade PR" above.

## Phase 4: Announce Mainnet Upgrade

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export WARM_STORAGE_PROXY_ADDRESS="0x..."
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."
export AFTER_EPOCH="123456"

./announce-planned-upgrade.sh
```

Notify stakeholders (see [Stakeholder Communication](#stakeholder-communication)).

## Phase 5: Execute Mainnet Upgrade

After `AFTER_EPOCH` passes:

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export WARM_STORAGE_PROXY_ADDRESS="0x..."
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."

./upgrade.sh
```

## Phase 6: Verify and Release

1. **Verify** the upgrade on [Mainnet Blockscout](https://filfox.info/).
2. **Confirm** `deployments.json` is up to date.
3. **Merge** the changelog PR.
4. **Tag release**:
   ```bash
   git tag v1.X.0
   git push origin v1.X.0
   ```
5. **Create GitHub Release** with the changelog.
6. **Close the release issue** after updating it with the release link.

---

## Stakeholder Communication

> **Tip**: Use the [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) GitHub Action to generate a release issue. Go to **Actions → Create Release Issue → Run workflow**.

The release issue serves as both the public announcement and the release engineer's checklist. It includes:
- Overview with network, epoch, estimated time, and changelog link
- Summary of changes and action required for integrators
- Full release checklist with all phases
- Deployed addresses table (filled in during the process)

### Breaking Changes

For breaking API changes:
- Provide extended notice period (1-2 weeks recommended)
- Create a migration guide for affected integrators
- Consider phased rollout: Calibnet first, then Mainnet after validation

---

## Upgrading Other Contracts

Most upgrades only involve FWSS. This section covers the rare cases where you need to upgrade other contracts.

### ServiceProviderRegistry

The registry uses the same two-step upgrade mechanism as FWSS. Only upgrade it when:
- There are changes to provider registration logic
- Storage or validation rules need updating

**Deploy new implementation:**
```bash
./deploy-registry.sh
```

**Announce upgrade:**
```bash
export REGISTRY_PROXY_ADDRESS="0x..."
export NEW_REGISTRY_IMPLEMENTATION_ADDRESS="0x..."
export AFTER_EPOCH="123456"

./announce-planned-upgrade-registry.sh
```

**Execute upgrade (after AFTER_EPOCH):**
```bash
export SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS="0x..."
export NEW_REGISTRY_IMPLEMENTATION_ADDRESS="0x..."

./upgrade-registry.sh
```

**Environment variables:**

| Variable | Description |
|----------|-------------|
| `REGISTRY_PROXY_ADDRESS` | Address of registry proxy (for announce script) |
| `SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS` | Address of registry proxy (for upgrade script) |
| `NEW_REGISTRY_IMPLEMENTATION_ADDRESS` | Address of new implementation |
| `AFTER_EPOCH` | Block number after which upgrade can execute |

### FilecoinWarmStorageServiceStateView

StateView is a helper contract (not upgradeable). Redeploy it when:
- The view logic changes
- FWSS changes require updated read functions

**Deploy new StateView:**
```bash
./deploy-warm-storage-view.sh
```

**Update FWSS to use new StateView (during upgrade):**
```bash
export NEW_WARM_STORAGE_VIEW_ADDRESS="0x..."
./upgrade.sh
```

### Immutable Dependencies

FWSS has these immutable dependencies that are **not expected to change**:

```solidity
IPDPVerifier public immutable pdpVerifier;
FilecoinPayV1 public immutable paymentsContract;
IERC20Metadata public immutable usdfcTokenAddress;
address public immutable filBeamBeneficiaryAddress;
ServiceProviderRegistry public immutable serviceProviderRegistry;
SessionKeyRegistry public immutable sessionKeyRegistry;
```

If any of these need to change, it requires redeploying FWSS entirely. This should be announced well in advance (~2-4 weeks) with a migration plan.

---

## Environment Variables Reference

### Common Variables

| Variable | Description |
|----------|-------------|
| `ETH_RPC_URL` | RPC endpoint |
| `ETH_KEYSTORE` | Path to Ethereum keystore file |
| `PASSWORD` | Keystore password |
| `CHAIN` | Chain ID (auto-detected if not set) |

### FWSS Variables

| Variable | Description |
|----------|-------------|
| `WARM_STORAGE_PROXY_ADDRESS` | Address of FWSS proxy contract |
| `NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS` | Address of new implementation |
| `AFTER_EPOCH` | Block number after which upgrade can execute |
| `NEW_WARM_STORAGE_VIEW_ADDRESS` | (Optional) New StateView address to set during upgrade |

## Deployment Address Management

All deployment scripts automatically load and update addresses in `deployments.json`. See [README.md](./README.md) for details on:

- How addresses are loaded by chain ID
- Environment variable overrides
- Control flags (`SKIP_LOAD_DEPLOYMENTS`, `SKIP_UPDATE_DEPLOYMENTS`)
