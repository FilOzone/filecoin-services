# FWSS Contract Upgrade Process

The self-contained FWSS upgrade runbook now lives in [`UPGRADE-CHECKLIST.md`](./UPGRADE-CHECKLIST.md).

Use the [Create Release Issue](https://github.com/FilOzone/filecoin-services/actions/workflows/create-upgrade-announcement-issue.yml) workflow to render that checklist from the selected release branch. The generated issue is the rollout source of truth and includes the schedule, run log, network constants, Safe multisig instructions, command snippets, deployment verification, announce/execute steps, post-upgrade checks, and release wrap-up.

This file remains only as a compatibility pointer for older links. For normal releases, do not use it as a separate runbook. If a rollout needs work outside the main `FilecoinWarmStorageService` implementation upgrade path, add a clearly labeled exception section directly to the release issue before starting that work.
