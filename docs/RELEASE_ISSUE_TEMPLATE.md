# Release Issue Template - FilecoinWarmStorageService v[VERSION]

**Release Version:** v[VERSION]  
**Target Networks:** [mainnet/calibnet/all]  
**Release Type:** [major/minor/patch/hotfix]  
**Breaking Changes:** [yes/no]

## Pre-Release Checklist

### Code & Testing
- [ ] All tests pass (`make test`)
- [ ] Contract size checks pass (`make size-check`)
- [ ] Linting passes (`make lint`)
- [ ] Security audit review (if applicable)
- [ ] Code review and approval on release PR

### Documentation & Communication
- [ ] CHANGELOG.md updated with all changes
- [ ] Breaking changes documented (if any)
- [ ] Migration guide prepared (if breaking changes)
- [ ] ABI files updated and committed
- [ ] Release notes drafted

## Deployment Checklist

### Pre-Deployment Verification
- [ ] Submodule dependencies updated and tested
  - [ ] `fws-payments` submodule
  - [ ] `pdp` submodule
  - [ ] `openzeppelin-contracts` submodule
- [ ] Deployment scripts tested on testnet
- [ ] Contract addresses prepared for environment

### Network Deployments
#### Calibnet (Testnet)
- [ ] Deploy contracts to Calibnet
- [ ] Verify contract deployment
- [ ] Run integration tests
- [ ] Update contract addresses in subgraph
- [ ] Deploy and test subgraph

#### Mainnet
- [ ] Deploy contracts to Mainnet  
- [ ] Verify contract deployment
- [ ] Update contract addresses in subgraph
- [ ] Deploy subgraph to production
- [ ] Monitor initial transactions

## Post-Deployment Checklist

### Verification & Monitoring
- [ ] Contract verification on block explorer
- [ ] ABI published and accessible
- [ ] Subgraph indexing correctly
- [ ] Basic functionality testing
- [ ] Monitor for any issues in first 24h

### Communication & Documentation
- [ ] GitHub release created with proper tags
- [ ] Release announcement (if major/minor)
- [ ] Update README with new contract addresses
- [ ] Notify integration partners of changes
- [ ] Update deployment documentation

## Rollback Plan

### Emergency Procedures
- [ ] Rollback procedure documented
- [ ] Previous contract addresses backed up
- [ ] Emergency contact list updated
- [ ] Monitoring alerts configured

## Notes

### Key Changes in This Release
<!-- Highlight important changes, especially breaking ones -->

### Deployment Commands Used
```bash
# Record the actual commands used for deployment
make deploy-calibnet
make deploy-mainnet
```

### Contract Addresses
<!-- Update with actual deployed addresses -->
- **Calibnet:**
  - FilecoinWarmStorageService: `0x...`
  - ServiceProviderRegistry: `0x...` 
  - Payments: `0x...`

- **Mainnet:**
  - FilecoinWarmStorageService: `0x...`
  - ServiceProviderRegistry: `0x...`
  - Payments: `0x...`

## Post-Release Follow-up
- [ ] Monitor usage metrics
- [ ] Collect community feedback
- [ ] Plan next release cycle
- [ ] Archive this release issue

---

**Release Manager:** @[username]  
**Release Date:** [YYYY-MM-DD]  
**Estimated Duration:** [X hours]
