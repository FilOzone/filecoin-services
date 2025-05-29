# Service Contracts

This directory contains the SimplePDPServiceWithPayments contract and related files migrated from the pdp repository.

## Structure

- `src/` - Contract source files
  - `SimplePDPServiceWithPayments.sol` - Main PDP service contract with payment integration
- `test/` - Test files  
  - `SimplePDPServiceWithPayments.t.sol` - Tests for the service contract
- `tools/` - Deployment and utility scripts
  - `create_proofset_with_payments.sh` - Script to create proof sets with payments
  - `deploy-pdp-payments-calibnet.sh` - Deployment script for Calibnet
- `lib/` - Dependencies (git submodules)
  - `forge-std` - Foundry standard library
  - `openzeppelin-contracts` - OpenZeppelin contracts
  - `openzeppelin-contracts-upgradeable` - OpenZeppelin upgradeable contracts  
  - `fws-payments` - Filecoin Web Services payments contract
  - `pdp` - PDP verifier contract (from main branch)

## Building

```bash
forge build
```

## Testing

```bash
forge test
```

## Dependencies

The project depends on:
- PDP contracts from https://github.com/FilOzone/pdp.git (main branch)
- FWS Payments from https://github.com/FilOzone/fws-payments
- OpenZeppelin contracts (both standard and upgradeable)
- Forge standard library

All dependencies are managed as git submodules and initialized with:
```bash
git submodule update --init --recursive
```