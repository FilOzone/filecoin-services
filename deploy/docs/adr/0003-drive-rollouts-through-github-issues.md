---
status: accepted
---

# Drive rollouts through GitHub issues

Merging a Network Manifest automatically creates a Rollout Issue. Any repository writer may comment `/refresh` to trigger trusted default-branch automation that observes finalized chain state, verifies progress, updates the remaining plan, and generates every independently executable Safe Action as linked Safe Transaction Builder artifacts; operators review and sign those actions in their respective Safes.

Actions progress independently by component rather than through one global release stage. Explicit action-level dependencies prevent generation until their prerequisite component state is reached, while independent PDP and FWSS actions may proceed in parallel or be batched only when they share a Safe, require no intermediate verification, and are safe to execute atomically. External readiness is deliberately implicit: humans express it by not submitting an available Safe Action, not by adding machine-tracked operational gates.

## Consequences

A refresh normally discovers executed actions from chain state and events without requiring an operator-supplied transaction hash; a hash may remain a fallback when discovery is ambiguous. The issue retains enough target, call, network, Safe, manifest-revision, and verification information to reconstruct an expired artifact. It closes automatically when no divergence, pending action, or failed automated postcondition remains.
