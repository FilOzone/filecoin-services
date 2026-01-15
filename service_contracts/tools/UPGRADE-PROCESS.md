# FWSS Contract Upgrade Process

This document describes the upgrade process for FilecoinWarmStorageService (FWSS) and related contracts.

## Contract Upgradeability Overview

| Contract | Proxy Pattern | Upgrade Method |
|----------|---------------|----------------|
| FilecoinWarmStorageService | UUPS Proxy (two-step) | `announce-planned-upgrade.sh` + `upgrade.sh` |
| ServiceProviderRegistry | UUPS Proxy (two-step) | `announce-planned-upgrade-registry.sh` + `upgrade-registry.sh` |
| PDPVerifier | ERC1967 Proxy | Via [pdp repo](https://github.com/FilOzone/pdp) scripts |
| FilecoinPayV1 | None (immutable) | Not expected to be redeployed |
| SessionKeyRegistry | None (immutable) | Not expected to be redeployed |
| FilecoinWarmStorageServiceStateView | None (helper) | Redeployable via `deploy-warm-storage-view.sh` |

## Immutable Dependencies

FWSS stores several dependencies as `immutable` constructor parameters:

```solidity
IPDPVerifier public immutable pdpVerifier;
FilecoinPayV1 public immutable paymentsContract;
IERC20Metadata public immutable usdfcTokenAddress;
address public immutable filBeamBeneficiaryAddress;
ServiceProviderRegistry public immutable serviceProviderRegistry;
SessionKeyRegistry public immutable sessionKeyRegistry;
```

### Operational Expectations

These immutable contracts are **not expected to be redeployed** under normal operations. Redeploying any of these would require upgrading FWSS to a new implementation with updated constructor arguments, which could break existing functionality and integrations.

**If redeployment becomes necessary:**
- It will be announced **well ahead of time** to all stakeholders
- A migration plan will be communicated
- The change will go through the standard two-step upgrade process with an extended notice period

## Two-Step Upgrade Process

Both FWSS and ServiceProviderRegistry use a two-step upgrade mechanism:

1. **Announce** - Call `announcePlannedUpgrade()` with the new implementation address and `AFTER_EPOCH`
2. **Execute** - After `AFTER_EPOCH` has passed, call `upgradeToAndCall()` to complete the upgrade

This gives stakeholders time to review changes before execution.

## Choosing AFTER_EPOCH

When announcing an upgrade, choose `AFTER_EPOCH` to give stakeholders adequate notice:

| Upgrade Type | Minimum Notice | Recommended |
|--------------|----------------|-------------|
| Routine (bug fixes, minor features) | ~24 hours (~2,880 epochs) | 1-2 days |
| Breaking changes | ~1 week (~20,160 epochs) | 1-2 weeks |
| Immutable dependency changes | ~2 weeks (~40,320 epochs) | 2-4 weeks |

**To calculate:**

```bash
# Get current epoch
CURRENT_EPOCH=$(cast block-number --rpc-url $ETH_RPC_URL)

# Add desired notice period (e.g., 2 days = ~5760 epochs)
AFTER_EPOCH=$((CURRENT_EPOCH + 5760))

echo "Current: $CURRENT_EPOCH, Upgrade after: $AFTER_EPOCH"
```

**Considerations:**
- Allow time for stakeholder review
- Avoid weekends/holidays for mainnet upgrades
- Calibnet can use shorter notice periods for testing

## Release Workflow

### Before the Upgrade

1. **Prepare changelog entry** in `CHANGELOG.md`:
   - Document all changes since last release
   - Mark breaking changes clearly
   - Include migration notes if needed

2. **Create PR** with changelog updates

3. **Deploy new implementation** contract:
   - Run the deployment script (see [FWSS Upgrade Workflow](#fwss-upgrade-workflow))
   - `deployments.json` is automatically updated by the script
   - **Document the new implementation address in PR comments** for traceability
   - Commit the updated `deployments.json` to the PR

4. **Run upgrade announcement** on-chain via `announce-planned-upgrade.sh`

5. **Create tracking issue** using the [Create Upgrade Announcement](https://github.com/FilOzone/filecoin-services/actions/workflows/upgrade-announcement.yml) GitHub Action

### After Successful Upgrade

1. **Verify** the upgrade on block explorer (Blockscout)

2. **Confirm** `deployments.json` was updated (automatic via script)

3. **Merge** the changelog PR

4. **Tag release** in GitHub (post-upgrade):
   ```bash
   git tag v1.X.0
   git push origin v1.X.0
   ```

5. **Create GitHub Release** pointing to:
   - Changelog entry
   - `deployments.json` for current addresses

## Stakeholder Communication

<!-- TODO: Update these placeholders with actual channels and procedures -->

> **Tip**: Use the [Create Upgrade Announcement](../../.github/workflows/upgrade-announcement.yml) GitHub Action to automatically generate an announcement issue. Go to **Actions → Create Upgrade Announcement → Run workflow**.

### Before Announcing an Upgrade

Before running `announce-planned-upgrade.sh`, notify stakeholders through:

- [ ] **Slack**: Post in `#<!-- channel-name -->` with upgrade details
- [ ] **GitHub**: Create a tracking issue or discussion for the upgrade
- [ ] **Documentation**: Update changelog with upcoming changes

### Upgrade Announcement Template

> **Automated**: The [Create Upgrade Announcement](https://github.com/FilOzone/filecoin-services/actions/workflows/upgrade-announcement.yml) GitHub Action generates this template as an issue automatically.

When communicating an upgrade, include:

```
## FWSS Contract Upgrade Announcement

**Network**: [Mainnet/Calibnet]
**Upgrade Type**: [Routine/Breaking Change]
**Scheduled Execution**: After epoch [AFTER_EPOCH] (~[estimated date/time])

### Changes
- [Summary of changes]
- [Link to PR/release notes]

### New Implementation Address
`0x...`

### Action Required
[None / Describe any required actions for integrators]

### Resources
- Release: [link] (if applicable)
- Changelog: [link]
```

### After Upgrade Execution

- [ ] **Verify**: Confirm upgrade success on block explorer
- [ ] **Notify**: Post confirmation in communication channels
- [ ] **Update**: Update `deployments.json` (automatic) and any external documentation
- [ ] **Release**: Tag a new release in GitHub with updated addresses

### Breaking Changes Communication

For upgrades involving immutable dependency changes or breaking API changes:

- Provide **extended notice period** (minimum recommended: <!-- X days/weeks -->)
- Create detailed **migration guide** for affected integrators
- Offer **support channel** for questions during migration
- Consider **phased rollout**: Calibnet first, then Mainnet after validation

## FWSS Upgrade Workflow

### Step 1: Deploy New Implementation

Deploy the new implementation contract with the same immutable dependencies:

```bash
export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"

# Deploy new implementation (uses existing immutable addresses from deployments.json)
forge create --password "$PASSWORD" --broadcast \
  --libraries "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS" \
  src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService \
  --constructor-args \
    "$PDP_VERIFIER_ADDRESS" \
    "$PAYMENTS_CONTRACT_ADDRESS" \
    "$USDFC_TOKEN_ADDRESS" \
    "$FILBEAM_BENEFICIARY_ADDRESS" \
    "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    "$SESSION_KEY_REGISTRY_ADDRESS"
```

### Step 2: Optionally Deploy New StateView

If the StateView contract needs updating:

```bash
source ./deploy-warm-storage-view.sh
```

### Step 3: Announce the Upgrade

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export WARM_STORAGE_PROXY_ADDRESS="0x..."
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."  # From step 1
export AFTER_EPOCH="123456"  # Block number after which upgrade can execute

./announce-planned-upgrade.sh
```

### Step 4: Wait for AFTER_EPOCH

The upgrade cannot be executed until the current block number exceeds `AFTER_EPOCH`.

### Step 5: Execute the Upgrade

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export WARM_STORAGE_PROXY_ADDRESS="0x..."
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="0x..."
# Optional: NEW_WARM_STORAGE_VIEW_ADDRESS if deploying new view contract

./upgrade.sh
```

### Step 6: Verify

The script automatically:
- Verifies the upgrade by checking the implementation storage slot
- Updates `deployments.json` with the new implementation address

## ServiceProviderRegistry Upgrade Workflow

Similar to FWSS, but uses dedicated scripts:

### Announce

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export REGISTRY_PROXY_ADDRESS="0x..."
export NEW_REGISTRY_IMPLEMENTATION_ADDRESS="0x..."
export AFTER_EPOCH="123456"

./announce-planned-upgrade-registry.sh
```

### Execute

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export ETH_KEYSTORE="/path/to/keystore.json"
export PASSWORD="your-password"
export SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS="0x..."
export NEW_REGISTRY_IMPLEMENTATION_ADDRESS="0x..."
export NEW_VERSION="v1.1.0"  # Optional version string for migrate()

./upgrade-registry.sh
```

## StateView Contract Updates

The `FilecoinWarmStorageServiceStateView` is a helper contract that can be redeployed independently without going through the two-step announcement process:

1. Deploy new StateView:
   ```bash
   source ./deploy-warm-storage-view.sh
   ```

2. Set the new view address on FWSS proxy:
   ```bash
   source ./set-warm-storage-view.sh
   ```

This is an owner-only operation and does not require an upgrade announcement.

## Environment Variables Reference

### Common Variables

| Variable | Description |
|----------|-------------|
| `ETH_RPC_URL` | RPC endpoint (e.g., `https://api.calibration.node.glif.io/rpc/v1`) |
| `ETH_KEYSTORE` | Path to Ethereum keystore file |
| `PASSWORD` | Keystore password |
| `CHAIN` | Chain ID (auto-detected if not set) |

### FWSS Upgrade Variables

| Variable | Description |
|----------|-------------|
| `WARM_STORAGE_PROXY_ADDRESS` | Address of FWSS proxy contract |
| `NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS` | Address of new implementation |
| `AFTER_EPOCH` | Block number after which upgrade can execute |
| `NEW_WARM_STORAGE_VIEW_ADDRESS` | (Optional) New StateView address |

### Registry Upgrade Variables

| Variable | Description |
|----------|-------------|
| `SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS` | Address of registry proxy |
| `REGISTRY_PROXY_ADDRESS` | Same as above (used by announce script) |
| `NEW_REGISTRY_IMPLEMENTATION_ADDRESS` | Address of new implementation |
| `AFTER_EPOCH` | Block number after which upgrade can execute |
| `NEW_VERSION` | (Optional) Version string for migrate() |

## Verification and Testing

### Always Test on Calibnet First

Before upgrading on mainnet, always test the upgrade on Calibnet:

```bash
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
# ... run upgrade scripts
```

### Storage Layout Verification

Before deploying a new implementation, verify storage layout compatibility:

```bash
forge inspect src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService storageLayout
```

Compare with the previous version to ensure no storage slot collisions.

### Upgrade Verification

The upgrade scripts automatically verify success by checking the ERC1967 implementation slot:

```bash
cast rpc eth_getStorageAt "$PROXY_ADDRESS" \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc latest
```

### Run Upgrade Tests

```bash
forge test --match-contract FilecoinWarmStorageServiceUpgradeTest
```

## Deployment Address Management

All deployment scripts automatically load and update addresses in `deployments.json`. See the main [README.md](./README.md) for details on:

- How addresses are loaded by chain ID
- Environment variable overrides
- Control flags (`SKIP_LOAD_DEPLOYMENTS`, `SKIP_UPDATE_DEPLOYMENTS`)
