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

## Storage terms

`DataSetInfo.storageTermsId` is appended at relative slot 11. Existing datasets
read zero, the canonical legacy terms ID. No legacy root slot moves.

The catalogue is a mapping from `bytes32` IDs to `StorageTermsRecord` in the
ERC-7201 namespace `filecoin.FWSS.StorageTerms`, rooted at
`0xffe2107a587f9a58b0aaa87110a43c1dc6de9e3d39b63f9be37b80538b60ff00`.
Each mapping entry occupies three slots:

| Relative slot | Contents (byte offsets from least-significant byte) |
|---|---|
| 0 | `address token` 0–19; `uint8 tokenDecimals` 20; `uint8 version` 21; `bool enabled` 22; unused 23–31 |
| 1 | `bytes32 salt` |
| 2 | `uint96 pricePerTiBPerMonth` 0–11; unused 12–31 |

Unused bytes are not declared as reserved fields. Future fields may occupy them
only if existing offsets and widths remain unchanged. Version zero means
unregistered; current registered definitions have version one.

Fresh proxy initialization writes record zero using the legacy currency passed in
`initialize` calldata. An upgrade from the already-modular system uses
`FWSSStorageTermsMigration` to install routes and initialize that record atomically.
Initialization is idempotent and never re-enables a disabled record.


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

Layout checks do not execute an upgrade or prove migration behavior. The dispatcher
tests exercise the storage-terms migration through the pre-feature modular upgrade
entry point; view tests separately verify legacy array decoding and V2 term IDs.
