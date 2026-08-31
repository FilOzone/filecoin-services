---
status: accepted
---

# A merged network manifest authorizes reconciliation

Each network has one primary manifest declaring what that network is or will be. A human selects a frozen source commit, local tooling updates that same manifest, and a second human reviews the manifest PR; merging it authorizes tooling to reconcile observed chain state to the merged declaration.

The reconciliation plan is derived from the proposed manifest and fresh chain observations and is published as a PR comment rather than committed. The pre-PR manifest remains useful as Git history but is not an operational starting-state assumption. This avoids maintaining a second rollout-intent file or a Terraform-like cache of chain state.

## Consequences

The merged manifest may intentionally differ from the chain while a rollout is active. Completion means the observed network has reached the manifest state and automated postconditions pass, not merely that transactions succeeded. Explicit per-component delays and action dependencies live alongside the component declarations without a redundant `desired` wrapper.
