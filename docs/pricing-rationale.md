# FWSS Pricing Rationale

The durable record of the FilecoinWarmStorageService pricing schedule: why each fee exists, how it was derived, and how to re-derive it. Resolves [#468](https://github.com/FilOzone/filecoin-services/issues/468); supersedes the pre-GA pricing drafts.

The contract is the source of truth, not this document. List prices are `internal constant` literals in [`PriceListUSDFC.sol`](../service_contracts/src/lib/PriceListUSDFC.sol), and the live schedule is readable on-chain via `FilecoinWarmStorageServiceStateView.getPriceList()`. This doc explains those numbers, it does not define them.

> **Calibration basis (read first).** An SP pays the *effective gas price* (base fee + priority tip) per gas, not the base fee alone. [FIP-0115](https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0115.md) (NV28, mainnet June 2026) made the base fee responsive to congestion, so the effective price now swings widely (week-scale spikes reach several times the sustained level). The schedule is sized at the tx-weighted mean effective price over the post-FIP-0115 regime — 1.912M attoFIL/gas at the last derivation (2026-08) — with 10x headroom absorbing spikes, gas drift, and FIL:USDFC moves. The price level and the FIL = $1 assumption (section 3) are the two things to watch for recalibration (section 4).

---

## 1. The pricing schedule

FWSS bills in two forms, both in USDFC (18 decimals), both through FilecoinPay rails:

- **Streaming rates** accrue per epoch while data is stored.
- **One-time fees** fire when a lifecycle operation occurs, paid to the SP to reimburse the gas it fronts for that call. They draw from a small pre-funded **lifecycle reserve** on the PDP rail.

| Component | List price | Kind | Paid to | Constant |
|---|---|---|---|---|
| Storage | 2.50 USDFC / TiB / month | streaming | SP | `STORAGE_PRICE_PER_TIB_PER_MONTH` |
| Proving (per data set) | 0.20 USDFC / month | streaming, additive | SP | `DATASET_FEE_PER_MONTH` |
| Create data set | 0.025 USDFC | one-time | SP | `CREATE_DATA_SET_FEE` |
| Add pieces | 0.008 + 0.003 x N USDFC | one-time, per call | SP | `ADD_PIECES_BASE_FEE`, `ADD_PIECES_PER_PIECE_FEE` |
| Schedule piece removals | 0.007 USDFC | one-time, per call | SP | `SCHEDULE_PIECE_REMOVALS_FEE` |
| Terminate service | 0.006 USDFC | one-time | SP | `TERMINATE_FEE` |
| CDN egress | 7 USDFC / TiB | usage (FilBeam) | SP / FilBeam | `CDN_EGRESS_PRICE_PER_TIB`, `CACHE_MISS_EGRESS_PRICE_PER_TIB` |
| Lifecycle reserve | 1.00 target / 0.05 replenish | lockup | refunded | `LIFECYCLE_RESERVE_TARGET`, `REPLENISH_THRESHOLD` |

`N` is the piece count in the `addPieces` call. The reserve is a lockup, not a charge: unused balance returns at rail finalization.

**Not in the schedule (and why):**

- **No sybil fee.** v1.2.x burned 0.1 USDFC per data set via a separate FilecoinPay auction rail; v1.3.0 removes it, folding the anti-spam role into the elevated create fee (section 2).
- **No delete-data-set fee.** Deletion is an SP-side cleanup, not a client charge. The client-facing teardown is covered by the terminate fee together with the create fee; the SP's on-chain cleanup gas is offset separately by recovering its 0.1 FIL PDPVerifier cleanup deposit. *(Earlier drafts listed a 0.00112 delete fee gated on an EIP-712 delete authorization that was since removed from FWSS; there is no `deleteDataSetFee`.)* The case where cleanup gas exceeds the deposit is in section 5.
- **Commission is 0 bps** (`SERVICE_COMMISSION_BPS`): FWSS takes no cut of the streaming rail.

---

## 2. Design rationale, per component

**What the one-time fees protect against:** an SP fronts FIL gas for each lifecycle call (create, add, remove, terminate) on the client's behalf. Without reimbursement it absorbs that cost, under-pricing heavy-lifecycle clients and opening a free DoS on SP gas. The fees pass the gas through to whoever caused it.

**Streaming: storage + proving, additive not floored.** The rate is `naturalRate(bytes) + provingFee`, replacing the old `max(naturalRate, floor)` clamp. Storage scales with TiB; proving gas is flat per data set (5 challenges per period regardless of size), so a per-TiB term plus a fixed per-data-set term fits SP cost better than one clamp. Side effect: empty data sets pay zero, retiring the separate "floor on empty data sets" design.

**Create data set: 0.025, a deliberate over-charge.** A soft sybil deterrent replacing the old 0.1 FIL burn at lower magnitude, paid to the SP (covering its create gas and lifecycle admin, and raising the cost of spamming empty data sets). Measured `createDataSet` gas is ~618M — at the current price basis the 10x cost figure is ~0.012, so the deterrent margin has eroded from ~200x at first calibration to ~2x; the fee is held at 0.025 for now, and whether the deterrent needs restoring is a separate question from cost recovery.

**Add pieces: base + per-piece.** Two terms for two gas components: fixed per-call overhead (base) and marginal per piece (calldata plus storage). `0.008 + 0.003 x N` tracks SP cost from one piece to a full batch. Batches cap at 41 pieces (the per-event data-size limit, not a contract constant; the repo's `OpFees` tests use `BATCH_CAP = 41`), so `N` is bounded. SDK/Curio apply a conservative 40 in practice.

**The authorizer budget rides in the gated fees.** The per-data-set authorizer ([#536](https://github.com/FilOzone/filecoin-services/pull/536)) runs a client-programmable `isAuthorized` subcall inside `addPieces`, `schedulePieceRemovals`, and `terminateService`, hard-capped at 150M gas (`AUTHORIZER_GAS_LIMIT`). Since these fees are fixed gas pass-throughs, each gated fee funds the full cap in its base — worst case measured end-to-end at +146-156M gas per call. Funding it in the fee (rather than a separate line item, per-authorizer metering, or netting out the session-key path it can replace) keeps the pricing story one number per op and the SP's worst case bounded; users without an authorizer over-pay by a sub-cent amount, which is ordinary default-feature-set pricing. A P256/passkey authorizer (~105M measured) fits the cap; if authorizers turn out to run far cheaper in practice (e.g. a future P256 syscall at ~2M), the recalibration cadence reclaims the difference.

**Schedule piece removals: 0.007.** Covers the enqueue leg plus the authorizer budget. Removal gas splits in two: the enqueue (`schedulePieceDeletions`, ~218M measured on an fvm-anvil fork of mainnet state — it emits no event on mainnet, [FilOzone/pdp#281](https://github.com/FilOzone/pdp/issues/281) proposes one) and the delete, processed later inside `nextProvingPeriod`, entangled with proving and unrecovered by this fee. A flat fee under-recovers very large batches (`schedulePieceDeletions` is bounded only by PDPVerifier's 2000-deep queue); accepted for simplicity.

**Terminate service: 0.006, consent path only.** Covers the measured consent-termination gas (~148.5M observed on mainnet) plus the authorizer budget (termination is authorizer-gated too). The fee is charged only on the consent-based immediate termination: the SP calls `terminateService` with the payer's signed authorization in `extraData` (the contract requires the caller to be the SP here), which terminates the PDP rail immediately by zeroing its lockup. A no-signature termination (empty `extraData`, callable by either the payer or the SP) takes the non-immediate path and charges nothing. CDN rails persist until data-set deletion rather than being torn down here.

**Lifecycle reserve: how one-time fees are paid.** The PDP rail holds a small fixed-lockup pool (1.00 target, replenished below 0.05 — roughly seven max-batch `addPieces` calls of headroom), so most ops cost one FilecoinPay interaction. Terminating settles the pending one-time payments; since FilecoinPay forbids raising a terminated rail's lockup, the reserve cannot be refilled afterward, so post-termination wind-down ops draw from whatever remains and a client needing more must pre-fund before terminating. Refunded at finalization if unused.

---

## 3. How the numbers were derived

The listed prices were last derived in August 2026. The methodology, per operation:

1. **Measure gas on the with-metadata path** (~99% of mainnet adds carry metadata; the original no-metadata basis left it structurally unpriced). Supporting rules: subtract in **gas units, not FIL** (base-fee-independent, so a "combo minus baseline" difference holds across sample times); **isolate FWSS** from other PDPVerifier users (`set_id IN (SELECT data_set_id FROM fwss_data_set_created)`); **derive by difference** where an op never runs alone (`createDataSet` = create+add combo - warm add; `addPieces` per-piece = least-squares slope over batch size); ops mainnet can't isolate (the removals enqueue) are measured on an fvm-anvil fork of mainnet state.
2. **Convert to USDFC:** gas x the *effective gas price* (tx-weighted mean over the post-FIP-0115 regime; 1.912M attoFIL/gas at derivation — see block [0] of `pricing-measurement.sql` for the standing window and spike cross-check) / 1e18, at the stated assumption **FIL = $1** (`usdfc_per_fil = 1.0`; section 5).
3. **x10** for headroom against price spikes, gas drift, and FIL:USDFC moves. Not profit (commission is zero). Authorizer-gated ops add the 150M budget to their gas basis before pricing (section 2).

| Component | Gas basis | Raw 10x | Listed |
|---|---|---|---|
| `ADD_PIECES_BASE_FEE` | 258.4M + 150M authorizer | 0.00781 | 0.008 |
| `ADD_PIECES_PER_PIECE_FEE` | 156.7M | 0.00300 | 0.003 |
| `SCHEDULE_PIECE_REMOVALS_FEE` | 218.0M enqueue + 150M authorizer | 0.00704 | 0.007 |
| `TERMINATE_FEE` | 148.5M + 150M authorizer | 0.00571 | 0.006 |
| `DATASET_FEE_PER_MONTH` | 10.52B/month (nextPP 131.5M + prove 219.2M, x30) | 0.20118 | 0.20 |
| `CREATE_DATA_SET_FEE` | 617.7M | 0.01181 | 0.025 (deliberate over-charge, section 2) |

The companion [`pricing-measurement.sql`](pricing-measurement.sql) (run against [foc-observer](https://github.com/FilOzone/foc-observer)) holds the queries. Every cost-recovery fee holds >=1x coverage to FIL = $10, a proportional gas-price rise, or any combination multiplying to <=10x.

---

## 4. Recalibrating in future

Re-derive periodically and after anything touching gas: a protocol upgrade, an FVM gas-model change, or a sustained base-fee shift, and consider updating the pricing schedule to maintain reasonable economics.

**Runbook:** run [`pricing-measurement.sql`](pricing-measurement.sql) against foc-observer (`network: mainnet`). Three variables, re-measure all three:

1. **gas units** drift up ~3-4x over six months from contract-state growth (HAMT/KAMT depth, storage slots);
2. the **effective gas price** became far more responsive to congestion under FIP-0115's revised base-fee mechanism; and
3. the **FIL:USDFC rate**, pinned at $1 in the schedule, should be re-evaluated live.

**Schema note:** the indexer keeps receipt fields (`gas_used`, `effective_gas_price`) in a `tx_meta` view (one row per tx), joined by `tx_hash`, not on event rows. Dedupe to one row per tx (`MAX(m.gas_used)` grouped by `tx_hash`) so multi-event and multi-piece `addPieces` txs are not double- or piece-weighted.

**Live data can't give you** a clean standalone `createDataSet` (mainnet bundles an add), the `+CDN` creation premium at identical state, or the `schedulePieceDeletions` enqueue cost (no event) — measure those on an fvm-anvil fork of mainnet state instead.

To change a price: edit the literal in `PriceListUSDFC.sol` and ship a UUPS announce-then-execute upgrade.

---

## 5. Open sensitivities and gray areas

- **Effective-price volatility.** FIP-0115 made the base fee responsive to congestion, so the effective price swings widely — week-scale spikes have reached ~4x the sustained mean, with single-tx outliers far beyond. The schedule prices at the regime mean and lets the 10x headroom absorb spikes; a doubling of the sustained mean is the primary recalibration trigger (section 4).
- **FIL:USDFC (a second, independent compressor).** Cost is in FIL, fees in USDFC. Coverage above assumes the schedule's FIL = $1, so divide by the live FIL price: at FIL = $2 the cost-recovery fees sit ~5x. Stacks on effective-price moves; re-evaluate at the live rate, not the 1:1 pin.
- **CDN creation premium thinly measured.** ~334M gas from n=3 post-upgrade combos; directional, confirm on devnet.
- **Removal cost entangled.** The fee covers the enqueue leg only (section 2); the deletion leg, the larger and piece-count-dependent one, stays fused with proving inside `nextProvingPeriod` (~240M gas/piece observed) and is unrecovered. Isolating it on mainnet means pairing a scheduled removal with the next `nextProvingPeriod` and subtracting a no-removal baseline — approximate and awkward; best-effort either way.
- **Cleanup gas vs the 0.1 FIL deposit (abandonment).** Deleting a data set's pieces costs gas the SP normally recovers via its 0.1 FIL PDPVerifier cleanup deposit, so routine teardown nets out. With many pieces the cleanup gas can exceed 0.1 FIL, and a rational SP may abandon the set: it stops proving and charging and frees the data server-side, leaving the inert data set on-chain and forfeiting the deposit. After `INACTIVITY_WINDOW` (86400 epochs, ~30 days) cleanup becomes permissionless and the deposit goes to whoever completes it, so abandoned sets get cleaned by profit-seekers (few pieces) or network-aligned parties (chain hygiene). The residual is large-piece-count sets uneconomic for anyone to clean, which linger on-chain though effectively deleted.
- **Authorizer budget sized to the cap, not typical use.** The gated fees fund the full 150M worst case; a trivial authorizer costs ~nothing and P256 ~105M, so cheap-authorizer users over-pay within the fee. If real authorizers settle far below the cap (e.g. a P256 syscall FIP at ~2M), the bi-annual recalibration reclaims it.

