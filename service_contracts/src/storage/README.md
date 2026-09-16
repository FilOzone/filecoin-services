# FWSS shared storage

`FWSSStorage` declares the complete legacy application layout,
including retired fields and stored structs. FWSS inherits it and uses the same field
names. Previously private fields become internal to allow inherited access.

Preserve the 24 root slots (0–23), field order, types, struct members and packing.
Retired fields must remain in place. Constants and constructor immutables stay in
FWSS; OpenZeppelin state remains in its existing bases and namespaces.

Future modules must inherit the shared declarations. Independently appending fields
in different modules can make them write to the same proxy slots. Their actual
compiled layouts and any new storage must be reviewed when modules are introduced.

## Verification

Run from `service_contracts/`:

```sh
make gen
make check-layout
make check-fwss-module-layout
forge test
make update-abi
```

Existing CI regenerates FWSS's compiler layout, verifies generated files are current,
and compares the snapshot against the PR base. Inherited fields are included, so
shifts caused by this extraction are checked by the same workflow. Local
`make check-layout` compares against HEAD~1 when available; it is not a deployed
implementation check. No new upgrade validator is required by this extraction.

`make check-fwss-module-layout` builds production `src/` into a fresh artifact
folder, discovers direct and indirect `FWSSStorage` descendants from Forge's
compiler-derived inheritance linearization, and compares each complete normalized
layout exactly against the compiled shared base. No module list or interfaces are
required. Module-specific ordinary fields are rejected; namespaced storage and
business behavior need separate review and tests. The historical additive
`make check-layout` policy remains unchanged.

The snapshot normalizer maps only the declaring-contract names of `DataSetInfo` and
`PlannedUpgrade` to their historical names. Slots, offsets, widths and recursive
member types remain part of the comparison. The ABI's `PlannedUpgrade.internalType`
changes its declaring-contract name; tuple encoding is unchanged.

Layout checks do not execute a historical upgrade or prove migration behavior.
This PR changes declarations and inheritance; dispatcher and module behavior belong
to later changes with their own integration tests.
