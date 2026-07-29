# Syncing a PDPVerifier Release

PDPVerifier is upgraded in [FilOzone/pdp](https://github.com/FilOzone/pdp), independent of the FWSS upgrade flow ([UPGRADE-CHECKLIST.md](./UPGRADE-CHECKLIST.md)). Sync steps after a new `pdp` release is deployed:

1. Bump the submodule:

   ```bash
   git -C service_contracts/lib/pdp fetch --tags
   git -C service_contracts/lib/pdp checkout <tag>
   git add service_contracts/lib/pdp
   ```

2. Regenerate the ABI: `make -C service_contracts update-abi` (the `check-abi` CI job will fail otherwise).

3. Update `PDP_VERIFIER_IMPLEMENTATION_ADDRESS` for both networks (`"314"`, `"314159"`) in [`deployments.json`](../deployments.json), pulled from the release page. The proxy address does not change.

4. Verify EIP-55 checksum (manual edits skip the `forge create` path that produces checksummed output by default; non-EIP-55 case is rejected by viem `isAddress` and similar):

   ```bash
   bash service_contracts/tools/check_deployments_checksums.sh service_contracts/deployments.json
   # Or per-address: cast to-check-sum-address <address> (output should equal input)
   ```

   The same script runs in the `check-deployments` CI job.

5. Add a [`CHANGELOG.md`](../../CHANGELOG.md) entry following the existing PDPVerifier sync convention (proxy + impl with explorer links + source release link).

6. Open the PR (e.g. `chore: sync PDPVerifier vX.Y.Z source, ABI, and deployments`).
