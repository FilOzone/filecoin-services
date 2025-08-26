# Contributing

## Setup
After [installing forge](https://getfoundry.sh/introduction/installation/) and [jq](https://jqlang.github.io/jq/),
```sh
git clone git@github.com:FilOzone/filecoin-services.git
cd filecoin-services/service_contracts
make install  # Install dependencies
make build    # Build contracts
make gen      # Generate code files
```

### Setup git hooks
To add a hook to run `forge fmt --check` on `git commit`:
```sh
cd $(git rev-parse --show-toplevel)
echo 'forge fmt --root $(git rev-parse --show-toplevel)/service_contracts --check || exit 1' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

## Building

```sh
make build
# or with via-ir optimization:
forge build --via-ir
```

## Testing
```sh
make test
# or for more verbose output:
forge test -vvv
```

## Formatting
```sh
make fmt        # Format code
make fmt-check  # Check formatting
```

## Developing `view` methods for `extsload`

Use `extsload` and `extsloadStruct` to make data `public`.

New `view` methods should be added to `FilecoinWarmStorageServiceStateLibrary`.

### Regenerating Code Files

When you make changes to the storage layout or library, regenerate the necessary files:

```sh
# Regenerate all files (recommended)
make gen

# Or regenerate individual files:
make src/lib/FilecoinWarmStorageServiceLayout.sol               # Storage layout
make src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol # Internal library
make src/FilecoinWarmStorageServiceStateView.sol                # View contract
```

**Important Notes:**
- `FilecoinWarmStorageServiceStateInternalLibrary` and `FilecoinWarmStorageServiceStateView` are auto-generated from `FilecoinWarmStorageServiceStateLibrary`
- `FilecoinWarmStorageServiceLayout` is auto-generated from the storage layout of `FilecoinWarmStorageService`
- Always run `make gen` after modifying storage variables or the state library
- Use `make force-gen` if the generated files become corrupted
- Use `make safe-gen` for a safe regeneration with automatic rollback on failure

### Deploy a new `FilecoinWarmStorageServiceStateView`
```sh
make src/FilecoinWarmStorageServiceStateView.sol
tools/generate_view_contract.sh
```
