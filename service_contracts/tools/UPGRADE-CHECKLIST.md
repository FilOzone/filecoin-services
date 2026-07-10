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
| **Stack Version** | `{{RELEASE_VERSION}}` |
| **Upgrade Type** | `{{UPGRADE_TYPE}}` |
| **Release-prep PR(s)** | {{RELEASE_PREP_PR}} |
| **Technical Owner** | `TBD` |
| **Go/No-Go Status** | `TBD` |

### Release Tracking

The filecoin-services GitHub release version is the stack version. It may differ from an individual contract `VERSION()` when the stack changes without an FWSS code change.

| Item | Value |
|---|---|
| Frozen deploy commit | `TBD` |
| GitHub pre-release | `TBD` |
| Release status | `Pre-release until Mainnet proxy switch is verified` |
| `deployments.json` PR(s) | `TBD` |
| Synapse SDK PR | `TBD` |

Field ownership for duplicated rollout data:

| Data | Source of truth | Mirror/update |
|---|---|---|
| Operator status, owner decisions, exceptions, and in-progress tx/check evidence | This release issue: Release Tracking and Run Log | Mirror externally useful rollout status to the GitHub Release page |
| Live contract state | Chain state read from the FWSS proxy, implementation slot, and View contract | Record observed values in the Run Log and use them for go/no-go |
| Consumer-facing release status, addresses, epochs, and tx links | GitHub Release page | Populate from the Run Log as rollout facts become final |
| Repo deployment snapshot | `service_contracts/deployments.json` on `main` | Update by follow-up PR(s) only after the relevant proxy and View switches are live |

### Component Versions

| Component | Version | Changed? | Notes |
|---|---|---|---|
| Stack (`filecoin-services`) | `{{RELEASE_VERSION}}` | Yes | Git tag / GitHub Release |
| `FilecoinWarmStorageService` | `{{FWSS_VERSION}}` | `TBD` | Contract `VERSION()` returned by the FWSS proxy |
| `PDPVerifier` | `TBD` | `TBD` | Link PDP release if this stack consumes a new PDP version |

### Upgrade Schedule

| Network | Announcement mode | Requested delay | Actual `AFTER_EPOCH` | Status |
|---|---|---:|---:|---|
| Calibnet | `TBD` | `TBD` | `TBD` | Pending |
| Mainnet | `TBD` | `TBD` | `TBD` | Pending |

Choose the announcement mode and requested delay before proposing the Safe transaction. In delay mode, fill in the actual `AFTER_EPOCH` from `nextUpgrade()` after the announcement executes. In bootstrap legacy mode, record the absolute target before Safe signing, include the notice duration and signing buffer in the requested-delay cell, and verify the same target on-chain after execution. The observed value is the source of truth for the execute step and external communications.

### Run Log

The Run Log is this release issue's operator journal for rollout facts discovered during execution: deployed addresses, transaction links, validation outputs, exceptions, and owner decisions.

Keep this table current as values become known.

| Network | New FWSS implementation | StateView / setView tx | Announce tx | Actual `afterEpoch` | Execute tx | Post-upgrade checks |
|---|---|---|---|---:|---|---|
| Calibnet | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Pending |
| Mainnet | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Pending |

### Scope
- In scope: `FilecoinWarmStorageService` implementation upgrade behind the existing FWSS proxy.
- Out of scope by default: `FilecoinWarmStorageServiceStateView`, `ServiceProviderRegistry`, `PDPVerifier`, `FilecoinPay`, and `SessionKeyRegistry`.
- If this release needs an out-of-scope change, add a clearly labeled exception section to this issue before starting that work.

### Cross-Repo Impact

Check every pre-seeded row and list each required cross-repo change or release. Use `None` only after the technical owner confirms there is no required change for that repository.

| Repository | Required change, PR, issue, or release | Required before Mainnet? | Owner/Status |
|---|---|---|---|
| `FilOzone/synapse-sdk` | `TBD` | `TBD` | `TBD` |
| `FilOzone/pdp` | `TBD` | `TBD` | `TBD` |
| `filecoin-project/curio` | `TBD` | `TBD` | `TBD` |
| `FilOzone/filecoin-cloud` | `TBD` | `TBD` | `TBD` |
| Other / none | `TBD` | `TBD` | `TBD` |

### Dependency Targets and Compatibility

Record the intended deployed dependency versions or addresses, then verify actual deployed state against those targets before go/no-go.

| Dependency | Target version/address | Calibnet observed | Mainnet observed | Verification/status |
|---|---|---|---|---|
| `PDPVerifier` | `TBD` | `TBD` | `TBD` | `TBD` |
| `FilecoinPay` | `TBD` | `TBD` | `TBD` | `TBD` |
| `ServiceProviderRegistry` | `TBD` | `TBD` | `TBD` | `TBD` |
| `SessionKeyRegistry` | `TBD` | `TBD` | `TBD` | `TBD` |

### Rollback Plan

State whether rollback is safe before any live announce transaction. Link the approved rollback procedure or script when available.

| Field | Value |
|---|---|
| Rollback status | `TBD: Safe / Unsafe / Not applicable` |
| Previous FWSS implementation | `TBD` |
| Rollback procedure/script | `TBD` |
| Decision notes | `TBD` |

### Pre-Live Validation

Record validation that proves the planned upgrade works against the full contract, Curio, and Synapse state before live rollout.

| Validation | Evidence/status |
|---|---|
| foc-devnet post-upgrade state validation | `TBD` |
| Pricing validation | `TBD`: link command output, test run, or issue comment confirming FWSS pricing values match the intended release pricing before live rollout. |
| Synapse SDK integration build | `TBD`: link the Synapse SDK PR/check run that builds against the intended contract ABI/types and deployment-address state, or record the owner-approved exception. |

### Network Constants

| Network | Chain ID | RPC URL | FWSS Proxy | Safe Owner |
|---|---:|---|---|---|
| Calibnet | `314159` | `https://api.calibration.node.glif.io/rpc/v1` | `0x02925630df557F957f70E112bA06e50965417CA0` | `0x6386622B4915B027900d65560b0ab84F8a1ff2AA` |
| Mainnet | `314` | `https://api.node.glif.io/rpc/v1` | `0x8408502033C418E1bbC97cE9ac48E5528F371A9f` | `0x6386622B4915B027900d65560b0ab84F8a1ff2AA` |

### Operating Rules

- Use the release issue as the rollout source of truth. Keep the schedule, Run Log, tx links, and post-upgrade evidence current.
- Create the stack tag and GitHub Release before any live proxy switch. Mark the GitHub Release as a pre-release until Mainnet is complete and verified.
- Keep the GitHub pre-release page updated as the external rollout tracker for consumers; keep this issue updated as the operator runbook.
- Keep CHANGELOG focused on what changed. Put mutable deployment status, addresses, epochs, and transaction links on the GitHub Release page.
- **Tag semantics:** The `vX.Y.Z` tag is immutable and points to the frozen deploy commit used for contract deployment and bytecode verification. Post-deploy rollout facts such as live addresses, epochs, tx links, and `deployments.json` follow-up PRs are not folded back into the tag. They live on `main`, the release issue Run Log, and the GitHub Release page. Do not create a second "final release" tag.
- **Where to find what:** Use the `vX.Y.Z` tag for the source that produced the deployed bytecode. Use on-chain reads from the FWSS proxy for live state, including the implementation slot and address getters such as `viewContractAddress()`, `pdpVerifierAddress()`, `paymentsContractAddress()`, `serviceProviderRegistry()`, `sessionKeyRegistry()`, `usdfcTokenAddress()`, and `filBeamBeneficiaryAddress()`. Use the GitHub Release rollout table for the historical record of what was live for this release.
- `service_contracts/deployments.json` on a release branch or `vX.Y.Z` tag is the copy that existed at branch-cut/tag time and may be stale after Calibnet/Mainnet proxy or View switches. Do not use it as live state. Update `deployments.json` on `main` through the follow-up PR flow, but treat chain state and linked execute transactions as the live verification source.
- The technical owner owns the written upgrade plan, dependency target verification, and final go/no-go decision.
- Before any live announce transaction, fill in the Technical Owner, Cross-Repo Impact, Dependency Targets and Compatibility, Rollback Plan, and foc-devnet validation status.
- Generate owner-action calldata with `CALLDATA_ONLY=true` and submit it through Safe Transaction Builder.
- In Safe Transaction Builder, use the script output exactly: target is the printed FWSS proxy, value is `0`, and data is the printed calldata.
- Do not announce Mainnet until Calibnet execution, on-chain checks, explorer checks, smoke/E2E checks, and `filecoin-pin` Data Set creation validation are complete.
- Do not announce Mainnet until required cross-repo changes are merged/released or explicitly waived by the technical owner.
- `service_contracts/deployments.json` reflects what is live behind proxies and View contracts. Update it only after the relevant proxy switch and, if applicable, View switch are complete, normally through follow-up PR(s) to `main`, and record PR links in Release Tracking.
- In the normal delay-based flow, the requested delay starts when the Safe announcement executes. After execution, verify both fields returned by `nextUpgrade()` and record its exact `afterEpoch` as the source of truth.
- A later announcement replaces the pending plan. Record the replacement transaction and explicitly mark it as superseding the previous announcement.

### Notice Guidance

| Upgrade Type | Minimum Notice | Recommended |
|---|---:|---|
| Routine | `2880` epochs (~24h) | 1-2 days |
| Breaking change | `20160` epochs (~1 week) | 1-2 weeks |

Calibnet can use a shorter window for rehearsal and validation, but use enough time for signers to coordinate. Select a positive operational delay; the contract's one-epoch floor is an emergency safety bound, not the routine notice policy.

```bash
export UPGRADE_DELAY_EPOCHS=2880 # use 240+ for Calibnet rehearsal, 20160 for breaking changes
echo "Requested upgrade delay: $UPGRADE_DELAY_EPOCHS epochs"
```

### Temporary Bootstrap Compatibility

The rollout that first installs `announceUpgradePlan(address,uint96)` must announce through the currently deployed `announcePlannedUpgrade((address,uint96))` interface. Use `ANNOUNCEMENT_MODE=legacy` with an absolute `AFTER_EPOCH` for both Calibnet and Mainnet during that rollout. Include a conservative Safe-signing buffer so the legacy proposal is still in the future when it executes.

```bash
export ANNOUNCEMENT_MODE=legacy
export LEGACY_NOTICE_EPOCHS=2880
export SAFE_SIGNING_BUFFER_EPOCHS=240
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
export AFTER_EPOCH=$((CURRENT_EPOCH + SAFE_SIGNING_BUFFER_EPOCHS + LEGACY_NOTICE_EPOCHS))
unset UPGRADE_DELAY_EPOCHS
echo "Legacy target epoch: $AFTER_EPOCH"
```

This is a bootstrap exception, not a second long-term workflow. After both networks run an implementation that exposes `announceUpgradePlan`, use the Phase 5 cleanup item to decide whether any rollback path still needs legacy mode and remove it once that path is retired.

### Post-Upgrade Evidence Required

For each network, record evidence that:
- FWSS proxy implementation slot equals the new implementation address.
- `VERSION()` returns the expected FWSS contract version without the leading `v`.
- `nextUpgrade()` is cleared.
- Blockscout shows the proxy and transaction as expected.
- A smoke/E2E test passes. The v1.2.0 rollout used the Synapse SDK storage E2E example.
- A [`filecoin-pin`](https://github.com/filecoin-project/filecoin-pin) `add` flow succeeds after the upgrade with unique Data Set metadata, forcing creation of a new Data Set on the target network. Record the command output, metadata, Data Set ID, tx/link, SP, and timestamp in the Run Log.

### Changes
{{CHANGES_SUMMARY}}

### Action Required for Integrators
{{ACTION_REQUIRED}}

---

## Release Checklist

> Work through the phases in order. Do not announce Mainnet until the Calibnet execute transaction, on-chain checks, smoke/E2E test, and `filecoin-pin` Data Set creation validation are complete.

### Phase 1: Branch, Issue, PR, and Checks
- [ ] All intended FWSS contract changes are merged into `main`
- [ ] Release-prep PR(s) opened for review (prefer one PR when practical) with changelog/release notes, a Deployment note linking to the [GitHub Release page](https://github.com/FilOzone/filecoin-services/releases/tag/{{RELEASE_VERSION}}) for rollout status, addresses, and transaction links, and any applicable version/submodule bump. For FWSS contract changes, include the `FilecoinWarmStorageService` `VERSION()` bump. For PDP-only stack releases, use the PDP/submodule bump PR and leave the FWSS `VERSION()` unchanged. Suggested title: `{{RECOMMENDED_PR_TITLE}}`
- [ ] Upgrade checks run:

```bash
cd service_contracts
forge test --match-contract FilecoinWarmStorageServiceUpgradeTest
forge inspect src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService storageLayout --extra-output storageLayout
```

- [ ] Release-prep PR(s) merged so `main` contains the final release notes and applicable version/submodule changes before creating the release branch
- [ ] Create release branch from `main` after the release-prep PR(s) land (recommended: `{{RELEASE_BRANCH}}`). Use this branch as the stable ref for rendering the release issue and as the landing branch for rollout patches if `main` moves on.
- [ ] Create the release issue by running the [Create Release Issue]({{CREATE_ISSUE_WORKFLOW_LINK}}) workflow from the release branch so the issue is rendered from that branch's checklist template
- [ ] Name the technical owner, update the Overview, and confirm they own the written upgrade plan and go/no-go decision
- [ ] Fill Cross-Repo Impact with required PRs, issues, releases, or `None`
- [ ] Fill Dependency Targets and Compatibility by comparing target versions/addresses with observed Calibnet and Mainnet deployed state
- [ ] Fill Rollback Plan, including whether rollback is safe and the approved procedure/script link when available
- [ ] Run foc-devnet post-upgrade state validation, or record the technical owner's approved exception
- [ ] Freeze the deploy commit and record it in Release Tracking
- [ ] Create and push the stack tag from the frozen deploy commit before any live proxy switch:

```bash
git tag {{RELEASE_VERSION}}
git push origin {{RELEASE_VERSION}}
```

- [ ] Create the GitHub Release from `{{RELEASE_VERSION}}`, mark it as a pre-release, and include component versions plus a FWSS rollout status table:

<details>
<summary>GitHub Release creation commands</summary>

```bash
export RELEASE_ISSUE_URL="TBD" # replace with the generated release issue URL

cat > /tmp/fwss-release-notes.md <<'EOF'
> Status: Pre-release. Calibnet and Mainnet rollout pending; tracked in [the release issue](RELEASE_ISSUE_URL).

## Summary
- TBD

## Component Versions

| Component | Version | Notes |
|---|---|---|
| Stack (`filecoin-services`) | `{{RELEASE_VERSION}}` | Git tag / GitHub Release |
| `FilecoinWarmStorageService` | `{{FWSS_VERSION}}` | Contract `VERSION()` returned by the FWSS proxy |
| `PDPVerifier` | `TBD` | Link PDP release if this stack consumes a new PDP version |

## Rollout Status

| Network | FWSS Proxy | FWSS Implementation | StateView | Announce tx | Actual `afterEpoch` | Execute tx | Status |
|---|---|---|---|---|---:|---|---|
| Calibnet | `0x02925630df557F957f70E112bA06e50965417CA0` | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Pending |
| Mainnet | `0x8408502033C418E1bbC97cE9ac48E5528F371A9f` | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Pending |

## Action Required For Integrators
- TBD
EOF

perl -0pi -e 's|RELEASE_ISSUE_URL|$ENV{RELEASE_ISSUE_URL}|g' /tmp/fwss-release-notes.md

gh release create {{RELEASE_VERSION}} \
  --verify-tag \
  --prerelease \
  --title "FWSS {{RELEASE_VERSION}}" \
  --notes-file /tmp/fwss-release-notes.md
```

</details>

- [ ] Confirm the [Update Synapse SDK]({{SYNAPSE_WORKFLOW_LINK}}) workflow opened or updated the expected Synapse SDK PR and that its integration build passes against the intended contract ABI/types and deployment-address state, or record an exception/owner in Release Tracking. This Phase 1 check is the early ABI/type signal; run the workflow again in Phase 5 after final deployment-address state exists.
- [ ] Release issue Overview and Release Tracking updated with PR links, release link, summary, and action required

### Phase 2: Deploy Contracts
Deploy both networks before any announce/execute.

- [ ] Run the metadata-aware deploy dry-run for each target network before live deployment and record the deploy inventory in the Run Log: `SignatureVerificationLib`, `Rails`, `FilecoinWarmStorageService` implementation, `FilecoinWarmStorageServiceStateView`, and any other contract the tooling marks as needing deployment.
- [ ] For every contract type marked as needing deployment by the dry-run, run the matching [Deploy Contract workflow]({{DEPLOY_WORKFLOW_LINK}}) before live announce. Use `contract=FWSS Implementation` for linked libraries or FWSS implementation changes, and `contract=FWSS StateView` for StateView changes.
- [ ] Run `service_contracts/tools/verify-deployments.sh --chain <CHAIN>` for each target network after deployment metadata is available. Resolve or explicitly waive any bytecode/metadata mismatch before live announce.
- [ ] If linked libraries or StateView are newly deployed, record their addresses, verification status, and ABI-publishing decision in the Run Log.

<details>
<summary>Deployment metadata checks</summary>

```bash
cd service_contracts

ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1" \
  ./tools/verify-deployments.sh --chain 314159

ETH_RPC_URL="https://api.node.glif.io/rpc/v1" \
  ./tools/verify-deployments.sh --chain 314
```

Use the deploy dry-run output to identify contracts that are `Up to date` versus `Would deploy` or otherwise need deployment. Record the final deploy set before any live announce transaction.

| Dry-run marks as needing deployment | Operator action |
|---|---|
| `SignatureVerificationLib` or `Rails` | Run [Deploy Contract workflow]({{DEPLOY_WORKFLOW_LINK}}) with `contract=FWSS Implementation`; the implementation deploy script deploys linked libraries before deploying the FWSS implementation and records their addresses |
| `FilecoinWarmStorageService` implementation | Run [Deploy Contract workflow]({{DEPLOY_WORKFLOW_LINK}}) with `contract=FWSS Implementation` |
| `FilecoinWarmStorageServiceStateView` | Run [Deploy Contract workflow]({{DEPLOY_WORKFLOW_LINK}}) with `contract=FWSS StateView`, then follow the optional StateView switch steps below |
| `ServiceProviderRegistry` or `SessionKeyRegistry` | Only deploy if the release explicitly includes that out-of-scope contract; use its matching Deploy Contract workflow option and add an exception section to this issue |

</details>

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
- [ ] Add both implementation addresses to the GitHub pre-release rollout status. Do not update `service_contracts/deployments.json` until proxy slots are live.

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

**Optional StateView Switch**
- [ ] If the deploy inventory includes a new `FilecoinWarmStorageServiceStateView`, run [Deploy Contract workflow]({{DEPLOY_WORKFLOW_LINK}}) with `contract=FWSS StateView`, `dry_run=true`, then `dry_run=false` for each affected network
- [ ] Capture `CALI_NEW_VIEW` and/or `MAIN_NEW_VIEW`, record the deployed StateView address and verification status in the Run Log, and add the StateView address to the GitHub pre-release rollout table
- [ ] Generate `setViewContract(address)` calldata for each affected network and stage it in Safe UI. Execute the staged `setViewContract` transaction after the corresponding FWSS proxy upgrade execute transaction unless the technical owner approves a different ordering.
- [ ] After each `setViewContract` transaction lands, record its tx link in the Run Log and verify `viewContractAddress()` equals the new StateView address

<details>
<summary>StateView setViewContract calldata and verification</summary>

```bash
# Calibnet
cd service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export FWSS_VIEW_ADDRESS="$CALI_NEW_VIEW"

CALLDATA_ONLY=true ./warm-storage-set-view.sh

CURRENT_VIEW=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'viewContractAddress()(address)')
echo "viewContractAddress(): $CURRENT_VIEW (expected $FWSS_VIEW_ADDRESS)"

# Mainnet
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export FWSS_VIEW_ADDRESS="$MAIN_NEW_VIEW"

CALLDATA_ONLY=true ./warm-storage-set-view.sh

CURRENT_VIEW=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'viewContractAddress()(address)')
echo "viewContractAddress(): $CURRENT_VIEW (expected $FWSS_VIEW_ADDRESS)"
```

In Safe Transaction Builder, set target to the printed FWSS proxy, value to `0`, and data to the printed calldata.

</details>

### Phase 3: Calibnet Announce + Execute

**Announce**
- [ ] Choose the Calibnet announcement mode and requested delay, then update those fields in the schedule table

- [ ] Generate announce calldata and submit/sign/execute in Safe UI:

```bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
```

For the normal delay-based flow:

```bash
export UPGRADE_DELAY_EPOCHS=240 # use a longer window if desired
unset ANNOUNCEMENT_MODE AFTER_EPOCH
```

For the temporary bootstrap rollout only, use this configuration instead:

```bash
export ANNOUNCEMENT_MODE=legacy
export LEGACY_NOTICE_EPOCHS=240
export SAFE_SIGNING_BUFFER_EPOCHS=240
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
export AFTER_EPOCH=$((CURRENT_EPOCH + SAFE_SIGNING_BUFFER_EPOCHS + LEGACY_NOTICE_EPOCHS))
unset UPGRADE_DELAY_EPOCHS
```

Generate the transaction after selecting exactly one configuration above:

```bash
CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

- [ ] In Safe Transaction Builder, set target to the printed FWSS proxy, value to `0`, and data to the printed calldata
- [ ] After the Safe transaction executes, verify and read back the pending plan:

```bash
export ANNOUNCE_TX_HASH="0x..." # Safe execution transaction hash

CURRENT_VIEW=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'viewContractAddress()(address)')

UPGRADE_PLAN=($(cast call --rpc-url "$ETH_RPC_URL" \
  "$CURRENT_VIEW" \
  'nextUpgrade()(address,uint96)'))

OBSERVED_IMPL=${UPGRADE_PLAN[0]}
OBSERVED_AFTER_EPOCH=${UPGRADE_PLAN[1]}
echo "Planned implementation: $OBSERVED_IMPL (expected $CALI_NEW_IMPL)"
echo "Actual afterEpoch: $OBSERVED_AFTER_EPOCH"

if [ "${ANNOUNCEMENT_MODE:-delay}" = "legacy" ]; then
  EXPECTED_AFTER_EPOCH=$AFTER_EPOCH
else
  ANNOUNCE_EPOCH=$(cast receipt --rpc-url "$ETH_RPC_URL" "$ANNOUNCE_TX_HASH" blockNumber)
  EFFECTIVE_DELAY_EPOCHS=$UPGRADE_DELAY_EPOCHS
  [ "$EFFECTIVE_DELAY_EPOCHS" -eq 0 ] && EFFECTIVE_DELAY_EPOCHS=1
  EXPECTED_AFTER_EPOCH=$((ANNOUNCE_EPOCH + EFFECTIVE_DELAY_EPOCHS))
fi

if [ "$(printf '%s' "$OBSERVED_IMPL" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$CALI_NEW_IMPL" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "ERROR: announced implementation mismatch"
  exit 1
fi
if [ "$OBSERVED_AFTER_EPOCH" -ne "$EXPECTED_AFTER_EPOCH" ]; then
  echo "ERROR: afterEpoch mismatch ($OBSERVED_AFTER_EPOCH != $EXPECTED_AFTER_EPOCH)"
  exit 1
fi
```

- [ ] Record the Calibnet announce tx and observed `afterEpoch` in the schedule and Run Log
- [ ] Update the GitHub pre-release Calibnet rollout status with the announce tx and observed `afterEpoch`

**Execute**
- [ ] Wait for the observed Calibnet `afterEpoch`
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
- [ ] Verify `VERSION()` returns the expected FWSS contract version
- [ ] Verify `viewContractAddress()` equals `CALI_NEW_VIEW` if a StateView switch was expected, or the unchanged View address otherwise
- [ ] Verify `nextUpgrade()` is cleared

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"
export EXPECTED_FWSS_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
export EXPECTED_FWSS_VERSION="{{FWSS_VERSION}}"
export EXPECTED_FWSS_VIEW_ADDRESS="${CALI_NEW_VIEW:-unchanged}"

CURRENT_VIEW=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'viewContractAddress()(address)')
if [ "$EXPECTED_FWSS_VIEW_ADDRESS" = "unchanged" ]; then
  EXPECTED_FWSS_VIEW_ADDRESS="$CURRENT_VIEW"
fi

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
echo "VERSION(): $ACTUAL_VERSION (expected $EXPECTED_FWSS_VERSION)"
echo "viewContractAddress(): $CURRENT_VIEW (expected $EXPECTED_FWSS_VIEW_ADDRESS)"
echo "nextUpgrade(): $NEXT_UPGRADE (expected zero address and 0)"

if [ "$(printf '%s' "$CURRENT_VIEW" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$EXPECTED_FWSS_VIEW_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "ERROR: viewContractAddress() mismatch"
  exit 1
fi
```

- [ ] Verify FWSS pricing output, such as `getPriceList()`, matches the intended release pricing and record the command/output in the Run Log
- [ ] Run and record a Calibnet smoke/E2E test result
- [ ] Validate Calibnet Data Set creation through [`filecoin-pin add`](https://github.com/filecoin-project/filecoin-pin) with `--network calibration` and unique `--data-set-metadata`, then record the command output, metadata, Data Set ID, tx/link, SP, and timestamp in the Run Log

<details>
<summary>Calibnet filecoin-pin validation</summary>

```bash
RUN_ID="fwss-{{RELEASE_VERSION}}-calibnet-$(date -u +%Y%m%dT%H%M%SZ)"
printf "FWSS {{RELEASE_VERSION}} Calibnet smoke %s\n" "$RUN_ID" > "/tmp/$RUN_ID.txt"

filecoin-pin add "/tmp/$RUN_ID.txt" \
  --network calibration \
  --data-set-metadata fwss_release={{RELEASE_VERSION}} \
  --data-set-metadata smoke_run="$RUN_ID"
```

The unique `smoke_run` metadata is required so this validates new Data Set creation rather than reusing an existing Data Set.

</details>

- [ ] Verify the proxy on Blockscout
- [ ] Update the GitHub pre-release Calibnet rollout status with execute tx, checks, and smoke/E2E evidence
- [ ] If Calibnet deployment addresses should be published before Mainnet, open or update a Calibnet-only follow-up PR to `main` for `service_contracts/deployments.json` after the Calibnet proxy switch and, if applicable, View switch are live, then record the PR link in Release Tracking. Otherwise record that the `deployments.json` update will wait for Mainnet.
- [ ] Technical owner confirms Calibnet results are good before announcing Mainnet

### Phase 4: Mainnet Announce + Execute

**Announce**
- [ ] Technical owner records Mainnet go/no-go after reviewing Calibnet evidence, rollback status, dependency targets, and cross-repo status
- [ ] Confirm required cross-repo changes are merged/released or explicitly waived by the technical owner
- [ ] Notify stakeholders before announcing Mainnet, including FilB so they can propagate the upgrade notice
- [ ] Choose the Mainnet announcement mode and requested delay, then update those fields in the schedule table

- [ ] Generate announce calldata and submit/sign/execute in Safe UI:

```bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
```

For the normal delay-based flow:

```bash
export UPGRADE_DELAY_EPOCHS=2880 # use 20160 for breaking changes
unset ANNOUNCEMENT_MODE AFTER_EPOCH
```

For the temporary bootstrap rollout only, use this configuration instead:

```bash
export ANNOUNCEMENT_MODE=legacy
export LEGACY_NOTICE_EPOCHS=2880
export SAFE_SIGNING_BUFFER_EPOCHS=2880
CURRENT_EPOCH=$(cast block-number --rpc-url "$ETH_RPC_URL")
export AFTER_EPOCH=$((CURRENT_EPOCH + SAFE_SIGNING_BUFFER_EPOCHS + LEGACY_NOTICE_EPOCHS))
unset UPGRADE_DELAY_EPOCHS
```

Generate the transaction after selecting exactly one configuration above:

```bash
CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
```

- [ ] In Safe Transaction Builder, set target to the printed FWSS proxy, value to `0`, and data to the printed calldata
- [ ] After the Safe transaction executes, verify and read back the pending plan:

```bash
export ANNOUNCE_TX_HASH="0x..." # Safe execution transaction hash

CURRENT_VIEW=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'viewContractAddress()(address)')

UPGRADE_PLAN=($(cast call --rpc-url "$ETH_RPC_URL" \
  "$CURRENT_VIEW" \
  'nextUpgrade()(address,uint96)'))

OBSERVED_IMPL=${UPGRADE_PLAN[0]}
OBSERVED_AFTER_EPOCH=${UPGRADE_PLAN[1]}
echo "Planned implementation: $OBSERVED_IMPL (expected $MAIN_NEW_IMPL)"
echo "Actual afterEpoch: $OBSERVED_AFTER_EPOCH"

if [ "${ANNOUNCEMENT_MODE:-delay}" = "legacy" ]; then
  EXPECTED_AFTER_EPOCH=$AFTER_EPOCH
else
  ANNOUNCE_EPOCH=$(cast receipt --rpc-url "$ETH_RPC_URL" "$ANNOUNCE_TX_HASH" blockNumber)
  EFFECTIVE_DELAY_EPOCHS=$UPGRADE_DELAY_EPOCHS
  [ "$EFFECTIVE_DELAY_EPOCHS" -eq 0 ] && EFFECTIVE_DELAY_EPOCHS=1
  EXPECTED_AFTER_EPOCH=$((ANNOUNCE_EPOCH + EFFECTIVE_DELAY_EPOCHS))
fi

if [ "$(printf '%s' "$OBSERVED_IMPL" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$MAIN_NEW_IMPL" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "ERROR: announced implementation mismatch"
  exit 1
fi
if [ "$OBSERVED_AFTER_EPOCH" -ne "$EXPECTED_AFTER_EPOCH" ]; then
  echo "ERROR: afterEpoch mismatch ($OBSERVED_AFTER_EPOCH != $EXPECTED_AFTER_EPOCH)"
  exit 1
fi
```

- [ ] Record the Mainnet announce tx and observed `afterEpoch` in the schedule and Run Log
- [ ] Update the GitHub pre-release Mainnet rollout status with the announce tx and observed `afterEpoch`

**Execute**
- [ ] Wait for the observed Mainnet `afterEpoch`
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
- [ ] Verify `VERSION()` returns the expected FWSS contract version
- [ ] Verify `viewContractAddress()` equals `MAIN_NEW_VIEW` if a StateView switch was expected, or the unchanged View address otherwise
- [ ] Verify `nextUpgrade()` is cleared

```bash
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
export EXPECTED_FWSS_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
export EXPECTED_FWSS_VERSION="{{FWSS_VERSION}}"
export EXPECTED_FWSS_VIEW_ADDRESS="${MAIN_NEW_VIEW:-unchanged}"

CURRENT_VIEW=$(cast call --rpc-url "$ETH_RPC_URL" \
  "$FWSS_PROXY_ADDRESS" \
  'viewContractAddress()(address)')
if [ "$EXPECTED_FWSS_VIEW_ADDRESS" = "unchanged" ]; then
  EXPECTED_FWSS_VIEW_ADDRESS="$CURRENT_VIEW"
fi

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
echo "VERSION(): $ACTUAL_VERSION (expected $EXPECTED_FWSS_VERSION)"
echo "viewContractAddress(): $CURRENT_VIEW (expected $EXPECTED_FWSS_VIEW_ADDRESS)"
echo "nextUpgrade(): $NEXT_UPGRADE (expected zero address and 0)"

if [ "$(printf '%s' "$CURRENT_VIEW" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$EXPECTED_FWSS_VIEW_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "ERROR: viewContractAddress() mismatch"
  exit 1
fi
```

- [ ] Verify FWSS pricing output, such as `getPriceList()`, matches the intended release pricing and record the command/output in the Run Log
- [ ] Run and record a Mainnet smoke/E2E test result
- [ ] Validate Mainnet Data Set creation through [`filecoin-pin add`](https://github.com/filecoin-project/filecoin-pin) with `--network mainnet` and unique `--data-set-metadata`, then record the command output, metadata, Data Set ID, tx/link, SP, and timestamp in the Run Log

<details>
<summary>Mainnet filecoin-pin validation</summary>

```bash
RUN_ID="fwss-{{RELEASE_VERSION}}-mainnet-$(date -u +%Y%m%dT%H%M%SZ)"
printf "FWSS {{RELEASE_VERSION}} Mainnet smoke %s\n" "$RUN_ID" > "/tmp/$RUN_ID.txt"

filecoin-pin add "/tmp/$RUN_ID.txt" \
  --network mainnet \
  --data-set-metadata fwss_release={{RELEASE_VERSION}} \
  --data-set-metadata smoke_run="$RUN_ID"
```

The unique `smoke_run` metadata is required so this validates new Data Set creation rather than reusing an existing Data Set.

</details>

- [ ] Verify the proxy on Blockscout
- [ ] Update the GitHub pre-release Mainnet rollout status with execute tx, checks, and smoke/E2E evidence

### Phase 5: Promote Release and Close Out
- [ ] Confirm live Calibnet and Mainnet FWSS implementation slots match the new implementation addresses
- [ ] If this is the bootstrap rollout for `announceUpgradePlan`, decide whether rollback to an implementation without that selector is still supported. Once both networks are upgraded **and** that rollback path is retired, open and merge a follow-up PR that removes `ANNOUNCEMENT_MODE=legacy`, its `AFTER_EPOCH` handling, the README bootstrap example, and the Temporary Bootstrap Compatibility instructions; record the cleanup PR link. If rollback remains supported, retain legacy mode or document the exact tagged helper that operators must use. For later releases, mark this `N/A` with the versions observed on both networks.
- [ ] Confirm cross-repo follow-ups are complete or tracked with owners
- [ ] Open or update follow-up PR(s) to `main` for `service_contracts/deployments.json` after the relevant Calibnet/Mainnet proxy switches and, if applicable, View switches are live. Include live implementation addresses, View addresses, deployment bytecode metadata, and `pdp_version` / `fwss_version` fields for each updated network.
- [ ] Record the `service_contracts/deployments.json` PR link(s) in Release Tracking, then merge after checksum validation, bytecode metadata verification, and live-slot verification
- [ ] Verify final `service_contracts/deployments.json` bytecode metadata matches the live deployed contracts after all proxy and View switches are complete

<details>
<summary>Deployment bytecode metadata verification commands</summary>

```bash
cd service_contracts

# Calibnet
CHAIN=314159 ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1" \
  ./tools/verify-deployments.sh

# Mainnet
CHAIN=314 ETH_RPC_URL="https://api.node.glif.io/rpc/v1" \
  ./tools/verify-deployments.sh
```

</details>

- [ ] Merge release-prep PR(s) if still open, keeping mutable rollout details on the GitHub Release page
- [ ] Promote the GitHub Release from pre-release to latest after Mainnet proxy switch, checks, and release-page status are complete
- [ ] Publish or update required ABIs after linked-library or interface changes: run `make -C service_contracts update-abi` for checked-in `service_contracts/abi` updates, confirm the Synapse SDK workflow regenerated downstream ABI/types, and record any explicit linked-library ABI publishing target or `None required`

<details>
<summary>ABI update commands</summary>

```bash
make -C service_contracts update-abi
git status --short service_contracts/abi
```

</details>

- [ ] Run the [Update Synapse SDK]({{SYNAPSE_WORKFLOW_LINK}}) workflow manually with the release tag and the approved source ref/SHA after the intended deployment address state is available, or record an exception/owner in Release Tracking. This Phase 5 run is the final address-state update and should not be skipped because the Phase 1 ABI/type signal already ran.
- [ ] Merge auto-generated PRs in [filecoin-cloud](https://github.com/FilOzone/filecoin-cloud/pulls)
- [ ] Confirm Synapse PR/release is merged or owned
- [ ] Capture lessons learned from this rollout and update [`service_contracts/tools/UPGRADE-CHECKLIST.md`]({{CHECKLIST_UPDATE_LINK}}) if the process should change
- [ ] Add release link to this issue
- [ ] Close this issue

---

### Resources
- [Changelog]({{CHANGELOG_LINK}})
- [Upgrade Checklist Source]({{CHECKLIST_LINK}})
<!-- ISSUE_TEMPLATE_END -->

## Notes From v1.3.0

- Identify linked libraries and StateView changes before deploy. If the release needs new linked libraries, a new `FilecoinWarmStorageServiceStateView`, or a follow-up `setViewContract`, track those explicitly before deploying the FWSS implementation.
- Rollback must be explicit before live announce. Record either an approved rollback procedure or a written technical-owner decision that rollback is unsafe or not available for this rollout.
- Run Synapse updates from the intended deployment-address state. If the Synapse workflow or PR is run before `service_contracts/deployments.json` reflects live addresses, record the exception and owner.
- Final changelog updates should not fold post-tag source changes into the released version section. Put post-tag source changes under `Unreleased` or the next release.
- Use the GitHub Release page for mutable rollout details. CHANGELOG entries should describe what changed and link to the release page for deployment addresses, epochs, txs, and validation evidence.

## Notes From v1.2.0

- Track Calibnet and Mainnet `AFTER_EPOCH` values in a small schedule table near the top of the issue.
- Keep announce and execute transaction links close to the schedule or in short phase comments.
- Keep a top-level run log with implementation addresses, tx links, and post-upgrade evidence so the issue is skimmable.
- Notify FilB before Mainnet announce so they can propagate contract-upgrade information.
- Run a smoke/E2E check after each network executes; the v1.2.0 rollout used the Synapse SDK storage E2E example.
- If an `AFTER_EPOCH` changes, record that the later announcement supersedes the earlier one.
- FilFox verification was flaky during the `v1.2.0` rollout. Record the result, but do not let it block Sourcify + Blockscout verification.
