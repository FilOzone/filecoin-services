# Legacy piece metadata cleanup

This tool zeroes the legacy piece metadata that FWSS no longer uses: `dataSetPieceMetadata`, `dataSetPieceMetadataKeys` and `scheduledPieceMetadataRemovals` (FilOzone/filecoin-services#609).
It plans the work off-chain and sends it to the temporary facet `FWSSPieceMetadataCleanupModule.cleanupLegacyPieceMetadata`.
The tool is deleted together with that facet once the state is gone.

The facet cannot detect residue.
If the tool has a wrong key, value length or key count for a piece, the slots it does not know stay behind and every transaction still succeeds.
So `check` compares each piece with chain storage, and `plan` plans only the pieces that `check` found matching.

## Prerequisites

- Node.js 24.12 or later (runs TypeScript directly and uses the built-in `node:sqlite`).
- `npm ci` in this directory.
- Read access to the FilOzone indexer Postgres for `fetch`.
- A JSON-RPC endpoint; the default is the public Glif endpoint of the network.
- For `send`: a key whose nonce nothing else uses during the run, funded with the budget of the run and no more.

## Environment variables

- `DATABASE_URL`, or the standard `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`: the indexer, for `fetch` only.
- `CLEANUP_PRIVATE_KEY`: the signing key, read by `send` only.
  The tool never logs or stores it.
  `send --dry-run --from <address>` runs without it.

## Commands

All commands take `--network mainnet|calibnet` and keep their state in one SQLite file (`--db`, default `cleanup-<network>.sqlite`).
The FWSS proxy address comes from `service_contracts/deployments.json`.
Run `npm run cli -- --help` for every option.

`queues`, `check`, `verify` and `send` first require that the node serves the network's chain id and that the FWSS proxy address has code there.
A node of another network answers every storage read with zero, which would read as "all clean".

| Command | Does | Proves | Does not prove |
|---|---|---|---|
| `fetch` | Copies legacy pieces with metadata from the indexer; rerunning upserts and keeps a check result while the metadata is unchanged | Nothing about chain state | That the indexer is right |
| `check --sample N \| --all` | Reads each piece's keys length slot, key element slots and value head slots and compares them with the indexer row | A `match` piece has exactly the stored key count, keys and value lengths, so its plan clears all of it; a `clean` piece has no slot set, value data slots included | The value data of a `match` piece; the plan takes their count from the value length in the head |
| `queues` | Reads the legacy queue length of every data set id below PDPVerifier's next id | Which queues are non-empty at that moment | Their lengths later: the deployed FWSS keeps popping them until the upgrade |
| `plan` | Builds ops for `match` pieces and every stored queue, sorts them by slot, cuts batches | Bounds: a piece the facet cannot clear is listed as `invalid` and never planned | Anything about storage |
| `send` | Sends the batches that are not done, in order, under a price ceiling | Each batch succeeded on chain when its receipt was read | That anything was cleared: the facet zeroes whatever slots it is given |
| `verify --sample N \| --all` | Reads every slot the plan zeroes and every planned queue length; exits 1 if one is not zero | The planned slots are zero | Slots the plan never had; `check` covers those |

`check` compares the key elements as a set with repeats, because the chain keeps keys in insertion order and the indexer does not record it.
`check` runs only before anything is sent.
After a partial send the ops of one piece are partly executed, so the piece would read as `mismatch` although the plan still holds the ops that finish it.
`check` refuses to run on a state file from which a message was ever sent, also after `plan --force`.
`check` prints the first mismatches, and `check --report <file>` writes all of them as TSV (data set id, piece id, what differed).

`plan` leaves out `clean` pieces (storage already empty), `mismatch` pieces and `invalid` pieces, and `plan --report <file>` writes the `mismatch` and `invalid` ones as TSV.
`plan` refuses to run while a piece is `unchecked` and prints how many there are.
`plan --allow-unchecked` plans them anyway and prints how many it planned without a check.
`plan` builds the new plan in one SQLite transaction, so a crash keeps the earlier plan.

`verify --requeue` puts every batch that still has a non-zero slot back to `planned`.
For a queue that is not empty it puts back every batch that pops that queue.
It acts only on what it read, so with `--sample` it puts back the batches of the sampled ops and of the queues.
`verify` exits 1 when it found residue, with and without `--requeue`.
`verify --report <file>` writes the residue as TSV.
`verify` refuses to run on a state file without a plan.

`--sample` and `--all` exclude each other, and `check` and `verify` need one of them.

## Run order

Before the upgrade that adds the facet:

1. `fetch`.
2. `check --all --report mismatches.tsv`.
   It is slow and resumable: a rerun skips pieces already checked, so it can run days ahead.
   Look at every `mismatch` before going on.

After the upgrade, because the queue lengths only stop changing then:

1. `queues`.
2. `plan`.
3. `send --dry-run --max-batches 10`, then a pilot `send --max-gas-price <attoFIL> --max-batches 10`, then `send --max-gas-price <attoFIL>`.
4. `verify --all`, after the last batch is final.
   Filecoin finality is 900 epochs, 7.5 hours.
   `verify --sample N` gives a quicker look in between.

## Second pass

`verify --requeue`, then `send`, is the only second pass.
Repeat the two until `verify --all` exits 0.

`send` records a batch as done when it reads a successful receipt.
A reorg can remove that message afterwards, and the batch then stays recorded as done without having run.
`verify --requeue` after finality finds its slots and puts the batch back, and `send` sends it again.

Do not use `check` or `plan --force` to recover.
`plan --force` after sending started builds a new plan from the check results taken before sending: it sends everything again and deletes the records of what was spent.

Keep a copy of the state file from before the first `send`: it holds the check results.
If the state file is lost during `send`, restore that copy and run `queues`, `plan` and `send` again; this sends everything again.
Without a copy, a fresh `check` reads the partly cleaned pieces as `mismatch`, so the only way is `fetch`, `queues`, `plan --allow-unchecked`, `send`, without the proof that `check` gives.

## Sending and resume

`send` estimates each batch with `eth_estimateGas` and sets the gas limit to the estimate times `--gas-multiplier`.
At most `--max-inflight` messages (at most 4, the Filecoin mempool's nonce gap) are unconfirmed at a time, with nonces the tool assigns.

`--max-gas-price <attoFIL per gas>` is the price ceiling, and `send` requires it unless `--dry-run` is set.
No message leaves while the latest base fee plus the priority fee the node suggests (`eth_maxPriorityFeePerGas`) is above the ceiling; `send` waits and asks again.
Each message is signed with a fee cap of twice the base fee plus the priority fee, or the ceiling if that is lower, and with a priority fee no higher than the fee cap.
So a message pays at most the ceiling times its gas limit, and the run at most the ceiling times the sum of the gas limits.
The ceiling limits the price, not the number of messages: fund the key with the budget of the run only, so that the balance is the limit on the total.
On the public Glif mainnet RPC on 10.11.2026 (block 6533386) the base fee was 100 attoFIL and the suggested priority fee 199,796 attoFIL per gas, so the priority fee is what the ceiling must cover.

The tool records each message's hash in the state file before it broadcasts it.
A rerun first looks up the receipt of every message recorded as sent, and waits until no message from the sender is pending.
A batch with a successful receipt is done; a batch whose message never landed goes back to planned.
A message that was given up as dropped can still land, so a rerun also looks up the receipts of dropped messages whose batch is not done.
Only then does it send what is not done, with the nonce from the chain.

Sending a batch twice is safe, because every op zeroes a fixed slot or pops what is left of a queue.
The cost is the gas of the second message.
That happens when a message lands after the tool sent its batch again, or when the node cannot find receipts by hash.
In the worst case each restart pays twice for up to `--max-inflight` batches.

The run stops at the first failure: a revert in `eth_estimateGas`, a rejected send, a reverted receipt, or no receipt within `--receipt-timeout`.
It then waits for the messages already sent, records them, prints the batch id and the revert data, and exits 1.
A reverted batch is retried on the next run.
`send` exits 1 when the state file has no batches at all.

`--max-batches N` stops after N batches.
`--dry-run` only estimates; estimates ignore the batches before them.
The summary shows the batches done, the gas used and the FIL spent, from the receipts.

## Tuning

- `plan --max-calldata-bytes` (default 60000): Filecoin rejects messages over about 64 KiB, and the envelope overhead is not measured.
- `plan --max-ops` (default 1500, about 0.9B gas): each queue pop counts as one op.
- `--read-batch-size`, `--read-concurrency`, `--requests-per-second`: storage reads, as `eth_getStorageAt` in JSON-RPC batches.
- `send --gas-multiplier`, `--max-inflight`, `--poll-interval`, `--receipt-timeout`.

## Measured and estimated durations

Measured on 10.11.2026 against the public Glif RPCs, with the default read settings:

- mainnet: `check` of 4,487 pieces in 47 s, about 95 pieces/s;
- calibnet: `check` of 3,000 pieces in 17 s, about 170 pieces/s;
- mainnet, plain storage reads: 8,992 in 23 s, about 390 reads/s.

Estimates for mainnet (4,533,224 pieces, about 22.7M slots), from those rates:

- `check --all`: about 13 hours at 95 pieces/s.
- `verify --all`: about 22.7M slots, about 16 hours; it does not resume, so use `--sample` for interim looks.
- `send`: about 12,100 batches at the default limits; at 4 messages per one or two 30-second epochs, about 25 to 50 hours.

## Not verified

The facet is not deployed on any network, so nothing here has run against a real Filecoin node.
Unchecked on a real node: the message size limit, nonce gaps and mempool replacement, fee estimation and the price ceiling against Lotus's priority fee, FVM gas per batch, and finding transactions and receipts by the Ethereum hash the tool computes.
The calibnet rehearsal must cover these before mainnet.

## Tests

- `npm test`: unit tests; no network.
- `npm run typecheck`.
- `npm run test:e2e`: needs `anvil` on PATH and `forge build` output in `service_contracts/out`.
  It deploys `test/helpers/FWSSPieceMetadataCleanupHarness.sol` to a local anvil and seeds legacy metadata through Solidity.
  One run goes through `check`, `queues`, `plan`, `send` (with a price ceiling hold and an interrupted run) and `verify`.
  Another sends part of a plan, records two batches as done that never ran, and finishes with `verify --requeue` and `send`.
  A third loses messages before broadcast and lets one land late.
  Each then dumps the contract's storage from anvil and requires exactly the expected non-legacy slots, without the tool's slot formulas.
