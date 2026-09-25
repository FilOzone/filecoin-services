# ERC-8167 proxy integration

The dispatcher is the unmodified `Proxy.evm` from `wjmelements/erc8167`. It runs
behind the existing FWSS ERC-1967 proxy, so business state stays at the same
address. `implementation(bytes4)` is the upstream `Implementation.evm` delegate.
Josuke generates `selectors()` and the migration bytecode. No administrative
selector is built into the dispatcher.

The dependency is pinned to `44b41a1a94a491b54920ae8dd3c16aa974b6bf09`.
FWSS uses Solidity 0.8.37 with `via_ir` and the explicit `cancun` EVM target.
FEVM supports the `PUSH0`, `MCOPY` and transient-storage opcodes used here; this
does not imply support for Ethereum blob opcodes. No blob features are used.
`forge-std` is pinned to v1.16.2, matching the upstream tests.

## Build

Install the `wjmelements/evm` assembler at commit
`4123f3a47e8032499fc0ddfe178f35c034ae77a7` and put its `bin` directory on `PATH`.
Initialize Git submodules, then run from `service_contracts/`:

```sh
make build test
```

`make erc8167` builds the upstream proxy and introspection artifacts under
`lib/erc8167/out/`. Run it before using `forge test` directly. Solidity builds
disable both the metadata hash and CBOR trailer with `bytecode_hash = "none"`
and `cbor_metadata = false`.

## Josuke

Josuke is pinned to `0c8917f9e4343557025bdecd19c3a303dbbde623`:

```sh
uvx --from git+https://github.com/wjmelements/josuke@0c8917f9e4343557025bdecd19c3a303dbbde623 josuke --help
```

`josuke.mainnet.json` and `josuke.calibnet.json` are the deployment ledgers.
Josuke assumes one proxy address across chains, so each network has its own
ledger. Both use the same `facetSrc`:

- `src/modules/*.sol`: every contract with creation bytecode in this directory
  is a facet. Keep libraries, helpers and abstract bases elsewhere.
- `lib/erc8167/src/Implementation.evm`: upstream `implementation(bytes4)`.

No facet implements `selectors()`; Josuke generates it from the facet set.
Run Josuke from `service_contracts/` with `-f <ledger>`.

Each selector must belong to exactly one facet. `FWSSStorage` fields are
internal, so inheriting modules do not export getters; a shared getter belongs
to one module. Every Josuke command needs an RPC, so `test/JosukeFacets.t.sol`
resolves `facetSrc` offline from build artifacts. It fails on duplicate
selectors and on missing transition routes. The dispatcher tests install the
same facet set.

Current facets:

| Facet | Selectors |
|---|---|
| `MigrateModule` | `announceMigration`, `migrate` |
| `OwnershipModule` | `owner`, `transferOwnership`, `renounceOwnership` |
| `ProviderManagementModule` | `addApprovedProvider`, `removeApprovedProvider` |
| `ViewContractModule` | `viewContractAddress`, `setViewContract` |
| `Implementation.evm` | `implementation` |

The business logic remains only in `FilecoinWarmStorageService`. Do not run
the transition on a live network until the business modules are in
`src/modules/`. Without them, proving, payment callbacks and data set
operations stop working.

## Existing proxy transition

First deploy this intermediate `FilecoinWarmStorageService` release and install
it through the existing delayed UUPS upgrade. Its business logic is unchanged.
The deployed release accepts it because of its `code.length > 3000` check. The
intermediate release relaxes that check to `code.length > 3000 || code.length == 88`.
Provider approval moved to `ProviderManagementModule`, so it is unavailable
between this upgrade and the transition.

Deploy the blank upstream dispatcher and check its runtime hash:
`0x108d179021d554c7ad078adb0e30b9afbe6e022acfcd59ac878b2b684f29550a`.

The FWSS proxy cannot serve as the ledger address for the first
`josuke deploy`. Its fallback reads the ERC-1967 implementation slot before any
selector slot. For the first deploy, the ledger `address` is the blank
dispatcher. Josuke then finds the selector slots, which are the same in the FWSS
proxy's storage. Review `josuke verify`, then the proxy owner calls:

```solidity
service.announceDispatcherUpgrade(dispatcher, migration, delayEpochs);
// Wait until StateView.nextUpgrade().afterEpoch.
service.upgradeToAndCall(dispatcher, "");
```

Both addresses are bound to the announcement, with a minimum delay of one block.
The dispatcher address and epoch use the existing packed `nextUpgrade` slot. The
migration address uses the ERC-7201 namespace `filecoin.storage.DispatcherMigration`.
`DispatcherUpgradeAnnounced` records both addresses and the execution epoch.

There is one pending plan. Either kind of announcement replaces the previous
one. An ordinary UUPS announcement clears the pending dispatcher migration, and
an attempt to execute an ordinary UUPS target rejects an active dispatcher plan.
`upgradeToAndCall(dispatcher, "")` consumes the stored migration address and
requires empty calldata and zero FIL. It runs the migration before switching the
implementation, because an empty selector map cannot dispatch an initializer
afterwards. It then requires deployed delegates for `implementation`,
`selectors`, `announceMigration` and `migrate`. Any revert restores the plan,
route writes and implementation.

The OpenZeppelin UUPS path calls `proxiableUUID()` on the candidate, which the
blank dispatcher does not route. The intermediate release therefore overrides
`upgradeToAndCall` for an announced dispatcher migration and checks the runtime
hash at announcement and execution. Updating the upstream proxy bytecode
requires updating `DISPATCHER_CODE_HASH`. An ordinary
`announceUpgradePlan(dispatcher, delay)` passes the size check but cannot
execute the transition.

After the transition, set the ledger `address` to the FWSS proxy and run
`josuke accept`. The old monolith is not a facet: its legacy `migrate(address)`
sets StateView and shares a selector with `MigrateModule.migrate`.

`josuke accept`, `verify` and later `deploy` runs against the FWSS proxy need
[Josuke #3](https://github.com/wjmelements/josuke/issues/3). Until then they
read the ERC-1967 implementation slot as every selector's route.

## Later migrations

`MigrateModule` is FWSS code, not part of Josuke. Josuke generates and verifies
migration bytecode and records the `DiamondDelegateCall` event, but leaves
authorization to the proxy. The upstream `Migrate.evm` fixes its deployer as
owner, with no delay. FWSS keeps its transferable OpenZeppelin owner and the
existing announcement delay.

The current owner announces the generated migration with
`announceMigration(address,uint96)`, waits at least one block, then calls
`migrate(address)`. Zero requested delay means one block. A new announcement
replaces the pending one. The module clears the pending plan before
delegatecall; a failure restores both the plan and all migration writes. It emits
`DiamondDelegateCall(address,bytes)` with empty delegate calldata for Josuke.

The existing packed `nextUpgrade` slot and `UpgradeAnnounced` event are reused.
After the transition, the address in `StateView.nextUpgrade()` identifies a
migration contract, not a replacement ERC-1967 implementation. Existing
deployment scripts still target the old UUPS API.

Migration bytecode is privileged code. Run `josuke verify` before announcing it.
The on-chain checks do not prove business coverage, storage safety, or correct
selectors in arbitrary code.

See [PR #615](https://github.com/FilOzone/filecoin-services/pull/615),
[Will's first-migration procedure](https://github.com/FilOzone/filecoin-services/pull/615#discussion_r4082439880),
[Josuke #3](https://github.com/wjmelements/josuke/issues/3), and
[Josuke #4](https://github.com/wjmelements/josuke/pull/4).
