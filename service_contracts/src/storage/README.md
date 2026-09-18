# FWSS shared storage

`FWSSStorage` declares the legacy application layout used by
`FilecoinWarmStorageService`, including retired fields and stored structs.
Contracts inheriting it share the same field declarations and storage positions.

Preserve root slots 0–23, field order, types, struct members and packing. Retired
fields remain reserved. Appending ordinary fields independently in different
modules can make them write to the same proxy slots. OpenZeppelin state uses its
existing bases and namespaces.

`FWSSDispatcher` and `FWSSStateViewManager` access selected legacy fields through
typed accessors and generated slot constants instead of inheriting the full layout.
They declare no linear storage; `make check-layout` verifies this. Tests check their
accesses against legacy slots and existing StateView readers.

## Verification

Run from `service_contracts/`:

```sh
make gen
make check-layout
forge test
make update-abi
```

`make gen` regenerates the compiler layout snapshot and read helpers.
`make check-layout` compares the snapshot with the PR base selected by
`GITHUB_BASE_REF`, or with `HEAD~1` locally. The comparison includes inherited
fields, offsets, packing and nested types. The normalizer preserves historical
names for `DataSetInfo` and `PlannedUpgrade` when comparing compiler output.

These checks detect layout changes; they do not execute an upgrade or verify
migration behavior against a deployed proxy.
