# ERC-8167 proxy integration

The dispatcher is the unmodified `Proxy.evm` from `wjmelements/erc8167`.
`implementation(bytes4)` is a separate upstream delegate. Josuke supplies
`selectors()` and migration bytecode. No administrative selector is built into
the dispatcher.

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

`make erc8167` builds the upstream proxy and introspection
artifacts under `lib/erc8167/out/`. Run it before using `forge test` directly.
The upstream ABI build uses the project's configured Solidity version.
Solidity builds disable both the metadata hash and CBOR trailer with
`bytecode_hash = "none"` and `cbor_metadata = false`.

## Existing proxy transition

First deploy this intermediate `FilecoinWarmStorageService` release and install
it through the existing delayed UUPS upgrade. Its constructor and business logic
are unchanged. The monolith naturally satisfies the already-deployed release's
`code.length > 3000` check. This intermediate release changes that condition to
`code.length > 3000 || code.length == 88`. There is no separate conversion contract or
bytecode padding.

For the first `josuke deploy`, point the ledger at the blank upstream dispatcher.
This lets Josuke find selector-storage slots before the existing FWSS proxy uses
them. Review the generated migration and complete facet set. The existing proxy's
owner then calls:

```solidity
service.announceDispatcherUpgrade(dispatcher, migration, delayEpochs);
// Wait until StateView.nextUpgrade().afterEpoch.
service.upgradeToAndCall(dispatcher, "");
```

Both addresses are bound to the announcement, with a minimum delay of one block.
The dispatcher address and epoch use the existing packed `nextUpgrade` slot. The
migration address uses the ERC-7201 namespace `filecoin.storage.DispatcherMigration`,
accessed through OpenZeppelin `StorageSlot`; no legacy business slots move.
`DispatcherUpgradeAnnounced` records both addresses and the execution epoch.

There is one pending plan. Either kind of announcement replaces the previous
one. An ordinary UUPS announcement clears the pending dispatcher migration, and
an attempt to execute an ordinary UUPS target rejects an active dispatcher plan.
`upgradeToAndCall(dispatcher, "")` consumes the stored migration address; the
caller cannot replace it with different calldata. The transition
consumes the plan before delegatecalling the migration. It requires deployed
delegates for `implementation`, `selectors`, `announceMigration` and `migrate`,
then switches the ERC-1967 implementation to the dispatcher. Any revert restores
the whole plan, route writes and implementation. Business state stays at the same
proxy address.

After the transition, update `josuke.json` to the existing FWSS proxy address,
verify the installed routes and accept the migration. The monolith is no longer
the active implementation and must not be included as a facet. Its legacy
`migrate(address)` sets StateView; it is not the migration entry point below.

## The 3000-byte gate and UUPS exception

The old size check belongs to implementation code, so it cannot be changed by
writing a storage field in an initializer. The first delayed UUPS upgrade installs
the intermediate release that contains the relaxed check. Direct upgrades from
the old deployed release to the raw dispatcher remain impossible.

Allowing 88 bytes is not enough on its own: OpenZeppelin UUPS also calls
`proxiableUUID()` on the candidate. The blank dispatcher has no such route.
This release overrides `upgradeToAndCall` for an announced dispatcher migration.
Without that migration announcement, it retains OpenZeppelin's UUPS path. The runtime hash is
`0x108d179021d554c7ad078adb0e30b9afbe6e022acfcd59ac878b2b684f29550a`.
Both the dispatcher announcement and execution check that hash. Updating the
upstream proxy bytecode requires reviewing and updating this constant too.

Use `announceDispatcherUpgrade` for the final transition. An ordinary
`announceUpgradePlan(dispatcher, delay)` passes the new size check but does not
bind a migration and cannot execute the transition. Dispatcher execution requires
empty calldata and zero FIL; the migration comes from the delayed announcement.
The generated migration runs before the implementation changes, because an empty
selector map cannot dispatch an initializer after the switch.

There is no new initializer or constructor argument. Moving an arbitrary migration
address into first-upgrade initializer calldata would stop binding the migration
to the announcement delay. The paired announcement is retained for that reason.
The separate `upgradeToDispatcher` execution method is removed. An invalid target
reverts with `InvalidDispatcherTarget()`; nonempty dispatcher calldata is rejected
before the migration executes.

## Later migrations

Include `MigrateModule` once in Josuke's facet list. It imports `LibAccessControl`
from PR #611 and exports only `announceMigration(address,uint96)` and
`migrate(address)`. It implements the upstream `Migrate` interface and does not
inherit business storage or ownership getters.

The current owner announces the generated migration address, waits at least one
block, then calls `migrate(address)`. Zero requested delay means one block. A new
announcement replaces the pending one. The module clears the pending plan before
delegatecall; a failure restores both the plan and all migration writes. It emits
`DiamondDelegateCall(address,bytes)` with empty delegate calldata for Josuke.

The existing packed `nextUpgrade` slot and `UpgradeAnnounced` event are reused.
After transition, the address in `StateView.nextUpgrade()` identifies a migration
contract, not a replacement ERC-1967 implementation. Callers must account for
this change. Existing deployment scripts still target the old UUPS API.

Migration bytecode is privileged code. Josuke verification and acceptance of the
complete facet set remain required before execution. The on-chain checks do not
prove business coverage, storage safety, or correct selectors in arbitrary code.

## Integration requirements

- Josuke issue #3 must support selector-storage detection behind the outer
  ERC-1967 proxy. There is no local workaround.
- Use a Josuke revision containing PR #4, which removes selectors deleted from
  retained facets.
- Finish the business and admin facets separately. In particular, route ownership,
  StateView discovery and `extsload` methods once, and preserve module constructor
  dependencies. `FWSSStorage` currently exposes `viewContractAddress()` from every
  inheriting facet; resolve that duplication in the shared module work.
- Test the complete generated migration against the exact deployed monolith,
  populated datasets and payment rails, then exercise proof, settlement and
  retrieval after the upgrade. Tests using this source's monolith and routing
  fixtures do not replace that release gate.
- Standard contract-size checks cover the intermediate monolith and MigrateModule.
  The assembler output is checked separately in the proxy tests.

The proxy tests use upstream `SetDelegateOperation[]`, duplicate-selector
validation and `Migration.createMigration` for route installation. `AbiCheats`
checks the installed module routes against the compiled ABIs, excluding the
shared `viewContractAddress()` getter until its owner is assigned.
An intentionally reverting fixture verifies rollback. Transition tests use the
monolith and its existing UUPS and delay checks without padding or a relaxed shell.

See [PR #615](https://github.com/FilOzone/filecoin-services/pull/615),
[Will's first-migration procedure](https://github.com/FilOzone/filecoin-services/pull/615#discussion_r4082439880),
[Josuke #3](https://github.com/wjmelements/josuke/issues/3), and
[Josuke #4](https://github.com/wjmelements/josuke/pull/4).
