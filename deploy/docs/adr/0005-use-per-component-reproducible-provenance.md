---
status: accepted
---

# Use per-component reproducible provenance

Every managed deployable component records its own Source Commit and reproducible deployment identity. Update tooling may select all changed components from one commit or a focused component set, avoiding the anti-pattern of temporarily pinning every unrelated component when one library or contract must come from a different commit.

Source Commits must be reachable from protected mainline history. Authored inputs include component selection, Source Commit, structured constructor arguments, explicit library bindings, delay, dependencies, and Pins; tooling produces candidate addresses and bytecode identities. Both the reviewer and CI reproduce compiler settings, artifact bytecode, bindings, constructor arguments, complete initcode identity, and expected runtime bytecode, while CI also verifies the recorded candidate through the configured network RPC.

## Consequences

A Pin is persistent protection from bulk updates, not a release-scope selector. Pin expiry warns locally and fails CI until reviewed. Normal candidates remain reproducible; Adoption may explicitly mark observed state Unreproducible when humans need an escape hatch. For now, CI uses tooling from the PR branch, so review—not an enforced separation of tooling and manifest changes—guards verifier changes.
