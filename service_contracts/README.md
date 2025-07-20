# Service Contracts

This directory contains the smart contracts for different Filecoin services using [Filecoin payment service](https://github.com/FilOzone/filecoin-services-payments).

## Structure

- `src/` - Contract source files
  - `PandoraService.sol` - A service contract with [PDP](https://github.com/FilOzone/pdp) (Proof of Data Possession) and payment integration
- `test/` - Test files  
  - `PandoraService.t.sol` - Tests for the service contract
- `tools/` - Deployment and utility scripts
  - `create_proofset_with_payments.sh` - Script to create data sets with payments
  - `deploy-pandora-calibnet.sh` - Deployment script for Pandora service on Calibnet
  - `deploy-all-pandora-calibnet.sh` - Deployment script for all Pandora contracts on Calibnet
- `lib/` - Dependencies (git submodules)
  - `forge-std` - Foundry standard library
  - `openzeppelin-contracts` - OpenZeppelin contracts
  - `openzeppelin-contracts-upgradeable` - OpenZeppelin upgradeable contracts  
  - `fws-payments` - Filecoin Services payments contract
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
- Filecoin Services Payments from https://github.com/FilOzone/filecoin-services-payments
- OpenZeppelin contracts (both standard and upgradeable)
- Forge standard library

All dependencies are managed as git submodules and initialized with:
```bash
git submodule update --init --recursive
```