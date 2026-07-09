# Operational Event Communications Runbook

Use this runbook when Filecoin Cloud users need a public operational update for
an incident, service degradation, scheduled maintenance, or security-sensitive
event.

Use [FOC Operational Excellence](https://app.notion.com/p/filecoindev/FOC-Operational-Excellence-2b7dc41950c1802aa432fff8ecb801cc#388dc41950c18004b0a7ee87400db860) (internal; requires Notion access)
for Better Stack access details and current internal operating notes.

## Communication Model

- Use [status.filecoin.cloud](https://status.filecoin.cloud/) for the short,
  user-facing status notice.
- For an ongoing incident or degradation, create a GitHub issue in this repo and
  link to it from the Better Stack notice.
- For a scheduled FWSS or contract upgrade, link the Better Stack maintenance
  notice to the release issue or GitHub Release instead of creating a separate
  incident issue.
- Use the [foc-problems issue form](https://github.com/FilOzone/foc-problems/issues/new/choose)
  for inbound user reports.

Better Stack subscriptions are useful, but confirmation emails have landed in
spam in smoke tests. Treat subscriber email as helpful, not as the only
communication path.

## When To Publish

Publish a notice when an event affects, or is likely to affect, Filecoin Cloud
users, integrators, or storage providers.

Common triggers:

- Mainnet contract upgrades or planned maintenance.
- Active or suspected service degradation.
- Issues with major dependencies (e.g., RPC providers, IPNI) that affect FOC quality of service.
- Contract or security events where users need clear guidance.

If impact is uncertain, publish a short notice that says impact is being
assessed and link to the tracking issue.

## Component Mapping

| Event type | Better Stack component | Typical state |
|---|---|---|
| Scheduled FWSS or contract rollout | `Contract upgrades / maintenance` | Maintenance |
| Contract incident or security issue | `Contract upgrades / maintenance` | Degraded or downtime |
| Filecoin RPC, chain dependency, or upstream issue | `Filecoin RPC / dependencies` | Degraded or downtime |
| FilBeam delivery issue | `FilBeam CDN` | Degraded or downtime |
| Indexing or IPNI issue | `Indexing / IPNI` | Degraded or downtime |
| Storage provider network issue | `Provider network health` | Degraded or downtime |

## Ongoing Incident Flow

1. Name the incident owner.
2. Create a public issue in `FilOzone/filecoin-services` unless the event is
   security-sensitive and the owner decides details must stay private initially.
3. Add the current facts to the issue:
   - impact;
   - affected users or workflows;
   - start time in UTC, if known;
   - current mitigation or next action;
   - next expected update.
4. Create or update the Better Stack notice:
   - select the affected component(s);
   - set `degraded` or `downtime`;
   - keep the message short;
   - link to the GitHub issue for details and timeline.
5. Notify subscribers for Mainnet impact, required user action, broad
   dependency impact, or security-relevant events.
6. Post ongoing updates in the GitHub issue. Keep Better Stack focused on
   public status changes, impact changes, and resolution.
7. Resolve the Better Stack notice when user impact has ended, then close or
   follow up from the GitHub issue.

Suggested issue title:

```text
Operational event: <short user-facing summary> (<YYYY-MM-DD UTC>)
```

Suggested issue body:

```markdown
## Impact
TBD

## Current status
TBD

## Timeline
- <UTC time>: Event opened.

## User action
No user action is required at this time.

## Public status notice
TODO: add relevant link to status.filecoin.cloud
```

## Scheduled Upgrade Flow

For scheduled FWSS or contract upgrades:

1. Use the release issue and GitHub Release as the durable rollout record.
2. Create a Better Stack maintenance notice on `Contract upgrades / maintenance`
   before or alongside Mainnet stakeholder notification.
3. Link the notice to the release issue or GitHub Release.
4. Update the notice after announce and execute transactions are recorded.
5. Resolve the notice after Mainnet execution and post-upgrade checks complete.

## Security Note

For suspected contract or security issues, do not publish exploit details,
credentials, private reports, or unreviewed analysis. If public tracking is not
safe yet, keep the GitHub issue private/internal until the owner approves a
public issue, advisory, or limited status-page wording.

## Closeout

- [ ] Better Stack notice resolved or updated to final state.
- [ ] GitHub issue, release issue, or GitHub Release contains the final public
      status link.
- [ ] User reports through the [foc-problems issue form](https://github.com/FilOzone/foc-problems/issues/new/choose)
      have been checked.
- [ ] Follow-up work or lessons learned captured.
