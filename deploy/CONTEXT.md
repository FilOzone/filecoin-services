# Contract Rollout

This context describes how a network declaration is reviewed and reconciled with contracts observed on-chain.

## Language

**Network Manifest**:
The authoritative declaration of what a single network is or will be. It contains contract identities, addresses, deployment provenance, upgrade parameters, dependencies, and deliberate pins.
_Avoid_: Desired-state file, rollout plan, deployment cache

**Source Commit**:
The frozen repository revision from which one managed component's deployment identity is reproduced.
_Avoid_: Working tree, release branch

**Observed State**:
Contract state read from a specific network at a finalized observation point. It is the factual input to reconciliation, not a cached copy in the repository.
_Avoid_: Current manifest, Terraform state

**Divergence**:
A difference between Observed State and the Network Manifest that may require one or more actions to reconcile.
_Avoid_: Drift from the previous manifest

**Reconciliation Plan**:
The derived, uncommitted set of actions that can move Observed State toward the Network Manifest. The plan is empty when the declared state has been reached.
_Avoid_: Committed rollout plan, release checklist

**Candidate**:
A deployed contract that the Network Manifest may cause canonical contracts to reference. Its existence alone does not change governed network state.
_Avoid_: Safe deployment, active implementation

**Rollout**:
The progressive reconciliation of one network after a Network Manifest merge authorizes its declared state.
_Avoid_: Deployment script run, global release stage

**State Reached**:
The condition where a component's Observed State agrees with its declaration in the Network Manifest and its automated postconditions pass.
_Avoid_: Transaction succeeded, rollout attempted

**Safe Action**:
One currently executable owner-governed transaction presented for human review and signing.
_Avoid_: Upgrade approval, automatic execution

**Action Dependency**:
A persistent requirement that blocks one generated action until another component has reached a named state. Operational readiness that humans express by withholding a Safe Action is not an Action Dependency.
_Avoid_: Operational gate, rollout wave

**Pin**:
A justified, expiring declaration that protects a managed component from bulk source updates while continuing to verify it.
_Avoid_: Per-rollout waiver, silent exclusion

**Adoption**:
An explicit manifest change that accepts Observed State as the declared network state, including state that normal provenance checks cannot reproduce.
_Avoid_: Automatic import, drift acceptance

**Unreproducible**:
An explicit property of adopted state whose deployment identity cannot be reproduced from a known Source Commit.
_Avoid_: Verified exception, assumed source

**Supersession**:
Replacement of an active rollout target by a newly merged Network Manifest. Reconciliation restarts from Observed State without interpreting or migrating the prior rollout's progress.
_Avoid_: Rollback, rollout resume

**Rollout Issue**:
The operational record for one authorized Network Manifest, containing observations, available Safe Actions, verification results, and remaining divergence.
_Avoid_: Source of state, manual checklist
