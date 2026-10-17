# Service Contracts

This directory contains the smart contracts for different Filecoin services using [Filecoin payment service](https://github.com/FilOzone/filecoin-services-payments).

## Structure

- `src/` - Contract source files
  - `FWSSInitializer.sol` - One-shot implementation that initializes a fresh FWSS proxy and moves it to the ERC-8167 dispatcher
  - `interfaces/IFilecoinWarmStorageService.sol` - FWSS interface generated from the ABI `josuke abi` merges from the modules
  - `src/modules` - ERC-8167 modules the dispatcher routes to; `FWSSViewModule.sol` serves the view methods at the FWSS proxy
  - `IFilecoinServiceMetadata.sol` - Minimal service identity interface (`name`, `description`, `homepage`)
  - `src/lib` - Library source files
    - `FilecoinWarmStorageServiceLayout.sol` - Constants conveying the storage layout of `FilecoinWarmStorageService`
    - `FilecoinWarmStorageServiceStateInternalLibrary.sol` - `internal` library for embedding logic to read `FilecoinWarmStorageService`
    - `FilecoinWarmStorageServiceStateLibrary.sol` - `public` library for using `delegatecall` to read `FilecoinWarmStorageService`
    - `LibSignatureVerification.sol` - `internal` library with EIP-712 metadata hashing and signature verification
- `test/` - Test files  
  - `FilecoinWarmStorageService.t.sol` - Tests for the service contract
- `tools/` - Deployment and utility scripts
  - `warm-storage-deploy-all.sh` - Deploys a fresh Warm Storage stack, mainly for local devnets; FWSS deploys through
    `script/FWSSDeploy.s.sol` on the ERC-8167 dispatcher
  - `warm-storage-deploy-all-test.sh` - Runs `warm-storage-deploy-all.sh` against anvil and checks the stack, as CI does
- `lib/` - Dependencies (git submodules)
  - `forge-std` - Foundry standard library
  - `openzeppelin-contracts` - OpenZeppelin contracts
  - `openzeppelin-contracts-upgradeable` - OpenZeppelin upgradeable contracts  
  - `fws-payments` - Filecoin Services payments contract
  - `pdp` - PDP verifier contract (from main branch)


## Dataset Status & Lifecycle

Datasets have a simplified two-state lifecycle system to track their operational status:

### Status States

- **Inactive**: Dataset doesn't exist or has no pieces added yet (rate = 0, no proving)
- **Active**: Dataset has pieces and proving history (including terminated datasets)

**Important**: Terminated datasets remain **Active** because they still have data. Status reflects data existence, not operational state. Use `pdpEndEpoch` to check if a dataset is terminated.

### Querying Status

**From Solidity:**
```solidity
import {FilecoinWarmStorageServiceStateLibrary} from "./lib/FilecoinWarmStorageServiceStateLibrary.sol";

// Get status
DataSetStatus status = FilecoinWarmStorageServiceStateLibrary.getDataSetStatus(service, dataSetId);
bool isActive = (status == DataSetStatus.Active);
```

**From Subgraph:**
```graphql
{
  dataSet(id: "0x...") {
    setId
    status  # "ACTIVE" or "INACTIVE"
    totalPieces
    pdpEndEpoch
  }
}
```

**Via View Contract:**
```solidity
// viewContract is FWSS.viewContractAddress(): the StateView, or the FWSS proxy after the dispatcher transition
DataSetStatus status = viewContract.getDataSetStatus(dataSetId);
// 0 = Inactive, 1 = Active
```

### Extsload
The allow for many view methods within the 24 KiB contract size constraint, viewing is done with `extsload` and `extsloadStruct`.
There are three recommended ways to access `view` methods.

#### View Contract
To call the view methods off-chain, for example with `eth_call`, call the view contract that the FWSS proxy reports through `viewContractAddress()`. On the v1.4.0 monolith that is the deployed `FilecoinWarmStorageServiceStateView`, whose ABI is `abi/FilecoinWarmStorageServiceStateView.abi.json`. After the ERC-8167 dispatcher transition, `viewContractAddress()` returns the FWSS proxy itself, which serves the same methods through `FWSSViewModule`:
```sh
forge build
jq .abi out/FWSSViewModule.sol/FWSSViewModule.json
```

After the transition, `josuke abi $FWSS_PROXY_ADDRESS` prints the proxy's complete ABI, merged from every module it routes to.

For example to call `getPriceList()` on `$WARM_STORAGE_VIEW_ADDRESS`, the address `viewContractAddress()` returned:
```json
{
    "id": 1,
    "method": "eth_call",
    "params": [
        {
            "to": $WARM_STORAGE_VIEW_ADDRESS,
            "data": "0xb7029144"
        },
        "latest"
    ]
}
```

Reading `viewContractAddress()` rather than hard-wiring an address keeps callers working across the transition. The view contract is best for off-chain queries but the following `library` approaches are better for smart contracts.

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

The project includes several auto-generated files that must be kept in sync with the contract source. The generated files are:

- [`src/lib/FilecoinWarmStorageServiceLayout.sol`](src/lib/FilecoinWarmStorageServiceLayout.sol) — storage slot constants generated from [`src/storage/FWSSStorage.sol`](src/storage/FWSSStorage.sol) by [`tools/generate_storage_layout.sh`](tools/generate_storage_layout.sh). Each state variable is mapped to a `bytes32` constant holding its storage slot number (e.g. `MAX_PROVING_PERIOD_SLOT = bytes32(uint256(0))`). Used by `FilecoinWarmStorageServiceStateLibrary` to implement `extsload`-based view access without delegatecall overhead.
- [`src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol`](src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol) — produced by replacing `public` with `internal` in [`src/lib/FilecoinWarmStorageServiceStateLibrary.sol`](src/lib/FilecoinWarmStorageServiceStateLibrary.sol) via `sed`.
- [`src/modules/FWSSViewModule.sol`](src/modules/FWSSViewModule.sol) — view module generated from [`src/lib/FilecoinWarmStorageServiceStateLibrary.sol`](src/lib/FilecoinWarmStorageServiceStateLibrary.sol) by [`tools/generate_view_module.sh`](tools/generate_view_module.sh), reading storage directly in place of `extsload`.

To regenerate them after changing [`src/storage/FWSSStorage.sol`](src/storage/FWSSStorage.sol) or [`src/lib/FilecoinWarmStorageServiceStateLibrary.sol`](src/lib/FilecoinWarmStorageServiceStateLibrary.sol):

```bash
# Generate all files (layout, internal library, view module)
make gen

# Force regeneration if files are corrupted
make force-gen

# Clean all generated files
make clean-gen
```

**Important:** Generated files must be committed. The `check-gen` CI job ([`.github/workflows/check.yml`](../.github/workflows/check.yml)) runs `make gen` on every pull request and push to `main`, then checks `git status`. If the regenerated output differs from what is committed, the build fails.

Always run `make gen` and commit the results whenever you modify a contract that affects storage layout or state access.

### ABI Management

The project maintains checked-in ABI files in the `abi/` directory for use by scripts and external tools:

```bash
# Update checked-in ABIs after contract changes
make update-abi
```

This extracts the checked-in ABIs, including:
- `abi/FilecoinWarmStorageService.abi.json` - Main service contract ABI
- `abi/FilecoinWarmStorageServiceStateLibrary.abi.json` - State library ABI used by generated view helpers

`abi/FilecoinWarmStorageServiceStateView.abi.json` is the frozen ABI of the legacy view contract still deployed for networks on the v1.4.0 monolith; `make update-abi` no longer regenerates it.

These ABIs are used by the code generation scripts in the `gen` target and should be updated whenever contract interfaces change.
`FilecoinWarmStorageService.abi.json` also includes first-party library event fragments emitted by the FWSS proxy at runtime.

### Dependencies

The project depends on:
- PDP contracts from https://github.com/FilOzone/pdp.git (main branch)
- Filecoin Services FilecoinPayV1 from https://github.com/FilOzone/filecoin-services-payments
- OpenZeppelin contracts (both standard and upgradeable)
- Forge standard library

All dependencies are managed as git submodules and initialized with:
```bash
git submodule update --init --recursive
```
