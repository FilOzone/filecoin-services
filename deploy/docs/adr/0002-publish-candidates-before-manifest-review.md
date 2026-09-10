---
status: accepted
---

# Publish candidates before manifest review

Candidate deployment is separated from live-state reconciliation. An author first generates and reviews a deployment plan without key access, then may use any funded account to deploy candidates locally before opening the manifest PR; deployment is permissionless publication, while only the later manifest merge authorizes governed contracts to reference those candidates.

The manifest records each candidate address together with reproducible deployment provenance, including source commit, artifact identity, initcode hash, structured constructor arguments, and library bindings. CI independently rebuilds from the frozen source commit and verifies the on-chain candidate and recorded metadata. Rejected or partially completed attempts may leave unused candidates, and redeployment is acceptable; tooling may reuse a locally recorded candidate when exact verification is simple but does not reconstruct deployment history.

## Consequences

Candidate addresses are concrete during review without requiring deterministic deployment. The deployment command must build the selected Source Commit rather than the author's working tree. Invalid normal-candidate identity or provenance blocks merge; the explicitly marked Unreproducible Adoption escape hatch is distinct. Verification evidence belongs in CI rather than committed manifest state.
