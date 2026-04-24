# FWSS Upgrade Checklist and Runbook

This file is the canonical, self-contained template for FWSS release issues.

- Keep this template focused on the main `FilecoinWarmStorageService` contract upgrade path.
- Update this file on your release branch if you want to improve or customize the checklist for the current rollout.
- Run the [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) workflow from that same branch so the issue body is rendered from this branch's copy of the template.
- The generated issue should contain everything a release engineer needs for a normal FWSS upgrade.

<!-- ISSUE_TEMPLATE_START -->
## Overview

| Field | Value |
|-------|-------|
| **Version** | `{{RELEASE_VERSION}}` |
| **Upgrade Type** | `{{UPGRADE_TYPE}}` |
| **Changelog PR** | {{CHANGELOG_PR}} |

### Upgrade Schedule

| Network | AFTER_EPOCH | Status |
|---|---:|---|
| Calibnet | `TBD` | Pending |
| Mainnet | `TBD` | Pending |

### Run Log

Keep this table current as values become known.

| Network | New FWSS implementation | Announce tx | Execute tx | Post-upgrade checks |
|---|---|---|---|---|
| Calibnet | `TBD` | `TBD` | `TBD` | Pending |
| Mainnet | `TBD` | `TBD` | `TBD` | Pending |

### Scope
- In scope: `FilecoinWarmStorageService` implementation upgrade behind the existing FWSS proxy.
- Out of scope by default: `FilecoinWarmStorageServiceStateView`, `ServiceProviderRegistry`, `PDPVerifier`, `FilecoinPay`, and `SessionKeyRegistry`.
- If this release needs an out-of-scope change, add a clearly labeled exception section to this issue before starting that work.

### Network Constants

| Network | Chain ID | RPC URL | FWSS Proxy | Safe Owner |
|---|---:|---|---|---|
| Calibnet | `314159` | `https://api.calibration.node.glif.io/rpc/v1` | `0x02925630df557F957f70E112bA06e50965417CA0` | `0x6386622B4915B027900d65560b0ab84F8a1ff2AA` |
| Mainnet | `314` | `https://api.node.glif.io/rpc/v1` | `0x8408502033C418E1bbC97cE9ac48E5528F371A9f` | `0x6386622B4915B027900d65560b0ab84F8a1ff2AA` |

### Operating Rules

- Use the release issue as the rollout source of truth. Keep the schedule, Run Log, tx links, and post-upgrade evidence current.
- Generate owner-action calldata with `CALLDATA_ONLY=true` and submit it through Safe Transaction Builder.
- In Safe Transaction Builder, use the script output exactly: target is the printed FWSS proxy, value is `0`, and data is the printed calldata.
- Do not announce Mainnet until Calibnet execute, on-chain checks, explorer checks, and smoke/E2E checks are complete.
- Do not merge `service_contracts/deployments.json` until live proxy implementation slots match the new implementation addresses.
- If an `AFTER_EPOCH` changes, submit a new `announcePlannedUpgrade()` transaction and record that it supersedes the previous announcement.

### Notice Guidance

| Upgrade Type | Minimum Notice | Recommended |
|---|---:|---|
| Routine | `2880` epochs (~24h) | 1-2 days |
| Breaking change | `20160` epochs (~1 week) | 1-2 weeks |

Calibnet can use a shorter window for rehearsal and validation, but use enough time for signers to coordinate.

```bash
export UPGRADE_WAIT_DURATION_EPOCHS=2880 # use 240+ for Calibnet rehearsal, 20160 for breaking changes
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
AFTER_EPOCH=$((CURRENT_EPOCH + UPGRADE_WAIT_DURATION_EPOCHS))
echo "Current: $CURRENT_EPOCH, Upgrade after: $AFTER_EPOCH"
```

### Post-Upgrade Evidence Required

For each network, record evidence that:
- FWSS proxy implementation slot equals the new implementation address.
- `VERSION()` returns the release version without the leading `v`.
- `nextUpgrade()` is cleared.
- Blockscout shows the proxy and transaction as expected.
- A smoke/E2E test passes. The v1.2.0 rollout used the Synapse SDK storage E2E example.

### Changes
{{CHANGES_SUMMARY}}

### Action Required for Integrators
{{ACTION_REQUIRED}}

---

## Release Checklist

> Work through the phases in order. Do not announce Mainnet until the Calibnet execute transaction, on-chain checks, and smoke/E2E test are complete.

### Phase 1: Branch, Issue, PR, and Checks
- [ ] All intended FWSS contract changes are merged into `main`
- [ ] Create release branch from `main` (recommended: `{{RELEASE_BRANCH}}`)
- [ ] Review this issue template on the release branch and make any one-off wording or structure tweaks before generating the release issue
- [ ] Create the release issue by running the [Create Release Issue]({{CREATE_ISSUE_WORKFLOW_LINK}}) workflow from this branch
- [ ] Changelog entry prepared in [CHANGELOG.md]({{CHANGELOG_LINK}})
- [ ] Version string updated in [FilecoinWarmStorageService.sol]({{FWSS_CONTRACT_LINK}})
- [ ] Upgrade PR created with the title `{{RECOMMENDED_PR_TITLE}}` and linked in the Overview section of this issue
- [ ] Upgrade checks run:

```bash
cd service_contracts
forge test --match-contract FilecoinWarmStorageServiceUpgradeTest
forge inspect src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService storageLayout
```

- [ ] Release issue Overview updated with PR links, summary, and action required

### Phase 2: Deploy Contracts
Deploy both networks before any announce/execute.

**Calibnet FWSS Implementation**
- [ ] Run [Deploy Contract workflow]({{DEPLOY_WORKFLOW_LINK}}) with `network=Calibnet`, `contract=FWSS Implementation`, `dry_run=true`
- [ ] Re-run with `dry_run=false`
- [ ] Capture `CALI_NEW_IMPL` and add it to the Run Log
- [ ] Verify implementation on Sourcify and Blockscout
- [ ] Attempt FilFox verification and record result

**Mainnet FWSS Implementation**
- [ ] Run [Deploy Contract workflow]({{DEPLOY_WORKFLOW_LINK}}) with `network=Mainnet`, `contract=FWSS Implementation`, `dry_run=true`
- [ ] Re-run with `dry_run=false`
- [ ] Capture `MAIN_NEW_IMPL` and add it to the Run Log
- [ ] Verify implementation on Sourcify and Blockscout
- [ ] Attempt FilFox verification and record result
- [ ] Update the upgrade PR's `service_contracts/deployments.json` with both new implementation addresses, but do not merge it until live proxy slots match those addresses

Verification command pattern:

```bash
cd service_contracts

# Calibnet: CHAIN=314159 and FWSS_IMPL="$CALI_NEW_IMPL"
# Mainnet: CHAIN=314 and FWSS_IMPL="$MAIN_NEW_IMPL"
export CHAIN=314159
export FWSS_IMPL="$CALI_NEW_IMPL"

source tools/verify-contracts.sh
verify_sourcify "$FWSS_IMPL" "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService"
verify_blockscout "$FWSS_IMPL" "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService"
verify_filfox "$FWSS_IMPL" "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService"
```

### Phase 3: Calibnet Announce + Execute

**Announce**
- [ ] Compute Calibnet `AFTER_EPOCH` and update the schedule table

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export UPGRADE_WAIT_DURATION_EPOCHS=240 # use a longer window if desired
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
AFTER_EPOCH=$((CURRENT_EPOCH + UPGRADE_WAIT_DURATION_EPOCHS))
echo "$CURRENT_EPOCH -> $AFTER_EPOCH"
```

- [ ] Generate announce calldata and submit/sign/execute in Safe UI:

```bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
export AFTER_EPOCH="$AFTER_EPOCH"

CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

- [ ] In Safe Transaction Builder, set target to the printed FWSS proxy, value to `0`, and data to the printed calldata
- [ ] Record Calibnet announce tx link in the Run Log

**Execute**
- [ ] Wait for `AFTER_EPOCH`
- [ ] Generate execute calldata and submit/sign/execute in Safe UI:

```bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"

CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
```

- [ ] In Safe Transaction Builder, set target to the printed FWSS proxy, value to `0`, and data to the printed calldata
- [ ] Record Calibnet execute tx link in the Run Log
- [ ] Verify implementation slot equals `CALI_NEW_IMPL`
- [ ] Verify `VERSION()` returns the release version without the leading `v`
- [ ] Verify `nextUpgrade()` is cleared

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export EXPECTED_FWSS_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
export EXPECTED_VERSION="{{RELEASE_VERSION}}"
EXPECTED_VERSION="${EXPECTED_VERSION#v}"

CURRENT_VIEW=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'viewContractAddress()(address)')

IMPLEMENTATION_SLOT=$(cast rpc --rpc-url "$ETH_RPC_URL" \
  eth_getStorageAt \
  "$FWSS_PROXY_ADDRESS" \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  latest | tr -d '"' | sed 's/^0x000000000000000000000000/0x/')

ACTUAL_VERSION=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'VERSION()(string)' | tr -d '"')

NEXT_UPGRADE=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$CURRENT_VIEW" \
  'nextUpgrade()(address,uint96)')

echo "Implementation slot: $IMPLEMENTATION_SLOT (expected $EXPECTED_FWSS_IMPLEMENTATION_ADDRESS)"
echo "VERSION(): $ACTUAL_VERSION (expected $EXPECTED_VERSION)"
echo "nextUpgrade(): $NEXT_UPGRADE (expected zero address and 0)"
```

- [ ] Run and record a Calibnet smoke/E2E test result
- [ ] Verify the proxy on Blockscout
- [ ] Confirm Calibnet results are good before announcing Mainnet

### Phase 4: Mainnet Announce + Execute

**Announce**
- [ ] Notify stakeholders before announcing Mainnet, including FilB so they can propagate the upgrade notice
- [ ] Compute Mainnet `AFTER_EPOCH` and update the schedule table

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export UPGRADE_WAIT_DURATION_EPOCHS=2880 # use 20160 for breaking changes
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
AFTER_EPOCH=$((CURRENT_EPOCH + UPGRADE_WAIT_DURATION_EPOCHS))
echo "$CURRENT_EPOCH -> $AFTER_EPOCH"
```

- [ ] Generate announce calldata and submit/sign/execute in Safe UI:

```bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
export AFTER_EPOCH="$AFTER_EPOCH"

CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

- [ ] In Safe Transaction Builder, set target to the printed FWSS proxy, value to `0`, and data to the printed calldata
- [ ] Record Mainnet announce tx link in the Run Log

**Execute**
- [ ] Wait for `AFTER_EPOCH`
- [ ] Generate execute calldata and submit/sign/execute in Safe UI:

```bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"

CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
```

- [ ] In Safe Transaction Builder, set target to the printed FWSS proxy, value to `0`, and data to the printed calldata
- [ ] Record Mainnet execute tx link in the Run Log
- [ ] Verify implementation slot equals `MAIN_NEW_IMPL`
- [ ] Verify `VERSION()` returns the release version without the leading `v`
- [ ] Verify `nextUpgrade()` is cleared

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export EXPECTED_FWSS_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
export EXPECTED_VERSION="{{RELEASE_VERSION}}"
EXPECTED_VERSION="${EXPECTED_VERSION#v}"

CURRENT_VIEW=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'viewContractAddress()(address)')

IMPLEMENTATION_SLOT=$(cast rpc --rpc-url "$ETH_RPC_URL" \
  eth_getStorageAt \
  "$FWSS_PROXY_ADDRESS" \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  latest | tr -d '"' | sed 's/^0x000000000000000000000000/0x/')

ACTUAL_VERSION=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'VERSION()(string)' | tr -d '"')

NEXT_UPGRADE=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$CURRENT_VIEW" \
  'nextUpgrade()(address,uint96)')

echo "Implementation slot: $IMPLEMENTATION_SLOT (expected $EXPECTED_FWSS_IMPLEMENTATION_ADDRESS)"
echo "VERSION(): $ACTUAL_VERSION (expected $EXPECTED_VERSION)"
echo "nextUpgrade(): $NEXT_UPGRADE (expected zero address and 0)"
```

- [ ] Run and record a Mainnet smoke/E2E test result
- [ ] Verify the proxy on Blockscout

### Phase 5: Merge and Release
- [ ] Confirm `service_contracts/deployments.json` matches live Calibnet and Mainnet FWSS implementation slots
- [ ] Finalize and merge changelog/deployments PR(s)
- [ ] Tag release: `git tag {{RELEASE_VERSION}} && git push origin {{RELEASE_VERSION}}`
- [ ] Create GitHub Release with changelog
- [ ] Merge auto-generated PRs in [filecoin-cloud](https://github.com/FilOzone/filecoin-cloud/pulls)
- [ ] Create "Upgrade Synapse to use newest contracts" issue
- [ ] Capture lessons learned from this rollout and update [`service_contracts/tools/UPGRADE-CHECKLIST.md`]({{CHECKLIST_LINK}}) if the process should change
- [ ] Add release link to this issue
- [ ] Close this issue

---

### Resources
- [Changelog]({{CHANGELOG_LINK}})
- [Upgrade Checklist Source]({{CHECKLIST_LINK}})
<!-- ISSUE_TEMPLATE_END -->

## Notes From v1.2.0

- Track Calibnet and Mainnet `AFTER_EPOCH` values in a small schedule table near the top of the issue.
- Keep announce and execute transaction links close to the schedule or in short phase comments.
- Keep a top-level run log with implementation addresses, tx links, and post-upgrade evidence so the issue is skimmable.
- Notify FilB before Mainnet announce so they can propagate contract-upgrade information.
- Run a smoke/E2E check after each network executes; the v1.2.0 rollout used the Synapse SDK storage E2E example.
- If an `AFTER_EPOCH` changes, record that the later announcement supersedes the earlier one.
- StateView changes are intentionally left out of the default checklist. If a release needs a new StateView, add a clearly labeled exception section to the release issue and track it explicitly there.
- `deployments.json` should match live on-chain state. If you prepare updates before a Safe tx executes, verify on-chain before merging.
- FilFox verification was flaky during the `v1.2.0` rollout. Record the result, but do not let it block Sourcify + Blockscout verification.
