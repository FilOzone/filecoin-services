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
make check-josuke
forge test
make update-abi
```

`make check-josuke` compares the storage every module declares with each deployment
`josuke.json` records, including `legacy`: the v1.4.0 monolith at the commit both
networks run. A variable that moves, changes type or shape, or is overlapped by a
different declaration fails; a rename or a dropped variable warns. It also fails when
two modules declare different variables over the same storage bytes. The ABI's
`PlannedUpgrade.internalType` changes its declaring-contract name; tuple encoding is
unchanged.

Fields are internal so that modules inheriting `FWSSStorage` do not export getters.

Layout checks do not execute a historical upgrade or prove migration behavior.
This PR changes declarations and inheritance; dispatcher and module behavior belong
to later changes with their own integration tests.
