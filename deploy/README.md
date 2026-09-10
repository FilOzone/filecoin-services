# Declarative Contract Rollouts

## Goal

Make contract deployment and upgrade review simpler and safer by declaring what one network is or will be, deriving the current state from chain, and guiding humans through the verified actions needed to make them agree.

The system automates comparison, reproduction, simulation, and postcondition checks. Humans still choose the declared state, merge it, and authorize privileged transactions.

## Core model

```text
Network Manifest + Observed State = Reconciliation Plan
```

- The **Network Manifest** is the repository's authoritative declaration for one network.
- **Observed State** is read from that network through a configured RPC.
- The **Reconciliation Plan** is derived output, not committed state.
- A component has reached state when its declared observable fields and automated invariants match.
- The plan disappears as components reach state.

The previous manifest is not an operational starting point. It provides Git history, while reconciliation always compares fresh chain observations with the proposed or merged manifest.

## Manifest

The primary network manifest contains the state declaration and the provenance needed to reproduce it. There is no separate rollout-intent file and no redundant `desired` wrapper.

Each managed component may declare:

- address and artifact identity;
- its own frozen Source Commit, reachable from protected mainline history;
- initcode and runtime identities;
- structured constructor arguments and library bindings;
- explicit upgrade delay;
- persistent action-level dependencies;
- a justified, expiring Pin;
- an explicit unreproducible marker when state was adopted through the escape hatch.

Source provenance is per component. A normal update can select all components changed by a commit, while a focused update can select one component without temporarily pinning everything else.

Deleting a component means that the system stops managing and verifying it. A Pin is different: the component remains managed and verified, but bulk updates retain its declaration. Local tooling warns about an expired Pin; CI rejects it until humans remove or renew it.

## Intent PR

A release author:

1. selects a frozen Source Commit and component scope;
2. edits explicit per-component delays, dependencies, constructor inputs, or Pins when needed;
3. runs a keyless local plan and reviews what would be deployed;
4. uses any funded account to deploy candidates;
5. records each successfully verified candidate in the manifest;
6. opens a PR containing the manifest change.

Candidate deployment is permissionless publication. It does not authorize canonical contracts to reference the candidate. Partial candidate deployment may be resumed when reuse is trivial; redeploying is acceptable.

The PR has three review surfaces:

1. **Manifest diff** — authoritative state and deployment provenance.
2. **Generated comment** — observed chain state to proposed manifest, predicted reconciliation actions, and GitHub links between relevant source commits.
3. **CI checks** — independent reconstruction and candidate verification.

The reviewer is expected to run the same generation tooling locally and reproduce the deployment identity from each selected Source Commit. CI performs the same reconstruction using the PR branch tooling and one configured RPC.

For a normal candidate, CI verifies compiler and build settings, artifact bytecode, library bindings, structured constructor arguments, complete initcode identity, expected runtime bytecode, and the code at the recorded candidate address. A mismatch is not hidden by changing a hash; inputs must reproduce the candidate.

An explicit Adoption is the escape hatch for accepting observed state. It may mark a component unreproducible, making that loss of assurance visible instead of pretending normal verification passed.

The Reconciliation Plan is advisory PR output because chain state may change. Candidate and manifest consistency checks are blocking. The presence of the manifest on the target main branch is the authorization to reconcile it.

## Rollout

A manifest merge automatically creates a Rollout Issue and derives a fresh plan from chain. The issue is the operational interface, not a source of state.

Any repository writer may comment `/refresh`. Trusted default-branch automation then:

1. observes finalized chain state;
2. verifies progress and postconditions;
3. simulates currently eligible privileged actions;
4. updates remaining divergence;
5. publishes Safe Transaction Builder JSON artifacts for every independently eligible Safe Action.

Actions progress independently by component and Safe. There is no batching. An action-level dependency blocks only the named action; for example, FWSS execution may wait until PDP has reached its manifest state while their earlier actions proceed independently.

Before publishing a Safe Action, automation verifies its authority, target, value, arguments, current preconditions, and dependencies. It simulates the exact action from the expected Safe on an Anvil fork of observed chain state and checks the resulting state and component invariants. A failed simulation does not produce an artifact.

Humans import, review, and sign the JSON in Safe. External readiness such as a Curio rollout is deliberately implicit: humans express it by not submitting an available Safe Action. It is not part of manifest equality or automated rollout state.

After execution, an operator comments `/refresh`; a transaction hash is normally unnecessary. Automation discovers progress from chain state and events, records a transaction when it can do so unambiguously, and verifies results. A successful transaction with failed postconditions stalls that dependency path but does not prevent independent components from progressing.

Only the final network state is declared in the manifest. Pending announcements, waiting periods, and other transitional states exist in the derived plan. An existing matching announcement is naturally detected and reused; the declared delay matters when a new announcement must be made. A conflicting announcement results in a new announcement for the manifest implementation.

The Rollout Issue closes automatically when every managed component has reached state and automated postconditions pass.

## Changes during rollout

A newly merged manifest becomes the current target. Automation may close the previous Rollout Issue with a simple supersession notice and open a new one, then plans directly from fresh Observed State. It does not migrate old action status or reconstruct abandoned rollout history.

Unexpected chain state is not copied into the manifest automatically. Humans may keep reconciling toward the manifest or use an explicit Adoption to change the declaration. Rollback is likewise an ordinary manifest update; simulation and the normal checks determine whether its actions are currently viable.

## Deliberate boundaries

- Initial proxy deployment remains manual and is outside this upgrade flow.
- Each manifest and rollout concerns one network; cross-network equality is a human review concern for now.
- The system never holds deployment or Safe signing keys.
- Safe proposals are not submitted automatically; tooling publishes Transaction Builder JSON.
- Operational readiness is not modeled as a machine gate.
- Reconciliation Plans and observed-state caches are not committed.
- The system does not continuously execute actions; humans remain in the authorization loop.
