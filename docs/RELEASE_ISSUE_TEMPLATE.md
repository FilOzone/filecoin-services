# FWSS Contract Upgrade Dependencies Document

This document outlines the procedures for upgrading dependencies and contracts in the FilecoinWarmStorageService (FWSS) ecosystem.

## Overview

The FWSS system depends on several key components that may need periodic upgrades:
- PDP (Proof of Data Possession) contracts
- Filecoin-Pay contract  
- SessionKeyRegistry

## Dependency Upgrade Procedures

### 1. PDP Contract Upgrade

#### In the PDP Repository:
- [ ] Create a PR with changelog changes
- [ ] Bump version string in `PDPVerifier.sol`
- [ ] Merge PR after review
- [ ] Create tag/release manually on GitHub UI

#### Upgrade PDP Implementation Contract in FWSS:
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

### 2. Filecoin-Pay Upgrade

> **TODO:** Document FWS-Payments upgrade procedure
- [ ] Update procedure documentation
- [ ] Define environment variables required
- [ ] Document testing steps
- [ ] Create upgrade scripts if needed

### 3. OpenZeppelin Contracts Upgrade

> **TODO:** Document OpenZeppelin contracts upgrade procedure
- [ ] Document procedure for `openzeppelin-contracts` submodule
- [ ] Document procedure for `openzeppelin-contracts-upgradeable` submodule
- [ ] Define compatibility testing requirements
- [ ] Create migration scripts for breaking changes

### 4. Session Key Registry Upgrade

> **TODO:** Document Session Key Registry upgrade procedure
- [ ] Update procedure documentation
- [ ] Define required environment variables
- [ ] Document testing and verification steps

### 5. Subgraph Dependencies Upgrade

> **TODO:** Document subgraph dependencies upgrade procedure
- [ ] Document npm package updates in `/subgraph`
- [ ] Define subgraph redeployment process
- [ ] Document ABI synchronization requirements

## Network-Specific Procedures

### Calibnet (Testnet) Upgrades
- [ ] Always test upgrades on Calibnet first
- [ ] Verify contract interactions work as expected
- [ ] Run integration tests
- [ ] Update subgraph with new contract addresses/ABIs
- [ ] Monitor for 24 hours before mainnet deployment

### Mainnet Upgrades
- [ ] Ensure Calibnet upgrade was successful
- [ ] Double-check all environment variables
- [ ] Execute upgrade during low-traffic periods
- [ ] Have rollback plan ready
- [ ] Monitor transactions immediately after upgrade

## Post-Upgrade Verification

### Contract Verification
- [ ] Verify contracts on block explorer (Etherscan/FilScan)
- [ ] Confirm ABI matches deployed contract
- [ ] Test basic contract functionality
- [ ] Verify proxy-implementation linkage (for upgradeable contracts)

### System Integration Testing
- [ ] Run full integration test suite
- [ ] Verify subgraph indexing
- [ ] Test frontend integration (if applicable)
- [ ] Monitor gas costs and performance

### Documentation Updates
- [ ] Update contract addresses in documentation
- [ ] Update ABI files in repository
- [ ] Update CHANGELOG.md
- [ ] Notify integration partners of changes

## Emergency Procedures

### Rollback Plan
- [ ] Previous contract addresses documented
- [ ] Rollback scripts tested and ready
- [ ] Emergency contact list available
- [ ] Monitoring alerts configured

### Issue Response
- [ ] Incident response team identified
- [ ] Communication channels established
- [ ] Escalation procedures defined

## Environment Variables Reference

### Required for PDP Upgrades
```bash
export RPC_URL="<network_rpc_url>"
export KEYSTORE="<path_to_keystore>"
export PASSWORD="<keystore_password>"
export PROXY_ADDRESS="<proxy_contract_address>"
export UPGRADE_DATA="<upgrade_function_signature>"
export IMPLEMENTATION_PATH="<contract_path>"
```

### Required for Other Dependencies
> **TODO:** Document environment variables for other dependencies

## Useful Commands

### Foundry/Cast Commands
```bash
# Get function signature for upgrade data
cast sig "migrate()"

# Check contract size
make size-check

# Run tests
make test

# Deploy to Calibnet
make deploy-calibnet

# Deploy to Mainnet  
make deploy-mainnet
```

### Git Submodule Management
```bash
# Update all submodules
git submodule update --recursive --remote

# Update specific submodule
git submodule update --remote lib/pdp

# Check submodule status
git submodule status
```

## Notes

- Always upgrade dependencies in a controlled manner
- Test thoroughly on Calibnet before mainnet deployment
- Keep detailed records of upgrade procedures and results
- Consider gas implications of upgrades, especially for frequently called functions
- Coordinate with integration partners for major upgrades

---

**Last Updated:** [DATE]  
**Document Version:** v1.0  
**Maintainer:** [TEAM/PERSON]
