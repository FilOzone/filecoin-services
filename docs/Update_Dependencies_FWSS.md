# Updating FWSS Dependencies

This document outlines the procedures for upgrading dependencies and contracts in the FilecoinWarmStorageService (FWSS) ecosystem.

## Overview

The FWSS system depends on several key components that may need periodic upgrades:
- PDP (Proof of Data Possession) contracts
- Filecoin-Pay contract  
- SessionKeyRegistry

## Dependency Upgrade Procedures

### PDP Contract Upgrades

#### Non-breaking PDP Contract Upgrade

This is outlining the upgrade flow if there is a non-breaking PDP contract upgrade change.

##### In the PDP Repository:
- [ ] Create a PR titled `build: prep PDP vX.Y.Z release` with the following changes:
  - [ ] Add an entry for the new version in the changelog:
    - Run `git log --pretty=format:"%h - %an, %ar : %s" vX.Y.Z..main` (where `vX.Y.Z` is the last tagged release version)
    - Use the output to document changes since the last release
  - [ ] Bump the version string in [pdp/src/PDPVerifier.sol](https://github.com/FilOzone/pdp/blob/e8d31459151d38a057c1df1ed43e34cd7de45476/src/PDPVerifier.sol#L161)
- [ ] Merge PR after review
- [ ] Create tag/release manually on GitHub UI

##### Upgrade PDP Implementation Contract in FWSS:
- [ ] Checkout the desired PDP tag you want to upgrade to
- [ ] Set required environment variables:
  ```bash
  export RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
  export KEYSTORE="~/.foundry/keystores/calibnet-deployer" #This has to be the same keystore that deployed the FWSS contract on Calibration network
  export PASSWORD="your_keystore_password"
  export PROXY_ADDRESS="0x...PDPProxy Address on Calibnet (The one used by FWSS)"
  export UPGRADE_DATA="0x..." # Get this by running "cast sig migrate()"
  export IMPLEMENTATION_PATH="src/PDPVerifier.sol:PDPVerifier" # If executing from /pdp
  ```
- [ ] Use the `upgrade-contract.sh` script to upgrade the contract
- [ ] Verify upgrade on Calibnet

#### A breaking PDP Contract Upgrade 

This is outlining the flow for a breaking change in the PDP Contract, and how to get that upgraded in FWSS.

### Filecoin-Pay Upgrades

Filecoin-Pay is a non-upgradeable contract, so every change that needs to get propagated up to FWSS requires a new set of contracts currently.

TODO: Outline publishing a new set of Filecoin-Pay contracts.

### 4. Session Key Registry Upgrade

TODO: Outline upgrading/publishing a new SessionKeyRegistry contract.
