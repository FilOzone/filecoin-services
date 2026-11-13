# Legacy piece metadata cleanup

This tool zeroes the legacy piece metadata that FWSS no longer uses: `dataSetPieceMetadata`, `dataSetPieceMetadataKeys` and `scheduledPieceMetadataRemovals` (FilOzone/filecoin-services#609).
It plans the work off-chain and sends it to the temporary facet `FWSSPieceMetadataCleanupModule.cleanupLegacyPieceMetadata`.
The tool is deleted together with that facet once the state is gone.

The facet cannot detect residue.
If the tool has a wrong key, value length or key count for a piece, the slots it does not know stay behind and every transaction still succeeds.
So `check` compares each piece with chain storage, and `plan` plans only the pieces that `check` found matching or already clean.
The indexer can also miss a piece entirely, so `discover` reads chain storage for pieces that have metadata and no row.

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

`discover`, `queues`, `check`, `verify` and `send` first require that the node serves the network's chain id and that the FWSS proxy address has code there.
A node of another network answers every storage read with zero, which would read as "all clean".

| Command | Does | Proves | Does not prove |
|---|---|---|---|
| `fetch` | Copies legacy pieces with metadata from the indexer, and the largest legacy piece id of every data set; rerunning upserts, keeps a check result while the metadata is unchanged, and keeps rows the indexer does not return | Nothing about chain state | That the indexer is right |
| `discover [--tail N]` | Reads the keys length slot of every piece id without a row, up to the data set's largest legacy id plus N (default 64), in every data set id below PDPVerifier's next id; recovers the metadata of each hit from storage and stores it like `fetch` | Which of those pieces had metadata when it ran | Pieces past the tail; pieces whose values outlived their key array, which FWSS never did before the upgrade |
| `check --sample N \| --all` | Reads each piece's keys length slot, key element slots and value head slots and compares them with the indexer row | A `match` piece has exactly the stored key count, keys and value lengths, so its plan clears all of it; a `clean` piece had none of those slots set when it was read | The value data slots and the data slot of a 32-byte key, which it does not read; the plan takes their count from the value length and the key length |
| `queues` | Refuses unless the proxy routes `cleanupLegacyPieceMetadata`; then reads the legacy queue length of every data set id below PDPVerifier's next id | Which queues are non-empty at that moment | That the queues stay as read; they do once the facet is installed, because the upgrade stops FWSS using them |
| `plan` | Builds ops for `match` and `clean` pieces and every stored queue, sorts them by slot, cuts batches | Bounds: a piece the facet cannot clear is listed as `invalid` and never planned | Anything about storage |
| `send` | Sends the batches that are not done, in order, under a price ceiling | Each batch succeeded on chain when its receipt was read | That anything was cleared: the facet zeroes whatever slots it is given |
| `verify --sample N \| --all \| --done` | Reads every slot the plan zeroes and every planned queue length, or with `--done` those of the batches recorded as done; exits 1 if one is not zero | The planned slots are zero | Slots the plan never had; `check` covers those |

`check` compares the key elements as a set with repeats, because the chain keeps keys in insertion order and the indexer does not record it.
The element of a 32-byte key holds only its length, so the key's bytes are proven by its value head.
A wrong 32-byte key with an empty value therefore reads as `match`, and the value of the real key stays behind.
`check` runs only before anything is sent.
After a partial send the ops of one piece are partly executed, so the piece would read as `mismatch` although the plan still holds the ops that finish it.
`check` and `plan` refuse to run on a state file from which a message was ever sent.
`check` prints the first mismatches, and `check --report <file>` writes all of them as TSV (data set id, piece id, what differed).

`discover` stores each hit with the status `fetch` would give it: `unchecked`, or `invalid` with the reason.
A hit that metadata cannot hold is stored as `invalid` with a reason that starts with `discover:`: more than 5 keys, a key or value that is not UTF-8, a long string outside the legacy bounds, or a key that appears twice.
It prints the discovered pieces, and `discover --report <file>` writes all of them as TSV (data set id, piece id, status, keys, detail).
Like `check`, it is valid only before anything is sent, and it refuses afterwards.
It also refuses before `fetch` has stored the id ranges.

`plan` leaves out `mismatch` and `invalid` pieces, and `plan --report <file>` writes them as TSV.
`plan` includes `clean` pieces: zeroing a zero slot is harmless, and it means `verify` reads their slots too, in case a reorg undid what `check` saw.
`plan` refuses to run while a piece is `unchecked` and prints how many there are.
`plan --allow-unchecked` plans them anyway and prints how many it planned without a check.
`plan` builds the new plan in one SQLite transaction, so a crash keeps the earlier plan.

## Ops

`plan` encodes ops in the facet's packed format; the natspec of `cleanupLegacyPieceMetadata` is the reference.
Every op starts with a 1-byte kind and a 3-byte data set id.
Metadata ops follow with a 3-byte piece id: KeysLength is 7 bytes, KeyHead and KeyData 8, ValueHead 8 plus the key, ValueData 9 plus the key.
PopQueue follows with a 2-byte count and is 6 bytes.

Data set and piece ids must fit in 24 bits.
`fetch` stores a piece with a larger id as `invalid`, and `plan` fails on a queue of a data set with a larger id; the tool never truncates an id.

Keys of 1 to 32 UTF-8 bytes are planned.
A 32-byte key is a long Solidity string: its key element holds the length, and its bytes sit in one data slot that a KeyData op zeroes.
The indexer does not record the key order, so a piece with a 32-byte key gets a KeyData op at every index of its key array.
Zeroing the unused data slot of a short key is harmless.

A PopQueue op zeroes up to `count` entries at the end of a queue and then writes the queue length once, so N entries cost N + 1 slot writes.
`plan` pops at most `--max-ops` entries per op, and each popped entry counts as one op of the batch budget.

`verify --requeue` puts every batch that still has a non-zero slot back to `planned`.
For a queue that is not empty it puts back every batch that pops that queue.
It acts only on what it read, so with `--sample` it puts back the batches of the sampled ops and of the queues.
`verify` exits 1 when it found residue, with and without `--requeue`.
`verify --report <file>` writes the residue as TSV.
`verify` refuses to run on a state file without a plan.
`verify --done` reads every slot of the batches recorded as done, and the length of every planned queue all of whose batches are done.
It refuses while no batch is done.
The facet zeroes whatever slots it is given, so a clean `verify --done` after a pilot also proves that the proxy routes the selector to a facet that zeroes these slots.

`check` needs exactly one of `--sample` and `--all`, and `verify` exactly one of `--sample`, `--all` and `--done`.

## Run order

Before the upgrade that adds the facet, because `discover` relies on how the deployed FWSS writes metadata:

1. `fetch`.
2. `discover --report discovered.tsv`.
3. `check --all --report mismatches.tsv`.
   It is slow and resumable: a rerun skips pieces already checked, so it can run days ahead.

Gate before `plan`: `check` reports zero `unchecked` pieces, and someone has explained every `mismatch` and `invalid` piece (`plan --report` lists them).
`plan` leaves those pieces out, and `verify` never reads their slots, so whatever they hold stays.
To fix a wrong row, correct its `metadata` in the state file, set its status to `unchecked`, and run `check --all` again, which checks only `unchecked` rows.

After the upgrade, because the queue lengths only stop changing then (`queues` refuses before it):

1. `queues`.
2. `plan`.
   It prints how many queue batches come first.
3. `send --dry-run --max-batches 10`.
4. Pilot: `send --max-gas-price <attoFIL> --max-batches <queue batches + 10>`, so that it runs metadata batches too.
5. `verify --done` must exit 0 before the full run.
   It proves that the pilot's batches zeroed every slot they planned and emptied the queues, on the real proxy.
6. `send --max-gas-price <attoFIL>`.
7. `verify --all`, after the last batch is final.
   Filecoin finality is 900 epochs, 7.5 hours.
   `verify --sample N` gives a quicker look in between.

## Second pass

The only second pass is `verify --all --requeue`, then `send --max-gas-price <attoFIL>`.
After each such `send`, wait for finality again, then run `verify --all`.
Repeat until `verify --all` exits 0.

`send` records a batch as done when it reads a successful receipt.
A reorg can remove that message afterwards, and the batch then stays recorded as done without having run.
`verify --requeue` after finality finds its slots and puts the batch back, and `send` sends it again.

`discover`, `check` and `plan` are not part of recovery, and all three refuse once a message was sent.

Keep a copy of the state file from before the first `send`: it holds the check results.
The state file is in WAL mode, so copy it with `sqlite3 <file> ".backup <copy>"` while no command runs, not with `cp`.
If the state file is lost during `send`, restore that copy and run `queues`, `plan` and `send` again; this sends everything again.
Without a copy, a fresh `check` reads the partly cleaned pieces as `mismatch`, so the only way is a new state file with `fetch`, `queues`, `plan --allow-unchecked`, `send`, without the proof that `check` gives.

## Sending and resume

`send` estimates each batch with `eth_estimateGas` and sets the gas limit to the estimate times `--gas-multiplier`.
Lotus's estimate is already about 1.25 times the gas a batch uses, so the default multiplier of 1 is enough.
At most `--max-inflight` messages (at most 4) are unconfirmed at a time, with nonces the tool assigns.
On the devnet four batches of the default size landed in one block and used about 3B gas, under the block gas target of 5B, above which the base fee rises.

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

Where you can, send and read through one node that is not behind a load balancer.
The resume logic reads nonces and receipts from the node it sends to, and a node that lags behind another one can make a batch look unsent.
The cost of that is batches sent twice, not residue.

The run stops at the first failure: a revert in `eth_estimateGas`, a rejected send, a reverted receipt, or no receipt within `--receipt-timeout`.
It then waits for the messages already sent, records them, prints the batch id and the revert data, and exits 1.
A reverted batch is retried on the next run.
`send` exits 1 when the state file has no batches at all.

`--max-batches N` stops after N batches.
`--dry-run` only estimates; estimates ignore the batches before them.
The summary shows the batches done, the gas used and the FIL spent, from the receipts.

## Tuning

- `plan --max-calldata-bytes` (default 60000): Lotus rejects messages over 65,536 bytes; on the devnet it accepted 65,348 bytes of calldata and rejected 65,412.
- `plan --max-ops` (default 1500): each popped queue entry counts as one op.
  On the devnet a batch of 1500 ops used about 0.76B gas; mainnet has a much larger storage tree, so expect more there.
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
- `discover`: about 1.06M candidates without the tail; at 390 reads/s, about 45 minutes.

An independent full run of this cleanup on a local node with mainnet state (`Kubuxu/fvm-anvil`, `benchmarks/fwss/metadata-cleanup.md`), with an older facet and messages of up to 1,024 ops, used about 478k gas per zeroed slot and about 598k gas per op.
That is the author's measurement, not ours; it suggests about 0.9B gas for a batch of 1500 ops on mainnet.

## Devnet rehearsal

On 12.11.2026 the tool's library code ran the whole procedure against a local Lotus 1.38.3 devnet (network version 29, 4-second epochs), on the test harness with 5,539 seeded pieces and three queues: 19 batches, 23,480 ops, 29,290 slots.
`verify` found no residue, and a read of the value slots through the harness's own views found none either.
The rehearsal ran on the earlier op format and facet (base commit `2081265`), and the numbers below were not measured again.
That facet took 5-byte ids and called `queue.pop()` once per popped entry, which wrote the queue length each time.
An op is now 4 bytes shorter (PopQueue 2 bytes shorter), and a PopQueue op writes the queue length once.

- Gas per batch of 1500 metadata ops: 757M median, 773M max; about 505k gas per op and 405k per zeroed slot.
- Queue pops: about 404k gas per popped entry.
- A batch sent again as a no-op used about 472M gas, against 760M the first time.
- The gas limit was 1.25 to 1.27 times the gas used in every batch.
- Every receipt was found by the hash recorded before the broadcast, also for the two messages in flight when `send` was killed.
- The price ceiling held the run while the base fee plus the priority fee was above it.
- Lotus accepted 12 consecutive nonces from one sender, so 4 in flight is a choice, not the node's limit.

The devnet contract held about 32,000 slots and mainnet holds about 24M, so these gas numbers are a lower bound for mainnet.

## Not verified

- `discover` on a real network: it has run only on anvil.
- Gas per batch on a storage tree of mainnet's size: the pilot on mainnet measures it.
- A dropped message, a reverted batch, a receipt timeout and a reorg on a real node; the anvil tests cover these paths.
- The mempool rules and rate limits of the public RPC nodes for sending.
- `verify --all` after finality on a real network.

The calibnet rehearsal covers the last three before mainnet.

## Tests

- `npm test`: unit tests; no network.
- `npm run typecheck`.
- `npm run test:e2e`: needs `anvil` on PATH and `forge build` output in `service_contracts/out`.
  It deploys `test/helpers/FWSSPieceMetadataCleanupHarness.sol` to a local anvil and seeds legacy metadata through Solidity.
  One run goes through `discover` (three pieces the tool's table lacks), `check`, `queues`, `plan`, a pilot checked with `verify --done`, `send` (with a price ceiling hold and an interrupted run) and `verify`.
  Another stores hits that metadata cannot hold as `invalid`.
  Another sends part of a plan, records two batches as done that never ran, and finishes with `verify --requeue` and `send`.
  A third loses messages before broadcast and lets one land late.
  Each then dumps the contract's storage from anvil and requires exactly the expected non-legacy slots, without the tool's slot formulas.
