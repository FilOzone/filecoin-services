# Service Contracts

This directory contains the smart contracts for different Filecoin services using [Filecoin payment service](https://github.com/FilOzone/filecoin-services-payments).

## Structure

- `src/` - Contract source files
  - `FilecoinWarmStorageService.sol` - A service contract with [PDP](https://github.com/FilOzone/pdp) (Proof of Data Possession) and payment integration
  - `FilecoinWarmStorageServiceStateView.sol` - View contract for reading `FilecoinWarmStorageService` with `eth_call`.
  - `src/lib` - Library source files
    - `FilecoinWarmStorageServiceLayout.sol` - Constants conveying the storage layout of `FilecoinWarmStorageService`
    - `FilecoinWarmStorageServiceStateInternalLibrary.sol` - `internal` library for embedding logic to read `FilecoinWarmStorageService`
    - `FilecoinWarmStorageServiceStateLibrary.sol` - `public` library for using `delegatecall` to read `FilecoinWarmStorageService`
    - `SignatureVerificationLib.sol` - external library with EIP-712 metadata hashing and signature verification
- `test/` - Test files  
  - `FilecoinWarmStorageService.t.sol` - Tests for the service contract
- `tools/` - Deployment and utility scripts
  - `create_data_set_with_payments.sh` - Script to create data sets with payments
  - `deploy-warm-storage-calibnet.sh` - Deployment script for Warm Storage service on Calibnet
  - `deploy-all-warm-storage-calibnet.sh` - Deployment script for all Warm Storage contracts on Calibnet
  - Note: deployment scripts now deploy and link `SignatureVerificationLib` when deploying `FilecoinWarmStorageService`.
    The scripts will deploy `src/lib/SignatureVerificationLib.sol` (or simulate it in dry-run) and pass the library address
    to `forge create` via the `--libraries` flag so the service implementation is correctly linked.
- `lib/` - Dependencies (git submodules)
  - `forge-std` - Foundry standard library
  - `openzeppelin-contracts` - OpenZeppelin contracts
  - `openzeppelin-contracts-upgradeable` - OpenZeppelin upgradeable contracts  
  - `fws-payments` - Filecoin Services payments contract
  - `pdp` - PDP verifier contract (from main branch)


### Extsload
The allow for many view methods within the 24 KiB contract size constraint, viewing is done with `extsload` and `extsloadStruct`.
There are three recommended ways to access `view` methods.

#### View Contract
To call the view methods off-chain, for example with `eth_call`, use the `FilecoinWarmStorageServiceStateView`:
```sh
forge build
jq .abi out/FilecoinWarmStorageServiceStateView.sol/FilecoinWarmStorageServiceStateView.json
```

For example to call `paymentsContractAddress()` on `$WARM_STORAGE_VIEW_ADDRESS`:
```json
{
    "id": 1,
    "method": "eth_call",
    "params": [
        {
            "to": $WARM_STORAGE_VIEW_ADDRESS,
            "data": "0xbc471469"
        },
        "latest"
    ]
}
```

`FilecoinWarmStorageServiceStateView` is best for off-chain queries but the following `library` approaches are better for smart contracts.

#### Internal Library
To embed the view methods you use into your smart contract, use the `FilecoinWarmStorageServiceStateInternalLibrary`:
```solidity
    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;
```

Compared to other approaches this will use the least gas.

#### Public Library
For your smart contract to call the view methods with a `delegatecall` into a shared library, use the `FilecoinWarmStorageServiceStateLibrary`:
```solidity
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;
```

Compared to other approaches this will have the least codesize.


## Contributing
See [CONTRIBUTING.md](./CONTRIBUTING.md)

### Building

```bash
make build
# or simply:
make
```

### Testing

```bash
make test
```

### Code Generation

The project includes several auto-generated files. To regenerate them:

```bash
# Generate all files (layout, internal library, view contract)
make gen

# Force regeneration if files are corrupted
make force-gen

# Clean all generated files
make clean-gen
```

### ABI Management

The project maintains checked-in ABI files in the `abi/` directory for use by scripts and external tools:

```bash
# Update checked-in ABIs after contract changes
make update-abi
```

This extracts the ABIs from the compiled contracts and saves them as JSON files:
- `abi/FilecoinWarmStorageService.abi.json` - Main service contract ABI
- `abi/FilecoinWarmStorageServiceStateView.abi.json` - View contract ABI

These ABIs are used by the code generation scripts in the `gen` target and should be updated whenever contract interfaces change.

Note: `SignatureVerificationLib.sol` is an external library (public functions); if you rely on its ABI for external tooling or verification,
you may also extract the library ABI via `make update-abi` after compilation. The primary consumer is the service implementation which
is linked at deploy time by the scripts in `tools/`.

### Dependencies

The project depends on:
- PDP contracts from https://github.com/FilOzone/pdp.git (main branch)
- Filecoin Services Payments from https://github.com/FilOzone/filecoin-services-payments
- OpenZeppelin contracts (both standard and upgradeable)
- Forge standard library

All dependencies are managed as git submodules and initialized with:
```bash
git submodule update --init --recursive
```
