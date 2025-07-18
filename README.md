# Filecoin Services

Building Filecoin onchain programmable services that integrate with the Filecoin network for decentralized storage.

## ⚠️ IMPORTANT DISCLAIMER

**🚨 THE FILECOIN WARM STORAGE CONTRACT IS CURRENTLY UNDER ACTIVE DEVELOPMENT AND IS NOT READY FOR PRODUCTION USE 🚨**

**DO NOT USE IN PRODUCTION ENVIRONMENTS**

This software is provided for development, testing, and research purposes only. The smart contracts have not undergone comprehensive security audits and may contain bugs, vulnerabilities, or other issues that could result in loss of funds or data.

**Use at your own risk. The developers and contributors are not responsible for any losses or damages.**

## Overview

This repository contains smart contracts and services for the Filecoin ecosystem, featuring:

- **FilecoinWarmStorageService**: A comprehensive service contract that combines PDP (Proof of Data Possession) verification with integrated payment rails
- **Payment Integration**: Built on top of the [Filecoin Services Payments](https://github.com/FilOzone/filecoin-services-payments) framework
- **Data Verification**: Uses [PDP verifiers](https://github.com/FilOzone/pdp) for cryptographic proof of data possession

## 🚀 Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) - Ethereum development toolchain
- Git with submodule support

### Installation

1. Clone the repository:
```bash
git clone https://github.com/your-org/filecoin-services.git
cd filecoin-services/service_contracts
```

2. Install dependencies and initialize submodules:
```bash
make install
```

3. Build the contracts:
```bash
make build
```

4. Run tests:
```bash
make test
```

## 📋 Project Structure

```
service_contracts/
├── src/                    # Smart contract source files
│   └── FilecoinWarmStorageService.sol  # Main service contract with PDP and payment integration
├── test/                   # Test files
│   └── FilecoinWarmStorageService.t.sol # Contract tests
├── tools/                  # Deployment and utility scripts
├── lib/                    # Dependencies (git submodules)
│   ├── forge-std/          # Foundry standard library
│   ├── openzeppelin-contracts/
│   ├── fws-payments/       # Filecoin Services payments
│   └── pdp/               # PDP verifier contracts
└── out/                    # Compiled artifacts
```

## 🌐 Deployed Contracts

### Calibnet (Testnet)
#### Live but soon to be deprecated

We are updating contract terminology to make the codebase more self-explanatory. As part of this process, we will be deploying a new set of contracts on Calibration and deprecating the existing Pandora Service contract.

Key points:
- New data (“root”) additions to the current contract will be frozen around the end of July.
- Storage Providers may remove existing datasets during this period.
- Please migrate to the new set of contracts as soon as possible!
- Thank you for your cooperation as we improve developer experience and clarity.

Pandora Service**: [`0xf49ba5eaCdFD5EE3744efEdf413791935FE4D4c5`](https://calibration.filfox.info/en/address/0xf49ba5eaCdFD5EE3744efEdf413791935FE4D4c5)

#### Coming next
- **FilecoinWarmStorageService**: [TBD](https://calibration.filfox.info/en/address/TBD)
  - FilecoinWarmStorageService implements UUPSUpgradeable & EIP712Upgradeable and this is the proxy contract address - it is relatively stable at this point. 
- **Latest Implementation**: [`TBD`](https://calibration.filfox.info/en/address/TBD)

### Mainnet
🚧 **Coming Soon** - Mainnet deployment is in progress

### Version History
Check the [latest tags](https://github.com/your-org/filecoin-services/tags) to find specific commit hashes and corresponding contract addresses for each deployment.

## 🔧 Development

### Running Tests

```bash
# Run all tests
make test

# Run tests with specific verbosity (using forge directly)
forge test -vvv --via-ir

# Run specific test file (using forge directly)
forge test --match-path test/FilecoinWarmStorageService.t.sol --via-ir
```

### Code Quality

```bash
# Format code
make fmt

# Check code formatting
make fmt-check

# Generate test coverage
make coverage

# Clean build artifacts
make clean
```

### Available Make Targets

Run `make help` to see all available targets:

```bash
make help
```

### Deployment

Use the provided deployment scripts in the `tools/` directory:

```bash
# Deploy to Calibnet
./tools/deploy-pandora-calibnet.sh

# Deploy all contracts
./tools/deploy-all-pandora-calibnet.sh

# Upgrade existing deployment
./tools/upgrade-pandora-calibnet.sh
```

## 🔗 Dependencies

This project builds on several key components:

- **PDP Contracts**: [FilOzone/pdp](https://github.com/FilOzone/pdp) - Proof of Data Possession verification
- **Payment Rails**: [FilOzone/filecoin-services-payments](https://github.com/FilOzone/filecoin-services-payments) - Payment infrastructure
- **OpenZeppelin**: Industry-standard smart contract libraries for security and upgradeability

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

## 📄 License
Dual-licensed under [MIT](https://github.com/filecoin-project/lotus/blob/master/LICENSE-MIT) + [Apache 2.0](https://github.com/filecoin-project/lotus/blob/master/LICENSE-APACHE)