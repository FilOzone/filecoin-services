# Filecoin Services

Building Filecoin onchain programmable services that integrate with the Filecoin network for decentralized storage.

## Overview

This repository contains smart contracts and services for the Filecoin ecosystem, featuring:

- **FilecoinWarmStorageService**: A comprehensive service contract that combines PDP (Proof of Data Possession) verification with integrated payment rails for data set management
- **Payment Integration**: Built on top of the [Filecoin Services Payments](https://github.com/FilOzone/filecoin-services-payments) framework
- **Data Verification**: Uses [PDP verifiers](https://github.com/FilOzone/pdp) for cryptographic proof of data possession

## Pricing

The service uses static global pricing set by the contract owner (currently 2.5 USDFC per TiB/month).
Rail payment rates are calculated as a size-proportional component plus a flat per-dataset fee of 0.024 USDFC/month.

Storage providers submit on-chain transactions on behalf of clients (piece additions, removal scheduling, proving). To reimburse SPs for these gas costs, FWSS charges small one-time operation fees: $0.025 on dataset creation, $0.0005 + $0.0003/piece per add-pieces call, $0.002 per removal-scheduling call, and $0.00112 when an SP terminates service with payer consent. Fees are drawn from a $0.10 lifecycle reserve maintained as fixed lockup on the PDP rail.

The complete on-chain price catalogue is exposed via `FilecoinWarmStorageServiceStateView.getPriceList()`. It returns a single nested `PriceList` struct covering token, streaming rates, one-time fees, and lockup amounts/periods. See [SPEC.md](SPEC.md) for details on rate calculation, operation fees, pricing updates, and top-up/renewal behavior.

## 🚀 Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) - Ethereum development toolchain
- [jq](https://jqlang.github.io/jq/) - Command-line JSON processor (v1.7+ recommended)
- Git with submodule support

### Installation

1. Clone the repository:
```bash
git clone https://github.com/FilOzone/filecoin-services.git
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
├── src/                                 # Smart contract source files
│   └── FilecoinWarmStorageService.sol   # Main service contract with PDP and payment integration
├── test/                                # Test files
│   └── FilecoinWarmStorageService.t.sol # Contract tests
├── tools/                               # Deployment and utility scripts
├── lib/                                 # Dependencies (git submodules)
│   ├── forge-std/                       # Foundry standard library
│   ├── openzeppelin-contracts/
│   ├── fws-payments/                    # Filecoin Services payments
│   └── pdp/                             # PDP verifier contracts
└── out/                                 # Compiled artifacts
```

## 🌐 Deployed Contracts

Contract addresses for all supported networks are maintained in [service_contracts/deployments.json](./service_contracts/deployments.json), which is updated automatically as new deployments are published.

- Mainnet: chain ID `314`
- Calibnet (testnet): chain ID `314159`

## 🔧 Development

### Running Tests

```bash
cd ./service_contracts/

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

## 🚀 Deployment

For comprehensive deployment instructions, parameters, and scripts, see [service_contracts/tools/README.md](./service_contracts/tools/README.md).

## 📊 Subgraph

The subgraph for indexing Filecoin Warm Storage Service contracts is maintained in a separate repository: [FIL-Builders/fwss-subgraph](https://github.com/FIL-Builders/fwss-subgraph).

## 🔗 Dependencies

This project builds on several key components:

- **PDP Contracts**: [FilOzone/pdp](https://github.com/FilOzone/pdp) - Proof of Data Possession verification
- **Payment Rails**: [FilOzone/filecoin-services-payments](https://github.com/FilOzone/filecoin-services-payments) - Payment infrastructure
- **OpenZeppelin**: Industry-standard smart contract libraries for security and upgradeability

## 🤝 Contributing

See [service_contracts/CONTRIBUTING.md](./service_contracts/CONTRIBUTING.md) for development guidelines and code generation details.

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

## 📄 License
Dual-licensed under [MIT](https://github.com/FilOzone/filecoin-services/blob/main/LICENSE.md) + [Apache 2.0](https://github.com/FilOzone/filecoin-services/blob/main/LICENSE.md)

