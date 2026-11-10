# Legacy piece metadata cleanup

This tool zeroes the legacy piece metadata that FWSS no longer uses: `dataSetPieceMetadata`, `dataSetPieceMetadataKeys` and `scheduledPieceMetadataRemovals` (FilOzone/filecoin-services#609).
It plans the work off-chain and sends it to the temporary facet `FWSSPieceMetadataCleanupModule.cleanupLegacyPieceMetadata`.
The tool is deleted together with that facet once the state is gone.

The facet cannot detect residue.
If the tool has a wrong key, value length or key count for a piece, the slots it does not know stay behind and every transaction still succeeds.
So the tool checks each piece against chain storage before it plans it.

## Prerequisites

- Node.js 24.12 or later (runs TypeScript directly and uses the built-in `node:sqlite`).
- `npm ci` in this directory.
- Read access to the FilOzone indexer Postgres for `fetch`.
- A JSON-RPC endpoint; the default is the public Glif endpoint of the network.
- For `send`: a funded key whose nonce nothing else uses during the run.

## Environment variables

- `DATABASE_URL`, or the standard `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`: the indexer, for `fetch` only.
- `CLEANUP_PRIVATE_KEY`: the signing key, read by `send` only.
  The tool never logs or stores it.
  `send --dry-run --from <address>` runs without it.

## Commands

All commands take `--network mainnet|calibnet` and keep their state in one SQLite file (`--db`, default `cleanup-<network>.sqlite`).
The FWSS proxy address comes from `service_contracts/deployments.json`.
Run `npm run cli -- --help` for every option.

| Command | Does | Proves | Does not prove |
|---|---|---|---|
| `fetch` | Copies legacy pieces with metadata from the indexer; rerunning upserts | Nothing about chain state | That the indexer is right |
| `check --sample N \| --all` | Reads each piece's keys length slot and value head slots and compares them with the indexer row | A `match` piece has exactly the stored key count, keys and value lengths, so its plan clears all of it | Anything about key element slots and value data slots, which follow from the same keys and lengths |
| `queues` | Reads the legacy queue length of every data set id below PDPVerifier's next id | Which queues are non-empty at that moment | Their lengths later: the deployed FWSS keeps popping them until the upgrade |
| `plan` | Builds ops for `unchecked` and `match` pieces and every stored queue, sorts them by slot, cuts batches | Bounds: a piece the facet cannot clear is listed as `invalid` and never planned | Anything about storage |
| `send` | Sends the batches that are not done, in order | Each batch succeeded on chain | That anything was cleared: the facet zeroes whatever slots it is given |
| `verify --sample N \| --all` | Reads every slot the plan zeroes and every planned queue length; exits 1 if one is not zero | The planned slots are zero | Slots the plan never had; `check` covers those |

`plan` leaves out `clean` pieces (storage already empty), `mismatch` pieces and `invalid` pieces, and `--report <file>` writes the excluded ones as TSV.
`verify --report <file>` writes the residue as TSV.

## Run order

Before the upgrade that adds the facet:

1. `fetch`.
2. `check --all`.
   It is slow and resumable: a rerun skips pieces already checked, so it can run days ahead.
   Look at every `mismatch` before going on.

After the upgrade, because the queue lengths only stop changing then:

1. `queues`.
2. `plan` (pass `--force` only to replan after batches were sent; it forgets the send records).
3. `send --dry-run --max-batches 10`, then a pilot `send --max-batches 10`, then `send`.
4. `verify --all`, or `verify --sample N` for a quicker look.

## Sending and resume

`send` estimates each batch with `eth_estimateGas` and sets the gas limit to the estimate times `--gas-multiplier`.
Fees are EIP-1559 from the node: the latest base fee times 2 plus `eth_maxPriorityFeePerGas`.
At most `--max-inflight` messages (at most 4, the Filecoin mempool's nonce gap) are unconfirmed at a time, with nonces the tool assigns.

The tool records each message's hash in the state file before it broadcasts it.
A rerun first looks up the receipt of every batch recorded as sent, and waits until no message from the sender is pending.
A batch with a successful receipt is done; a batch whose message never landed goes back to planned.
Only then does it send what is not done, with the nonce from the chain.

Sending a batch twice is safe, because every op zeroes a fixed slot or pops what is left of a queue.
The cost is the gas of the second message.
That happens when a message lands after the tool decided it was dropped, or when the node cannot find receipts by hash.
In the worst case each restart pays twice for up to `--max-inflight` batches.

The run stops at the first failure: a revert in `eth_estimateGas`, a rejected send, a reverted receipt, or no receipt within `--receipt-timeout`.
It then waits for the messages already sent, records them, prints the batch id and the revert data, and exits 1.
A reverted batch is retried on the next run.

`--max-base-fee <attoFIL>` holds new messages while the base fee is above it.
`--max-batches N` stops after N batches.
`--dry-run` only estimates; estimates ignore the batches before them.
The summary shows the batches done, the gas used and the FIL spent, from the receipts.

## Tuning

- `plan --max-calldata-bytes` (default 60000): Filecoin rejects messages over about 64 KiB, and the envelope overhead is not measured.
- `plan --max-ops` (default 1500, about 0.9B gas): each queue pop counts as one op.
- `--read-batch-size`, `--read-concurrency`, `--requests-per-second`: storage reads, as `eth_getStorageAt` in JSON-RPC batches.
- `send --gas-multiplier`, `--max-inflight`, `--poll-interval`, `--receipt-timeout`.

## Measured and estimated durations

Measured on 10.11.2026 against the public Glif calibnet RPC: `check --all` of 324,626 calibnet pieces ran at about 225 pieces/s, about 390 storage reads/s.

Estimates for mainnet, assuming the same read rate on the mainnet Glif RPC:

- `check --all`: about 9.1M reads for 4.53M pieces, about 6.5 hours.
- `verify --all`: about 22.7M slots, about 16 hours; it does not resume, so use `--sample` for interim looks.
- `send`: about 12,100 batches at the default limits; at 4 messages per one or two 30-second epochs, about 25 to 50 hours.

## Not verified

The facet is not deployed on any network, so nothing here has run against a real Filecoin node.
Unchecked on a real node: the message size limit, nonce gaps and mempool replacement, fee estimation, FVM gas per batch, and finding transactions and receipts by the Ethereum hash the tool computes.
The calibnet rehearsal must cover these before mainnet.

## Tests

- `npm test`: unit tests; no network.
- `npm run typecheck`.
- `npm run test:e2e`: needs `anvil` on PATH and `forge build` output in `service_contracts/out`.
  It deploys `test/helpers/FWSSPieceMetadataCleanupHarness.sol` to a local anvil, seeds legacy metadata through Solidity, runs `check`, `queues`, `plan`, `send` (with an interrupted run, a lost message and a base fee hold) and `verify`.
  It then dumps the contract's storage from anvil and requires exactly the expected non-legacy slots, without the tool's slot formulas.
