---
status: accepted
---

# Replan from chain on every manifest change

A newly merged Network Manifest replaces the active target even when another rollout is incomplete. Automation closes the previous Rollout Issue with a simple supersession notice, opens a new issue, observes the chain, and derives a fresh path to the new manifest without interpreting previous actions as complete, pending, or abandoned.

This deliberately avoids rollout-history migration, partial-deployment recovery, and stale Safe Action inventories unless they later prove cheap to add. Safe Action artifacts identify their manifest revision and closed issues warn operators not to use their actions. If an old action is nevertheless executed, the next observation treats its effects as ordinary chain state and plans from there.

Unexpected chain state is never silently copied into the manifest. When humans intend to retain it, an explicit component-scoped Adoption updates the manifest through the normal two-human PR review. Pins similarly become manifest state with justification and expiry rather than temporary rollout waivers.
