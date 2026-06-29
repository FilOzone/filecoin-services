# FWSS Pricing Rationale

The durable record of the FilecoinWarmStorageService v1.3.0 pricing schedule that shipped with FOC general availability (June 2026): why each fee exists, how it was derived, and how to re-derive it. Resolves [#468](https://github.com/FilOzone/filecoin-services/issues/468); supersedes the pre-GA pricing drafts.

The contract is the source of truth, not this document. List prices are `internal constant` literals in [`PriceListUSDFC.sol`](../service_contracts/src/lib/PriceListUSDFC.sol), and the live schedule is readable on-chain via `FilecoinWarmStorageServiceStateView.getPriceList()`. This doc explains those numbers, it does not define them.

> **Calibration caveat (read first).** An SP pays the *effective gas price* (base fee + priority tip) per gas, not the base fee alone. These fees were sized when that effective price was ~250,000 attoFIL/gas, with the base fee pinned at its ~100 floor so the price was essentially the priority-fee floor. [FIP-0115](https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0115.md) (NV28, mainnet June 2026) changed the base fee calculation and improved its responsiveness to congestion, so as of writing the trailing-30d average has more than doubled to ~540,000 (spiking to ~650,000+). Because the fees are fixed USDFC constants, at the time of writing the design ~10x safety margin has compressed to ~3-5x for the cost-recovery fees. That compression, and the FIL:USDFC assumption (section 3), are the things to watch on recalibration. See sections 4 and 5.

---

## 1. The pricing schedule

FWSS bills in two forms, both in USDFC (18 decimals), both through FilecoinPay rails:

- **Streaming rates** accrue per epoch while data is stored.
- **One-time fees** fire when a lifecycle operation occurs, paid to the SP to reimburse the gas it fronts for that call. They draw from a small pre-funded **lifecycle reserve** on the PDP rail.

| Component | List price | Kind | Paid to | Constant |
|---|---|---|---|---|
| Storage | 2.50 USDFC / TiB / month | streaming | SP | `STORAGE_PRICE_PER_TIB_PER_MONTH` |
| Proving (per data set) | 0.024 USDFC / month | streaming, additive | SP | `DATASET_FEE_PER_MONTH` |
| Create data set | 0.025 USDFC | one-time | SP | `CREATE_DATA_SET_FEE` |
| Add pieces | 0.0005 + 0.0003 x N USDFC | one-time, per call | SP | `ADD_PIECES_BASE_FEE`, `ADD_PIECES_PER_PIECE_FEE` |
| Schedule piece removals | 0.002 USDFC | one-time, per call | SP | `SCHEDULE_PIECE_REMOVALS_FEE` |
| Terminate service | 0.00112 USDFC | one-time | SP | `TERMINATE_FEE` |
| CDN egress | 7 USDFC / TiB | usage (FilBeam) | SP / FilBeam | `CDN_EGRESS_PRICE_PER_TIB`, `CACHE_MISS_EGRESS_PRICE_PER_TIB` |
| Lifecycle reserve | 0.10 target / 0.005 replenish | lockup | refunded | `LIFECYCLE_RESERVE_TARGET`, `REPLENISH_THRESHOLD` |

`N` is the piece count in the `addPieces` call. The reserve is a lockup, not a charge: unused balance returns at rail finalization.

**Not in the schedule (and why):**

- **No sybil fee.** v1.2.x burned 0.1 USDFC per data set via a separate FilecoinPay auction rail; v1.3.0 removes it, folding the anti-spam role into the elevated create fee (section 2).
- **No delete-data-set fee.** Deletion is an SP-side cleanup, not a client charge. The client-facing teardown is covered by the terminate fee together with the create fee; the SP's on-chain cleanup gas is offset separately by recovering its 0.1 FIL PDPVerifier cleanup deposit. *(Earlier drafts listed a 0.00112 delete fee gated on an EIP-712 delete authorization that was since removed from FWSS; there is no `deleteDataSetFee`.)* The case where cleanup gas exceeds the deposit is in section 5.
- **Commission is 0 bps** (`SERVICE_COMMISSION_BPS`): FWSS takes no cut of the streaming rail.

---

## 2. Design rationale, per component

**What the one-time fees protect against:** an SP fronts FIL gas for each lifecycle call (create, add, remove, terminate) on the client's behalf. Without reimbursement it absorbs that cost, under-pricing heavy-lifecycle clients and opening a free DoS on SP gas. The fees pass the gas through to whoever caused it.

**Streaming: storage + proving, additive not floored.** The rate is `naturalRate(bytes) + provingFee`, replacing the old `max(naturalRate, floor)` clamp. Storage scales with TiB; proving gas is flat per data set (5 challenges per period regardless of size), so a per-TiB term plus a fixed per-data-set term fits SP cost better than one clamp. Side effect: empty data sets pay zero, retiring the separate "floor on empty data sets" design.

**Create data set: 0.025, a deliberate over-charge.** Measured `createDataSet` gas is ~500M (~0.0001-0.0003 USDFC as of writing); the 0.025 price is ~90-200x that. Intentional: a soft sybil deterrent replacing the old 0.1 FIL burn at lower magnitude, now paid to the SP (covering its create gas and lifecycle admin, and raising the cost of spamming empty data sets).

**Add pieces: base + per-piece.** Two terms for two gas components: fixed per-call overhead (base) and marginal per piece (calldata plus storage). `0.0005 + 0.0003 x N` tracks SP cost from one piece to a full batch. Batches cap at 41 pieces (the per-event data-size limit, not a contract constant; the repo's `OpFees` tests use `BATCH_CAP = 41`), so `N` is bounded. SDK/Curio apply a conservative 40 in practice.

**Schedule piece removals: 0.002 flat.** Removal gas is awkward: the enqueue emits no event ([FilOzone/pdp#281](https://github.com/FilOzone/pdp/issues/281) proposes adding one) and the delete is processed later inside `nextProvingPeriod`, entangled with proving. A flat 0.002 under-recovers very large batches (`schedulePieceDeletions` is bounded only by PDPVerifier's 2000-deep queue); accepted for simplicity.

**Terminate service: 0.00112, consent path only.** The fee is charged only on the consent-based immediate termination: the SP calls `terminateService` with the payer's signed authorization in `extraData` (the contract requires the caller to be the SP here), which terminates the PDP rail immediately by zeroing its lockup. A no-signature termination (empty `extraData`, callable by either the payer or the SP) takes the non-immediate path and charges nothing. The fee reimburses the SP for processing the consented wind-down. CDN rails persist until data-set deletion rather than being torn down here.

**Lifecycle reserve: how one-time fees are paid.** The PDP rail holds a small fixed-lockup pool (0.10 target, replenished below 0.005), so most ops cost one FilecoinPay interaction. Terminating settles the pending one-time payments; since FilecoinPay forbids raising a terminated rail's lockup, the reserve cannot be refilled afterward, so post-termination wind-down ops draw from whatever remains and a client needing more must pre-fund before terminating. Refunded at finalization if unused.

---

## 3. How the numbers were derived

The listed prices were set in Q2 2026. The methodology, per operation:

1. **Measure gas, no metadata**, from the FWSS gas calculator and early foc-observer queries. Supporting rules: subtract in **gas units, not FIL** (base-fee-independent, so a "combo minus baseline" difference holds across sample times); **isolate FWSS** from other PDPVerifier users (`set_id IN (SELECT data_set_id FROM fwss_data_set_created)`); **derive by difference** where an op never runs alone (`createDataSet` = create+add combo - warm add; `addPieces` per-piece = slope over batch size).
2. **Convert to USDFC:** gas x the prevailing *effective gas price* (`effective_gas_price`, base fee + tip; ~250K attoFIL/gas then) / 1e18, at the stated assumption **FIL = $1** (`usdfc_per_fil = 1.0`; section 5).
3. **x10** for headroom against price spikes, gas drift, and FIL:USDFC moves. Not profit (commission is zero).

Applied at the calibration inputs, this reproduces the listed prices at ~10x. For example a no-metadata N=1 `addPieces` was ~295M gas at ~250K and FIL=$1 -> ~0.00008 USDFC, x10 = 0.0008, i.e. the 0.0005 base plus one piece at 0.0003. The companion [`pricing-measurement.sql`](pricing-measurement.sql) (run against [foc-observer](https://github.com/FilOzone/foc-observer)) holds the queries.

| Op | calibration gas (no meta) | listed | coverage at calibration | realized (as of writing) |
|---|---|---|---|---|
| addPieces, per call (N=1) | ~295M | 0.0008 (base + 1 piece) | ~10x | ~4x no-meta / ~3x with meta |
| addPieces, per added piece | ~120M (estimate; no mainnet batching yet) | 0.0003 | ~10x | ~4x |
| proving / month | ~9.3B (nextProvingPeriod + provePossession, x30) | 0.024 | ~10x | ~4.7x |
| terminateService | gas basis ~0.000112 | 0.00112 | ~10x (nominal) | ~13x |
| createDataSet | ~500M | 0.025 | ~200x (deliberate) | ~92x |

`createDataSet` is the deliberate exception, a sybil deterrent (section 2), never a 10x cost-recovery fee. `terminateService` was set at 10x of an assumed gas basis; its new consent method (measured ~159M post-upgrade) turned out cheaper, so it now over-covers.

**What moved since calibration.** The realized multiple is below 10x because the inputs shifted, not because the calibration was wrong:

- **Effective gas price** is ~540K as of writing, ~2x the ~250K calibration snapshot, and volatile (it ranged ~250K-650K across 2026). FIP-0115 (NV28, June 2026) changed the base-fee mechanism, making it far more responsive to congestion (it had been stuck near its floor rather than tracking load as the design intended). This alone roughly halves every multiple.
- **Gas units** drifted up ~20% from contract-state growth (no-meta N=1 ~295M -> ~357M); affects the gas-measured ops.
- **Metadata** now rides ~99% of adds (~+100M gas at N=1, ~460M total), unpriced by the no-metadata calibration; specific to addPieces.

Realized figures are measured on mainnet after the 2026-06-12 v1.3.0 upgrade (earlier `createDataSet` gas is inflated by the since-removed sybil burn rail). Proving, price-only, sits near ~10x / 2 ~= ~4.7x; addPieces is eroded further by gas drift and metadata to ~3-4x in realistic use. The schedule still over-recovers (>1x); the shrinking headroom is the watch-item (section 5).

---

## 4. Recalibrating in future

Re-derive periodically and after anything touching gas: a protocol upgrade, an FVM gas-model change, or a sustained base-fee shift, and consider updating the pricing schedule to maintain reasonable economics.

**Runbook:** run [`pricing-measurement.sql`](pricing-measurement.sql) against foc-observer (`network: mainnet`). Three variables, re-measure all three:

1. **gas units** drift up ~3-4x over six months from contract-state growth (HAMT/KAMT depth, storage slots);
2. the **effective gas price** became far more responsive to congestion under FIP-0115's revised base-fee mechanism; and
3. the **FIL:USDFC rate**, pinned at $1 in the schedule, should be re-evaluated live.

**Schema note:** the indexer keeps receipt fields (`gas_used`, `effective_gas_price`) in a `tx_meta` view (one row per tx), joined by `tx_hash`, not on event rows. Dedupe to one row per tx (`MAX(m.gas_used)` grouped by `tx_hash`) so multi-event and multi-piece `addPieces` txs are not double- or piece-weighted.

**Live data can't give you** a clean standalone `createDataSet` (mainnet bundles an add), the `+CDN` creation premium at identical state, or the `schedulePieceDeletions` enqueue cost (no event).

To change a price: edit the literal in `PriceListUSDFC.sol` and ship a UUPS announce-then-execute upgrade.

---

## 5. Open sensitivities and gray areas

- **Effective-price compression.** FIP-0115 made the base fee far more responsive to congestion, so the effective gas price now swings widely. At the ~540K regime as of writing, cost-recovery fees give ~3-5x headroom vs the design ~10x, and a spike to ~650K pushes addPieces base toward ~2x. Still above 1x, but the buffer is largely spent. Primary recalibration trigger.
- **FIL:USDFC (a second, independent compressor).** Cost is in FIL, fees in USDFC. Coverage above assumes the schedule's FIL = $1, so divide by the live FIL price: at FIL = $2 the cost-recovery fees sit ~1.5-2.5x. Stacks on effective-price compression; re-evaluate at the live rate, not the 1:1 pin.
- **CDN creation premium thinly measured.** ~334M gas from n=3 post-upgrade combos; directional, confirm on devnet.
- **Removal cost entangled.** Removal gas splits in two: the enqueue (`schedulePieceDeletions`) and the actual deletion, processed later inside `nextProvingPeriod`. An enqueue event ([FilOzone/pdp#281](https://github.com/FilOzone/pdp/issues/281)) would expose the enqueue leg, but the deletion leg, the larger and piece-count-dependent one, stays fused with proving in the same tx. Isolating it means pairing a scheduled removal with the next `nextProvingPeriod` and subtracting that data set's no-removal baseline, which is approximate and awkward. The flat 0.002 under-recovers large batches; best-effort either way.
- **Cleanup gas vs the 0.1 FIL deposit (abandonment).** Deleting a data set's pieces costs gas the SP normally recovers via its 0.1 FIL PDPVerifier cleanup deposit, so routine teardown nets out. With many pieces the cleanup gas can exceed 0.1 FIL, and a rational SP may abandon the set: it stops proving and charging and frees the data server-side, leaving the inert data set on-chain and forfeiting the deposit. After `INACTIVITY_WINDOW` (86400 epochs, ~30 days) cleanup becomes permissionless and the deposit goes to whoever completes it, so abandoned sets get cleaned by profit-seekers (few pieces) or network-aligned parties (chain hygiene). The residual is large-piece-count sets uneconomic for anyone to clean, which linger on-chain though effectively deleted.
- **terminateService over-provisioned.** The new consent method, introduced along with the new pricing scheme in 1.3.0, is measurably cheaper (~159M) than the original guess, so 0.00112 is ~13x.
