# FWSS Upgrade Checklist and Runbook

This file is the canonical, self-contained template for FWSS release issues.

- Keep this template focused on upgrading the contract code behind the existing FWSS proxy.
- Start every rollout by running the [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) workflow from `main`, before opening release-prep PRs or creating a release branch. The generated issue is the operator checklist for those steps as well as the rollout itself.
- Customize the generated issue for release-specific exceptions. Put reusable process improvements in this file through a normal PR to `main`.
- The generated issue should contain everything a release engineer needs for a normal FWSS upgrade.
- The procedures exist to give the operator and every Safe signer confidence that what executes is exactly what was reviewed. Each check guards against an honest mistake and against a malicious proposer, deployer, or compromised tool alike. Do not skip a check because someone else already ran it: independent repetition is the protection.

<!-- ISSUE_TEMPLATE_START -->
## Overview

| Field | Value |
|-------|-------|
| **Stack Version** | `{{RELEASE_VERSION}}` |
| **Upgrade Type** | `{{UPGRADE_TYPE}}` |
| **Upgrade Path** | `TBD: A (one-time dispatcher transition) / B (josuke migration)` — see [Choose the Upgrade Path](#choose-the-upgrade-path) |
| **Release-prep PR(s)** | {{RELEASE_PREP_PR}} |
| **Technical Owner** | `TBD` |
| **Go/No-Go Status** | `TBD` |

> **Start here:** Choose the upgrade path, then work through the [Release Checklist](#release-checklist) from Phase 1. Expand the supporting sections below only when you need their context or evidence tables.

### Choose the Upgrade Path

FWSS is moving from a single UUPS implementation (the v1.4.0 monolith) to an ERC-8167 dispatcher that routes each function selector to a module. The proxy address never changes; what sits behind it decides the path.

- **Path A — one-time dispatcher transition.** The proxy still runs the v1.4.0 monolith. The monolith's own delayed UUPS upgrade installs `FWSSDispatcherTransition`, which in the same call points the proxy at the dispatcher and runs the josuke migration that writes the routes. This happens once per network.
- **Path B — josuke migration.** The proxy already runs the dispatcher. Every later upgrade deploys changed modules with `josuke deploy`, announces the migration that reroutes their selectors, runs it after the delay, and records it with `josuke accept`.

Determine the path from chain state for each network, not from memory or `deployments.json`:

```bash
cd service_contracts
IMPL=$(cast implementation --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS")
IMPL_CODEHASH=$(cast keccak "$(cast code --rpc-url "$ETH_RPC_URL" "$IMPL")")
PINNED_DISPATCHER_CODEHASH=$(grep -o '0x[0-9a-f]\{64\}' <<< "$(grep 'FWSS_DISPATCHER_CODE_HASH =' src/FWSSDispatcherTransition.sol)")
echo "Implementation $IMPL, code hash $IMPL_CODEHASH"
[ "$IMPL_CODEHASH" = "$PINNED_DISPATCHER_CODEHASH" ] && echo "Path B: dispatcher installed" || echo "Path A: monolith installed"
```

If Calibnet and Mainnet are on different paths, record the path per network in the Run Log and follow each network's path.

### How the Upgrade Functions Differ

The selector `migrate(address)` exists on both sides of the transition with different meanings. Read this table before preparing or signing any upgrade transaction.

| Step | Path A: monolith (UUPS) | Path B: dispatcher (ERC-8167) |
|---|---|---|
| Announce | `announceUpgradePlan(address newImplementation, uint96 delayEpochs)` with the transition as `newImplementation` | `announceMigration(address migration, uint96 delayEpochs)` with the josuke migration |
| Pending plan | Storage slot 19 of the proxy: `(nextImplementation, afterEpoch)` | Same slot 19: `(migration, afterEpoch)` |
| Execute | `upgradeToAndCall(transition, migrate(migration))` | `migrate(migration)` |
| What `migrate(address)` does | Inside the upgrade call, the transition's `migrate` points the proxy at the dispatcher and delegatecalls the pinned migration, which writes every route. On the monolith itself, `migrate(address)` only ever set the legacy view contract address; it is not part of either flow and must never be signed as a standalone transaction. | Runs the announced migration in the proxy's storage after `afterEpoch`, consumes the plan, then reverts if the migration changed the proxy's implementation or removed the `implementation`, `selectors`, `announceMigration`, or `migrate` routes. |
| What pins the code | The transition pins the migration's address **and code hash**, the dispatcher (whose code hash is pinned in source), and the rollback target | Only the migration's **address** is pinned. `josuke verify` checks the migration's code before the announcement, during the delay, and before execution (see [Procedure B](#procedure-b-josuke-migration)). |
| Abort before execution | A later announcement replaces the pending plan | A later announcement replaces the pending plan |
| Recovery after execution | `abortTransition()` on the proxy restores the monolith **only** if the transition was installed with empty upgrade data. A successful transition cannot be undone; fix forward with Path B. | Announce and run another migration that restores the previous routes, subject to the announce delay |
| Ledger | `josuke deploy` stages the modules and migration under `proposed` in `josuke.json`; `josuke accept` promotes them to `current` | Same |

<details>
<summary><strong>Release tracking and rollout records</strong> — tags, versions, deployment snapshots, schedule, and transaction evidence</summary>

### Release Tracking

The filecoin-services GitHub release version is the stack version. It may differ from an individual contract `VERSION()` when the stack changes without an FWSS code change.

| Item | Value |
|---|---|
| Frozen deploy commit | `TBD` |
| GitHub pre-release | `TBD` |
| Release status | `Pre-release until the Mainnet upgrade is verified` |
| `josuke.json` / `deployments.json` PR(s) | `TBD` |
| Synapse SDK PR | `TBD` |

Field ownership for duplicated rollout data:

| Data | Source of truth | Mirror/update |
|---|---|---|
| Operator status, owner decisions, exceptions, and in-progress tx/check evidence | This release issue: Release Tracking and Run Log | Mirror externally useful rollout status to the GitHub Release page |
| Live contract state | Chain state read from the FWSS proxy: implementation slot, pending-plan slot 19, and dispatcher routes | Record observed values in the Run Log and use them for go/no-go |
| Staged and live routes | `service_contracts/josuke.json`: `proposed` is staged, `current` is live after `josuke accept` | Commit after each `josuke deploy` and `josuke accept` |
| Consumer-facing release status, addresses, epochs, and tx links | GitHub Release page | Populate from the Run Log as rollout facts become final |
| Repo deployment snapshot | `service_contracts/deployments.json` on `main` | Update by follow-up PR(s) |

### Component Versions

| Component | Version | Changed? | Notes |
|---|---|---|---|
| Stack (`filecoin-services`) | `{{RELEASE_VERSION}}` | Yes | Git tag / GitHub Release |
| `FilecoinWarmStorageService` | `{{FWSS_VERSION}}` | `TBD` | `VERSION()` returned by the FWSS proxy |
| `PDPVerifier` | `TBD` | `TBD` | Link PDP release if this stack consumes a new PDP version |

### Upgrade Schedule

| Network | Path | Requested delay | Actual `afterEpoch` | Status |
|---|---|---:|---:|---|
| Calibnet | `TBD` | `TBD` | `TBD` | Pending |
| Mainnet | `TBD` | `TBD` | `TBD` | Pending |

Set the requested delay before proposing the Safe transaction. Fill in the actual `afterEpoch` from slot 19 after the announcement executes. The observed value is the source of truth for the execute step and external communications.

### Run Log

The Run Log is this release issue's operator journal for rollout facts discovered during execution: deployed addresses, code hashes, transaction links, validation outputs, exceptions, and owner decisions.

Keep this table current as values become known.

| Network | Path | Announced target (transition or migration) | Announce tx | Actual `afterEpoch` | Execute tx | `josuke accept` commit | Post-upgrade checks |
|---|---|---|---|---:|---|---|---|
| Calibnet | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Pending |
| Mainnet | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Pending |

</details>

<details>
<summary><strong>Scope and validation plan</strong> — cross-repo impact, dependencies, rollback, and pre-live evidence</summary>

### Scope
- In scope: the FWSS code behind the existing FWSS proxy — the one-time dispatcher transition (Path A) or the modules and migration of a josuke upgrade (Path B).
- Out of scope by default: `ServiceProviderRegistry`, `PDPVerifier`, `FilecoinPay`, and `SessionKeyRegistry`.
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

Populate this table while reviewing the Phase 1 inventory. The technical owner records the compatibility disposition for every dependency before approving the inventory.

| Dependency | Target version/address | Calibnet observed | Mainnet observed | Verification/status |
|---|---|---|---|---|
| `PDPVerifier` | `TBD` | `TBD` | `TBD` | `TBD` |
| `FilecoinPay` | `TBD` | `TBD` | `TBD` | `TBD` |
| `ServiceProviderRegistry` | `TBD` | `TBD` | `TBD` | `TBD` |
| `SessionKeyRegistry` | `TBD` | `TBD` | `TBD` | `TBD` |

### Rollback Plan

State the recovery plan before any live announce transaction. The [function table](#how-the-upgrade-functions-differ) lists what each path allows.

| Field | Value |
|---|---|
| Recovery status | `TBD: Abortable / Fix-forward only / Not applicable` |
| Previous implementation (Path A) or previous `current` routes (Path B) | `TBD` |
| Recovery procedure | `TBD` |
| Decision notes | `TBD` |

### Pre-Live Validation

Record validation that proves the planned upgrade works against the full contract, Curio, and Synapse state before live rollout.

| Validation | Evidence/status |
|---|---|
| foc-devnet post-upgrade state validation | `TBD` |
| Pricing validation | `TBD`: link command output, test run, or issue comment confirming FWSS pricing values match the intended release pricing before live rollout. |
| Synapse SDK integration build | `TBD`: link the Synapse SDK PR/check run that builds against the intended contract ABI/types and deployment-address state, or record the owner-approved exception. |

</details>

<details>
<summary><strong>Operator reference</strong> — network constants, operating rules, notice guidance, and required post-upgrade evidence</summary>

### Network Constants

| Network | Chain ID | RPC URL | FWSS Proxy | Safe Owner |
|---|---:|---|---|---|
| Calibnet | `314159` | `https://api.calibration.node.glif.io/rpc/v1` | `0x02925630df557F957f70E112bA06e50965417CA0` | `0x6386622B4915B027900d65560b0ab84F8a1ff2AA` |
| Mainnet | `314` | `https://api.node.glif.io/rpc/v1` | `0x8408502033C418E1bbC97cE9ac48E5528F371A9f` | `0x6386622B4915B027900d65560b0ab84F8a1ff2AA` |

Every procedure below runs from `service_contracts/` in one of these environments:

```bash
cd service_contracts

# Calibnet
export CHAIN=314159
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x02925630df557F957f70E112bA06e50965417CA0"

# Mainnet
export CHAIN=314
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="0x8408502033C418E1bbC97cE9ac48E5528F371A9f"
```

`cast` unlocks `ETH_KEYSTORE` even for read-only calls and then sends them from the keystore address (foundry-rs/foundry#17388, see #621). Keep `ETH_KEYSTORE` out of the environment for every read-only step; set it only for `josuke deploy` and the transition deploy script.

### Operating Rules

- **Reproduce before you sign.** Every Safe signer regenerates the calldata from this checklist on their own machine, decodes it, and confirms it byte-for-byte against the Safe UI before signing. Never sign calldata you only received from someone else.
- **Read state, not reports.** Confirm every announcement, execution, and post-check against chain state (implementation slot, slot 19, dispatcher routes, code hashes). A screenshot, a log line, or `deployments.json` is not evidence of live state.
- **Verify code, not just addresses.** Before signing an announce or execute transaction, run `josuke verify`, and for Path A check the transition's pins. An address alone does not prove what will run.
- **Treat surprises as incidents.** An announcement, route change, or implementation change that is not in this issue's Run Log is an incident: stop, notify the technical owner and signers, and do not execute anything until it is explained. A pending plan can be replaced by a new announcement.
- Use the release issue as the rollout source of truth. Keep the schedule, Run Log, tx links, and post-upgrade evidence current.
- Create the stack tag and GitHub Release before any live upgrade transaction. Mark the GitHub Release as a pre-release until Mainnet is complete and verified.
- Keep the GitHub pre-release page updated as the external rollout tracker for consumers; keep this issue updated as the operator runbook.
- Keep CHANGELOG focused on what changed. Put mutable deployment status, addresses, epochs, and transaction links on the GitHub Release page.
- **Tag semantics:** The `vX.Y.Z` tag is immutable and points to the frozen deploy commit used for contract deployment and bytecode verification. Post-deploy rollout facts such as live addresses, epochs, tx links, and `josuke.json` / `deployments.json` follow-up PRs are not folded back into the tag. They live on `main`, the release issue Run Log, and the GitHub Release page. Do not create a second "final release" tag.
- **Where to find what:** Use the `vX.Y.Z` tag for the source that produced the deployed bytecode. Use on-chain reads from the FWSS proxy for live state: the implementation slot, slot 19, `implementation(bytes4)` for each route, and address getters such as `pdpVerifierAddress()`, `paymentsContractAddress()`, `serviceProviderRegistry()`, `sessionKeyRegistry()`, `usdfcTokenAddress()`, and `filBeamBeneficiaryAddress()`. Use the GitHub Release rollout table for the historical record of what was live for this release.
- `josuke.json` and `deployments.json` on a release branch or `vX.Y.Z` tag are the copies that existed at branch-cut/tag time. Do not use them as live state. Commit `josuke.json` after every `josuke deploy` and `josuke accept` so reviewers verify the same ledger the operator used.
- The technical owner owns the written upgrade plan, dependency target verification, and final go/no-go decision.
- Before any live announce transaction, fill in the Technical Owner, Upgrade Path, Cross-Repo Impact, Dependency Targets and Compatibility, Rollback Plan, and foc-devnet validation status.
- In Safe Transaction Builder, the target is the FWSS proxy, value is `0`, and data is the calldata you reproduced.
- Do not announce Mainnet until Calibnet execution, on-chain checks, `josuke accept`, explorer checks, smoke/E2E checks, and `filecoin-pin` Data Set creation validation are complete.
- Do not announce Mainnet until required cross-repo changes are merged/released or explicitly waived by the technical owner.
- The requested delay starts when the Safe announcement executes. After execution, read slot 19 and record its exact `afterEpoch` as the source of truth.
- A later announcement replaces the pending plan. Record the replacement transaction and explicitly mark it as superseding the previous announcement.

### Notice Guidance

| Upgrade Type | Minimum Notice | Recommended |
|---|---:|---|
| Routine | `2880` epochs (~24h) | 1-2 days |
| Breaking change | `20160` epochs (~1 week) | 1-2 weeks |

Calibnet can use a shorter window for rehearsal and validation, but use enough time for signers and reviewers to coordinate. The delay is the window in which anyone can detect a bad announcement, so select a positive operational delay; the contract's one-epoch floor is an emergency safety bound, not the routine notice policy.

```bash
export UPGRADE_DELAY_EPOCHS=2880 # use 240+ for Calibnet rehearsal, 20160 for breaking changes
echo "Requested upgrade delay: $UPGRADE_DELAY_EPOCHS epochs"
```

### Post-Upgrade Evidence Required

For each network, record evidence that:
- The FWSS proxy implementation slot holds the dispatcher, and its code hash equals `FWSS_DISPATCHER_CODE_HASH` in `src/FWSSDispatcherTransition.sol`.
- Slot 19 is cleared.
- `josuke accept` succeeded against the live chain and the resulting `josuke.json` is committed.
- `owner()` is still the Safe owner.
- `VERSION()` returns the expected FWSS contract version without the leading `v`.
- Blockscout shows the proxy and transaction as expected.
- A smoke/E2E test passes. The v1.2.0 rollout used the Synapse SDK storage E2E example.
- A [`filecoin-pin`](https://github.com/filecoin-project/filecoin-pin) `add` flow succeeds after the upgrade with unique Data Set metadata, forcing creation of a new Data Set on the target network. Record the command output, metadata, Data Set ID, tx/link, SP, and timestamp in the Run Log.

</details>

<details>
<summary><strong>Release notes and integrator action</strong> — summary of changes and any required downstream action</summary>

### Changes
{{CHANGES_SUMMARY}}

### Action Required for Integrators
{{ACTION_REQUIRED}}

</details>

---

## Release Checklist

> Work through the phases in order. Do not announce Mainnet until the Calibnet execute transaction, on-chain checks, `josuke accept`, smoke/E2E test, and `filecoin-pin` Data Set creation validation are complete.

### Phase 1: Issue, PR, Branch, and Checks
- [ ] Create the release issue by running the [Create Release Issue]({{CREATE_ISSUE_WORKFLOW_LINK}}) workflow from `main`. Do this before the remaining release-prep and branch steps so the generated issue tracks the complete process.
- [ ] Determine the upgrade path for each network from chain state ([Choose the Upgrade Path](#choose-the-upgrade-path)) and record it in the Overview and Upgrade Schedule
- [ ] All intended FWSS contract changes are merged into `main`
- [ ] Release-prep PR(s) opened for review (prefer one PR when practical) with changelog/release notes, a Deployment note linking to the [GitHub Release page](https://github.com/FilOzone/filecoin-services/releases/tag/{{RELEASE_VERSION}}) for rollout status, addresses, and transaction links, and any applicable version/submodule bump. For FWSS contract changes, include the FWSS `VERSION()` bump. For PDP-only stack releases, use the PDP/submodule bump PR and leave the FWSS `VERSION()` unchanged. Suggested title: `{{RECOMMENDED_PR_TITLE}}`
- [ ] Upgrade checks pass on the release candidate:

```bash
cd service_contracts
make check-josuke   # ledger schema, facet sources, selector collisions, sizes, and storage against every recorded deployment, offline
make test           # builds the ERC-8167 dispatcher artifacts the tests need (make erc8167), then runs forge test
```

`josuke check` must list exactly the facets this release intends to change as `new`, `changed`, or `removed`, and nothing else. Stop if it reports a facet it cannot deploy.

- [ ] Release-prep PR(s) merged so `main` contains the final release notes and applicable version/submodule changes before creating the release branch
- [ ] Create the release branch from `main` after the release-prep PR(s) land (recommended: `{{RELEASE_BRANCH}}`), then record its name and commit in the existing release issue. Do not create a second release issue.
- [ ] Name the technical owner, update the Overview, and confirm they own the written upgrade plan and go/no-go decision
- [ ] Obtain technical-owner approval of the two-network deployment inventory:
  - Run `josuke check --chain 314159` and `josuke check --chain 314` and record the listed facets.
  - **Path A only:** record each network's current implementation (`cast implementation --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS"`). It is the transition's rollback target, and Procedure A2 checks the transition pins it.
  - Populate Dependency Targets and Compatibility. Stop, correct the release ref, and rerun for any unapproved difference.
- [ ] Fill Cross-Repo Impact with required PRs, issues, releases, or `None`
- [ ] Fill Rollback Plan from the [function table](#how-the-upgrade-functions-differ)
- [ ] Run foc-devnet post-upgrade state validation, or record the technical owner's approved exception
- [ ] Freeze the deploy commit and record it in Release Tracking
- [ ] Create and push the stack tag from the frozen deploy commit before any live upgrade transaction:

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
| `FilecoinWarmStorageService` | `{{FWSS_VERSION}}` | `VERSION()` returned by the FWSS proxy |
| `PDPVerifier` | `TBD` | Link PDP release if this stack consumes a new PDP version |

## Rollout Status

| Network | FWSS Proxy | Announced target | Announce tx | Actual `afterEpoch` | Execute tx | Status |
|---|---|---|---|---:|---|---|
| Calibnet | `0x02925630df557F957f70E112bA06e50965417CA0` | `TBD` | `TBD` | `TBD` | `TBD` | Pending |
| Mainnet | `0x8408502033C418E1bbC97cE9ac48E5528F371A9f` | `TBD` | `TBD` | `TBD` | `TBD` | Pending |

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
Deploy both networks from the frozen tag before any announce/execute. Deploying is permissionless and changes nothing behind the proxy; only the Safe's announce and execute transactions do.

- [ ] **Calibnet:** run [Procedure A1](#a1-deploy) (Path A) or [Procedure B1](#b1-deploy) (Path B) in the Calibnet environment
- [ ] **Mainnet:** run [Procedure A1](#a1-deploy) (Path A) or [Procedure B1](#b1-deploy) (Path B) in the Mainnet environment
- [ ] Open a PR with the updated `josuke.json` (and, for Path A, `deployments.json`) and record it in Release Tracking. Reviewers verify against this exact ledger.
- [ ] A second engineer runs `josuke verify` in each environment from the PR's commit and records the result in the Run Log
- [ ] Add the announced target for each network to the GitHub pre-release rollout status

### Phase 3: Calibnet Announce + Execute

**Announce**
- [ ] If this release has a ServiceProviderRegistry exception, generate its Calibnet announcement with `NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS="$CALI_NEW_SPR_IMPL" UPGRADE_DELAY_EPOCHS=<delay> CALLDATA_ONLY=true ./tools/service-provider-registry-announce-upgrade.sh`, execute it through the owner Safe, then verify and record the exact implementation and observed `afterEpoch` returned by `nextUpgrade()` before any execute transaction.
- [ ] Set the Calibnet requested delay and update the schedule table
- [ ] Run [Procedure A2](#a2-announce) or [Procedure B2](#b2-announce) in the Calibnet environment
- [ ] Record the Calibnet announce tx and observed `afterEpoch` in the schedule and Run Log
- [ ] Update the GitHub pre-release Calibnet rollout status with the announce tx and observed `afterEpoch`
- [ ] Create or update the public operational notice on [status.filecoin.cloud](https://status.filecoin.cloud/) for the Calibration network before execution. Identify the network and scheduled date/window, link the GitHub pre-release, and keep the maintenance window open through expected post-upgrade validation. Follow the [Operational Event Communications Runbook](https://github.com/FilOzone/filecoin-services/blob/main/docs/operational-events.md).

**Review during the delay**
- [ ] Run [Procedure A3](#a3-review-during-the-delay) or [Procedure B3](#b3-review-during-the-delay) in the Calibnet environment, by someone other than the announcing operator

**Execute**
- [ ] Wait for the observed Calibnet `afterEpoch`
- [ ] If this release has a ServiceProviderRegistry exception, generate its Calibnet execution with `NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS="$CALI_NEW_SPR_IMPL" NEW_VERSION=<version> CALLDATA_ONLY=true ./tools/service-provider-registry-execute-upgrade.sh`, execute it in the approved transaction order, then verify and record its implementation slot, `VERSION()`, initializer counter, preserved registry state, and cleared `nextUpgrade()`
- [ ] Run [Procedure A4](#a4-execute) or [Procedure B4](#b4-execute) in the Calibnet environment
- [ ] Record the Calibnet execute tx link in the Run Log
- [ ] For Path A, run [Procedure A5](#a5-list-the-proxy-in-the-ledger-again) in the Calibnet environment
- [ ] Run [Post-Upgrade Checks](#post-upgrade-checks) in the Calibnet environment, then `josuke accept` and commit `josuke.json`; record the commit in the Run Log
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
- [ ] Technical owner confirms Calibnet results are good before announcing Mainnet

### Phase 4: Mainnet Announce + Execute

**Announce**
- [ ] Technical owner records Mainnet go/no-go after reviewing Calibnet evidence, rollback status, dependency targets, and cross-repo status
- [ ] Confirm required cross-repo changes are merged/released or explicitly waived by the technical owner
- [ ] Create or update the public operational notice on [status.filecoin.cloud](https://status.filecoin.cloud/) for Mainnet before or alongside stakeholder notification. Identify the network and scheduled date/window, link the GitHub pre-release, and keep the maintenance window open through expected post-upgrade validation. Follow the [Operational Event Communications Runbook](https://github.com/FilOzone/filecoin-services/blob/main/docs/operational-events.md).
- [ ] Notify stakeholders before announcing Mainnet, including FilB so they can propagate the upgrade notice
- [ ] If this release has a ServiceProviderRegistry exception, generate its Mainnet announcement with `NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS="$MAIN_NEW_SPR_IMPL" UPGRADE_DELAY_EPOCHS=<delay> CALLDATA_ONLY=true ./tools/service-provider-registry-announce-upgrade.sh`, execute it through the owner Safe, then verify and record the exact implementation and observed `afterEpoch` returned by `nextUpgrade()` before any execute transaction.
- [ ] Set the Mainnet requested delay and update the schedule table
- [ ] Run [Procedure A2](#a2-announce) or [Procedure B2](#b2-announce) in the Mainnet environment
- [ ] Record the Mainnet announce tx and observed `afterEpoch` in the schedule and Run Log
- [ ] Update the GitHub pre-release Mainnet rollout status with the announce tx and observed `afterEpoch`

**Review during the delay**
- [ ] Run [Procedure A3](#a3-review-during-the-delay) or [Procedure B3](#b3-review-during-the-delay) in the Mainnet environment, by someone other than the announcing operator

**Execute**
- [ ] Wait for the observed Mainnet `afterEpoch`
- [ ] If this release has a ServiceProviderRegistry exception, generate its Mainnet execution with `NEW_SERVICE_PROVIDER_REGISTRY_IMPLEMENTATION_ADDRESS="$MAIN_NEW_SPR_IMPL" NEW_VERSION=<version> CALLDATA_ONLY=true ./tools/service-provider-registry-execute-upgrade.sh`, execute it in the approved transaction order, then verify and record its implementation slot, `VERSION()`, initializer counter, preserved registry state, and cleared `nextUpgrade()`
- [ ] Run [Procedure A4](#a4-execute) or [Procedure B4](#b4-execute) in the Mainnet environment
- [ ] Record the Mainnet execute tx link in the Run Log
- [ ] For Path A, run [Procedure A5](#a5-list-the-proxy-in-the-ledger-again) in the Mainnet environment
- [ ] Run [Post-Upgrade Checks](#post-upgrade-checks) in the Mainnet environment, then `josuke accept` and commit `josuke.json`; record the commit in the Run Log
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
- [ ] Confirm live Calibnet and Mainnet proxies point at the dispatcher, slot 19 is cleared, and `josuke accept` has been committed for both
- [ ] Run `josuke audit` against each network and record the result
- [ ] Resolve or complete every public operational notice after the corresponding rollout and post-upgrade validation succeed. Publish a final status update and record each notice link and final state in Release Tracking.
- [ ] Confirm cross-repo follow-ups are complete or tracked with owners
- [ ] Merge the `josuke.json` / `deployments.json` PR(s) to `main` after live-state verification, and record the PR link(s) in Release Tracking
- [ ] Verify `service_contracts/deployments.json` bytecode metadata matches the live deployed contracts

<details>
<summary>Deployment bytecode metadata verification commands</summary>

```bash
cd service_contracts

ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1" ./tools/verify-deployments.sh --chain 314159
ETH_RPC_URL="https://api.node.glif.io/rpc/v1" ./tools/verify-deployments.sh --chain 314
```

</details>

- [ ] Merge release-prep PR(s) if still open, keeping mutable rollout details on the GitHub Release page
- [ ] Promote the GitHub Release from pre-release to latest after the Mainnet upgrade, checks, and release-page status are complete
- [ ] Publish or update required ABIs: run `make -C service_contracts update-abi` for checked-in `service_contracts/abi` updates, compare against `josuke abi "$FWSS_PROXY_ADDRESS"` for the live routed ABI, and confirm the Synapse SDK workflow regenerated downstream ABI/types

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

## Procedures

Every procedure runs in one network environment from [Network Constants](#network-constants). Commands that only read chain state are safe to rerun at any time; rerun them whenever in doubt.

### Read the Pending Plan

Both paths store the pending plan in slot 19 of the proxy: the target address in the low 160 bits and `afterEpoch` in the high 96 bits. Read it from raw storage so the result does not depend on any view contract or route.

```bash
read_plan() {
  local word
  word=$(cast storage --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS" 19)
  PLANNED_TARGET=$(cast to-check-sum-address "0x${word:26:40}")
  PLANNED_AFTER_EPOCH=$(cast to-dec "0x${word:2:24}")
  echo "Pending target: $PLANNED_TARGET, afterEpoch: $PLANNED_AFTER_EPOCH"
}
read_plan
```

### Reproduce and Decode Safe Calldata

Before signing, every signer runs the generating command for the step, then decodes the result and compares it with the Safe UI:

```bash
export SAFE_DATA="0x..." # paste the data field shown in the Safe UI
[ "$SAFE_DATA" = "$CALLDATA" ] && echo "MATCH" || echo "MISMATCH: do not sign"
cast 4byte-calldata "$SAFE_DATA"
```

Also confirm in the Safe UI that the target is `$FWSS_PROXY_ADDRESS`, the value is `0`, and the operation is a call, not a delegatecall.

### Procedure A: One-Time Dispatcher Transition

Prerequisite: [Choose the Upgrade Path](#choose-the-upgrade-path) reports Path A for this network. Run `make erc8167` once to build the dispatcher artifact.

#### A1: Deploy

`josuke deploy` and `josuke verify` rehearse the migration against the code at the address `josuke.json` lists. The proxy still runs the monolith, so until the transition the ledger lists the proxy under the dispatcher instead. The transition scripts find the migration under either address.

```bash
forge script script/FWSSDispatcherDeploy.s.sol \
  --rpc-url "$ETH_RPC_URL" --keystore "$ETH_KEYSTORE" --password-file "$ETH_PASSWORD" --broadcast --skip-simulation
export DISPATCHER=$(jq -r ".\"$CHAIN\".FWSS_DISPATCHER_ADDRESS" deployments.json)
(source tools/josuke.sh; josuke_move_entry "$FWSS_PROXY_ADDRESS" "$DISPATCHER")

josuke deploy    # deploys changed modules and the migration, records them under `proposed`
josuke verify    # rebuilds every facet from its recorded commit and checks it against the chain

GIT_COMMIT=$(git rev-parse HEAD) forge script script/FWSSDispatcherTransitionDeploy.s.sol \
  --rpc-url "$ETH_RPC_URL" --keystore "$ETH_KEYSTORE" --password-file "$ETH_PASSWORD" \
  --broadcast --skip-simulation --verify   # verifies on Sourcify, forge's default verifier
```

Keep `--skip-simulation` on every `forge script --broadcast`. Without it forge sets each gas limit from its local EVM simulation, and FEVM gas is not EVM gas: Lotus rejects the two deploys (`'GasLimit' field cannot be less than the cost of storing a message on chain`), and a broadcast execute mines and reverts out of gas. With it, forge asks the node to estimate gas.

`FWSSDispatcherDeploy` deploys the dispatcher, or reuses the recorded one after checking its code hash, and records it in `deployments.json`. The transition deploy script reads the proxy and the dispatcher from `deployments.json`, the proposed migration from `josuke.json`, and the proxy's current implementation as the rollback target. It deploys `FWSSDispatcherTransition` and records it in `deployments.json`. See [`tools/README.md`](README.md#erc-8167-dispatcher-transition) for its full behavior and broadcast caveats.

- [ ] Check the deployed transition against source. The transition's getters cannot prove what its code does, and it runs in the proxy's storage, so its runtime bytecode must match the frozen tag's build:

```bash
./tools/verify-deployments.sh --chain "$CHAIN" --eth-call
```

- [ ] Record the transition as the announced target (`TRANSITION`) and the dispatcher in the Run Log
- [ ] Commit `josuke.json` and `deployments.json` to the Phase 2 PR

#### A2: Announce

Announce the transition through the monolith's `announceUpgradePlan`:

```bash
export DISPATCHER=$(jq -r ".\"$CHAIN\".FWSS_DISPATCHER_ADDRESS" deployments.json)
export TRANSITION=$(jq -r ".\"$CHAIN\".FWSS_DISPATCHER_TRANSITION_ADDRESS" deployments.json)
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$TRANSITION"
export UPGRADE_DELAY_EPOCHS=2880 # per Notice Guidance

CALLDATA_ONLY=true ./tools/warm-storage-announce-upgrade.sh
CALLDATA=$(cast calldata 'announceUpgradePlan(address,uint96)' "$TRANSITION" "$UPGRADE_DELAY_EPOCHS")
```

- [ ] Every signer [reproduces and decodes](#reproduce-and-decode-safe-calldata) `$CALLDATA` and [checks the transition's pins](#check-the-transitions-pins) before signing
- [ ] After the Safe transaction executes, [read the pending plan](#read-the-pending-plan) and confirm `PLANNED_TARGET` equals `$TRANSITION` and `PLANNED_AFTER_EPOCH` equals the announce block plus the requested delay (a delay of `0` becomes `1`).

#### A3: Review During the Delay

Someone other than the announcing operator runs these checks, preferably more than once before `afterEpoch`:

- [ ] [Read the pending plan](#read-the-pending-plan): the target is still `$TRANSITION` and nobody announced anything else
- [ ] [Check the transition's pins](#check-the-transitions-pins)
- [ ] From the frozen tag's build, `./tools/verify-deployments.sh --chain "$CHAIN" --eth-call` passes: the transition's code is the source's, so its getters report its real pins
- [ ] `josuke verify` passes against the committed `josuke.json`

The execute script repeats the plan and pin checks, but it checks readiness first, so it only reaches the pins after `afterEpoch`; A4 runs it. It does not run `verify-deployments.sh` or `josuke verify`.

#### Check the Transition's Pins

The transition is immutable, so its pins decide what the upgrade can do. Each value must match the expectation printed beside it:

```bash
PINNED_MIGRATION=$(cast call --rpc-url "$ETH_RPC_URL" "$TRANSITION" 'migration()(address)')
PINNED_DISPATCHER=$(cast call --rpc-url "$ETH_RPC_URL" "$TRANSITION" 'dispatcher()(address)')
PINNED_DISPATCHER_CODEHASH=$(grep -o '0x[0-9a-f]\{64\}' <<< "$(grep 'FWSS_DISPATCHER_CODE_HASH =' src/FWSSDispatcherTransition.sol)")
echo "previousImplementation: $(cast call --rpc-url "$ETH_RPC_URL" "$TRANSITION" 'previousImplementation()(address)') (expected $(cast implementation --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS"))"
echo "migration:              $PINNED_MIGRATION (expected $(source tools/josuke.sh; josuke_proposed_migration "$DISPATCHER"))"
echo "dispatcher:             $PINNED_DISPATCHER (expected $DISPATCHER)"
echo "migrationCodeHash:      $(cast call --rpc-url "$ETH_RPC_URL" "$TRANSITION" 'migrationCodeHash()(bytes32)') (expected $(cast keccak "$(cast code --rpc-url "$ETH_RPC_URL" "$PINNED_MIGRATION")"))"
echo "dispatcher code hash:   $(cast keccak "$(cast code --rpc-url "$ETH_RPC_URL" "$PINNED_DISPATCHER")") (expected $PINNED_DISPATCHER_CODEHASH)"
```

#### A4: Execute

```bash
export FWSS_DISPATCHER_TRANSITION_ADDRESS="$TRANSITION"
CALLDATA_ONLY=true forge script script/FWSSDispatcherTransitionExecute.s.sol --rpc-url "$ETH_RPC_URL"
```

With `CALLDATA_ONLY=true` the script checks that the plan is the transition and ready, that the transition pins the migration `josuke.json` proposes and that migration's unchanged code, the proxy's current implementation as the rollback target, and the pinned dispatcher. It then simulates the upgrade as the proxy owner and prints the Safe transaction: `upgradeToAndCall(transition, migrate(migration))` on the proxy. That one call points the proxy at the dispatcher and runs the migration; if any part reverts, nothing changes.

The upgrade call uses about 182M gas on FEVM. Leave the gas limit to the Safe's estimate; a signer must not cap it below that.

An EOA owner broadcasts the same call instead: replace `CALLDATA_ONLY=true` with `--keystore "$ETH_KEYSTORE" --password-file "$ETH_PASSWORD" --broadcast --skip-simulation`.

- [ ] Every signer [reproduces and decodes](#reproduce-and-decode-safe-calldata) the printed calldata, and decodes the inner `migrate(address)` call to confirm it names the pinned migration:

```bash
export CALLDATA="0x..." # the calldata the script printed
cast calldata-decode 'upgradeToAndCall(address,bytes)' "$CALLDATA" # first line must be $TRANSITION
INNER=$(cast calldata-decode 'upgradeToAndCall(address,bytes)' "$CALLDATA" | sed -n 2p)
cast calldata-decode 'migrate(address)' "$INNER"
```

- [ ] Never sign `upgradeToAndCall(transition, 0x)` with empty data. It installs the transition without migrating, and only `abortTransition()` or a separate `migrate(migration)` call on the proxy recovers from that state.

#### A5: List the Proxy in the Ledger Again

After the execute transaction, the proxy holds the routes the migration wrote, and `josuke accept` reads them from the address `josuke.json` lists:

```bash
(source tools/josuke.sh; josuke_move_entry "$DISPATCHER" "$FWSS_PROXY_ADDRESS")
```

- [ ] Commit the moved entry with the `josuke accept` result in the [Post-Upgrade Checks](#post-upgrade-checks)

### Procedure B: Josuke Migration

Prerequisite: [Choose the Upgrade Path](#choose-the-upgrade-path) reports Path B for this network. The legacy `warm-storage-announce-upgrade.sh` and `announceUpgradePlan` do not apply after the transition.

#### B1: Deploy

```bash
josuke deploy    # deploys changed modules and the migration, records them under `proposed`
josuke verify    # rebuilds every facet from its recorded commit and checks it, and that the migration installs exactly the proposed routes

export MIGRATION=$(source tools/josuke.sh; josuke_proposed_migration "$FWSS_PROXY_ADDRESS")
echo "Migration $MIGRATION"
```

- [ ] Record `MIGRATION` as the announced target in the Run Log
- [ ] Commit `josuke.json` to the Phase 2 PR

#### B2: Announce

```bash
export UPGRADE_DELAY_EPOCHS=2880 # per Notice Guidance
CALLDATA=$(cast calldata 'announceMigration(address,uint96)' "$MIGRATION" "$UPGRADE_DELAY_EPOCHS")
echo "Target: $FWSS_PROXY_ADDRESS"
echo "Data:   $CALLDATA"
```

- [ ] Every signer [reproduces and decodes](#reproduce-and-decode-safe-calldata) `$CALLDATA` and confirms `josuke verify` passes before signing
- [ ] After the Safe transaction executes, [read the pending plan](#read-the-pending-plan) and confirm `PLANNED_TARGET` equals `$MIGRATION` and `PLANNED_AFTER_EPOCH` equals the announce block plus the requested delay (a delay of `0` becomes `1`)

#### B3: Review During the Delay

`migrate` on the dispatcher checks only the migration's address, so `josuke verify` is what confirms the code that will run. Someone other than the announcing operator runs them, preferably more than once before `afterEpoch`:

- [ ] [Read the pending plan](#read-the-pending-plan): the target is still `$MIGRATION` and nobody announced anything else
- [ ] `josuke verify` passes against the committed `josuke.json`
- [ ] The proxy still points at the dispatcher (rerun [Choose the Upgrade Path](#choose-the-upgrade-path))

#### B4: Execute

```bash
read_plan
[ "$PLANNED_TARGET" = "$(cast to-check-sum-address "$MIGRATION")" ] || echo "STOP: the pending plan is not the reviewed migration"
josuke verify || echo "STOP: josuke verify failed"

CALLDATA=$(cast calldata 'migrate(address)' "$MIGRATION")
OWNER=$(cast call --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS" 'owner()(address)')
cast call --rpc-url "$ETH_RPC_URL" --from "$OWNER" "$FWSS_PROXY_ADDRESS" "$CALLDATA" && echo "Simulation succeeded"
echo "Target: $FWSS_PROXY_ADDRESS"
echo "Data:   $CALLDATA"
```

- [ ] Every signer reruns the two `STOP` checks and the simulation, and [reproduces and decodes](#reproduce-and-decode-safe-calldata) `$CALLDATA` before signing

### Post-Upgrade Checks

Run after either path's execute transaction, then run `josuke accept`, which checks on chain that every proposed selector routes to its facet and every dropped selector is cleared before it promotes `proposed` to `current`.

```bash
export EXPECTED_FWSS_VERSION="{{FWSS_VERSION}}"
export EXPECTED_OWNER="0x6386622B4915B027900d65560b0ab84F8a1ff2AA"

IMPL=$(cast implementation --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS")
IMPL_CODEHASH=$(cast keccak "$(cast code --rpc-url "$ETH_RPC_URL" "$IMPL")")
PINNED_DISPATCHER_CODEHASH=$(grep -o '0x[0-9a-f]\{64\}' <<< "$(grep 'FWSS_DISPATCHER_CODE_HASH =' src/FWSSDispatcherTransition.sol)")
echo "Implementation: $IMPL, code hash $IMPL_CODEHASH (expected $PINNED_DISPATCHER_CODEHASH)"

read_plan # expect the zero address and 0

echo "owner(): $(cast call --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS" 'owner()(address)') (expected $EXPECTED_OWNER)"
echo "VERSION(): $(cast call --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS" 'VERSION()(string)') (expected $EXPECTED_FWSS_VERSION)"

for sig in 'announceMigration(address,uint96)' 'migrate(address)' 'implementation(bytes4)' 'selectors()'; do
  echo "$sig -> $(cast call --rpc-url "$ETH_RPC_URL" "$FWSS_PROXY_ADDRESS" 'implementation(bytes4)(address)' "$(cast sig "$sig")")"
done

josuke accept
git add josuke.json && git commit -m "chore(josuke): accept the $CHAIN migration"
```

Every upgrade route must point at a deployed module; a zero address means FWSS can no longer be upgraded. Stop and escalate if any check differs from its expected value.

---

### Resources
- [Changelog]({{CHANGELOG_LINK}})
- [ERC-8167 transition scripts](https://github.com/FilOzone/filecoin-services/blob/main/service_contracts/tools/README.md#erc-8167-dispatcher-transition)
- [Operational Event Communications Runbook](https://github.com/FilOzone/filecoin-services/blob/main/docs/operational-events.md)
- [Upgrade Checklist Source]({{CHECKLIST_LINK}})
<!-- ISSUE_TEMPLATE_END -->

## Notes From v1.3.0

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
