# FWSS Upgrade Checklist Template

This file is the canonical template for FWSS release issues.

- Update this file on your release branch if you want to improve or customize the checklist for the current rollout.
- Run the [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) workflow from that same branch so the issue body is rendered from this branch's copy of the template.
- Use [`UPGRADE-PROCESS.md`](./UPGRADE-PROCESS.md) for the full runbook and command reference.

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

### Contracts in Scope
- FilecoinWarmStorageService

### Changes
{{CHANGES_SUMMARY}}

### Action Required for Integrators
{{ACTION_REQUIRED}}

---

## Release Checklist

> Full process details: [UPGRADE-PROCESS.md]({{UPGRADE_PROCESS_LINK}})

### Phase 1: Branch, Issue, PR, and Checks
- [ ] All intended contract changes are merged into `main`
- [ ] Create release branch from `main` (recommended: `{{RELEASE_BRANCH}}`)
- [ ] Update [`service_contracts/tools/UPGRADE-CHECKLIST.md`]({{CHECKLIST_LINK}}) in this branch if the issue structure needs tweaks for this rollout
- [ ] Create the release issue by running the [Create Release Issue]({{CREATE_ISSUE_WORKFLOW_LINK}}) workflow from this branch
- [ ] Changelog entry prepared in [CHANGELOG.md]({{CHANGELOG_LINK}})
- [ ] Version string updated in [FilecoinWarmStorageService.sol]({{FWSS_CONTRACT_LINK}})
- [ ] Upgrade PR created with the title `{{RECOMMENDED_PR_TITLE}}` and linked in the Overview section of this issue
- [ ] Upgrade checks run:

```bash
cd /Users/phi/filecoin-services/service_contracts
forge test --match-contract FilecoinWarmStorageServiceUpgradeTest
forge inspect src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService storageLayout
```

- [ ] Release issue Overview updated with PR links, summary, and action required

### Phase 2: Deploy Contracts
Deploy both networks before any announce/execute.

**Calibnet FWSS Implementation**
- [ ] Run [Deploy Contract workflow]({{DEPLOY_WORKFLOW_LINK}}) with `network=Calibnet`, `contract=FWSS Implementation`, `dry_run=true`
- [ ] Re-run with `dry_run=false`
- [ ] Capture `CALI_NEW_IMPL`
- [ ] Verify implementation on Sourcify and Blockscout
- [ ] Attempt FilFox verification and record result

**Mainnet FWSS Implementation**
- [ ] Run [Deploy Contract workflow]({{DEPLOY_WORKFLOW_LINK}}) with `network=Mainnet`, `contract=FWSS Implementation`, `dry_run=true`
- [ ] Re-run with `dry_run=false`
- [ ] Capture `MAIN_NEW_IMPL`
- [ ] Verify implementation on Sourcify and Blockscout
- [ ] Attempt FilFox verification and record result

### Phase 3: Calibnet Announce + Execute

**Announce**
- [ ] Compute Calibnet `AFTER_EPOCH` and update the schedule table above
- [ ] Generate announce calldata and submit/sign/execute in Safe UI:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
export AFTER_EPOCH="TBD"

CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

- [ ] Record Calibnet announce tx link in the schedule table or a comment

**Execute**
- [ ] Wait for `AFTER_EPOCH`
- [ ] Generate execute calldata and submit/sign/execute in Safe UI:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"

CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
```

- [ ] Verify implementation slot, `VERSION()`, and cleared `nextUpgrade()`
- [ ] Verify on Blockscout

### Phase 4: Mainnet Announce + Execute

**Announce**
- [ ] Compute Mainnet `AFTER_EPOCH`, update the schedule table above, and post stakeholder announcement
- [ ] Generate announce calldata and submit/sign/execute in Safe UI:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
export AFTER_EPOCH="TBD"

CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

- [ ] Record Mainnet announce tx link in the schedule table or a comment

**Execute**
- [ ] Wait for `AFTER_EPOCH`
- [ ] Generate execute calldata and submit/sign/execute in Safe UI:

```bash
cd /Users/phi/filecoin-services/service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"

CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
```

- [ ] Verify implementation slot, `VERSION()`, and cleared `nextUpgrade()`
- [ ] Verify on Blockscout

### Phase 5: Merge and Release
- [ ] Finalize changelog PR(s) if a draft PR and follow-up PR were used
- [ ] Commit/push updated `service_contracts/deployments.json`
- [ ] Tag release: `git tag {{RELEASE_VERSION}} && git push origin {{RELEASE_VERSION}}`
- [ ] Create GitHub Release with changelog
- [ ] Merge auto-generated PRs in [filecoin-cloud](https://github.com/FilOzone/filecoin-cloud/pulls)
- [ ] Create "Upgrade Synapse to use newest contracts" issue
- [ ] Add release link to this issue
- [ ] Close this issue

---

### Resources
- [Changelog]({{CHANGELOG_LINK}})
- [Upgrade Process Documentation]({{UPGRADE_PROCESS_LINK}})
<!-- ISSUE_TEMPLATE_END -->

## Notes From v1.2.0

- Track Calibnet and Mainnet `AFTER_EPOCH` values in a small schedule table near the top of the issue.
- Keep announce and execute transaction links close to the schedule or in short phase comments.
- StateView changes are intentionally left out of the default checklist. If a release needs a new StateView, handle that as an exception using [`UPGRADE-PROCESS.md`](./UPGRADE-PROCESS.md) and track it explicitly in the issue.
- `deployments.json` should match live on-chain state. If you prepare updates before a Safe tx executes, verify on-chain before merging.
- FilFox verification was flaky during the `v1.2.0` rollout. Record the result, but do not let it block Sourcify + Blockscout verification.
