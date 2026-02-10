# Filecoin Services Specification

## Pricing

### Pricing Model

FilecoinWarmStorageService uses **static global pricing**. All payment rails use the same price regardless of which provider stores the data. The default storage price is 2.5 USDFC per TiB/month.

Providers may advertise their own prices in the ServiceProviderRegistry, but these are informational for other services, and does not affect actual payments in FilecoinWarmStorageService.

### Rate Calculation

The payment rate per epoch is calculated from the total data size in bytes:

```
# Constants
EPOCHS_PER_MONTH              = 86400         # 2880 epochs/day × 30 days
TiB                           = 1099511627776 # bytes

# Default pricing (owner-adjustable)
pricePerTiBPerMonth           = 2.5 USDFC
minimumStorageRatePerMonth    = 0.06 USDFC

# Per-epoch rate calculation
sizeBasedRate = totalBytes × pricePerTiBPerMonth ÷ TiB ÷ EPOCHS_PER_MONTH
minimumRate   = minimumStorageRatePerMonth ÷ EPOCHS_PER_MONTH
finalRate     = max(sizeBasedRate, minimumRate)
```

The default minimum floor ensures datasets below ~24.58 GiB still generate the minimum payment of 0.06 USDFC/month.

**Precision note**: Integer division when computing `minimumRate` causes minor precision loss. The actual monthly payment (`minimumRate × EPOCHS_PER_MONTH`) is slightly less than `minimumStorageRatePerMonth`—under 0.0001% for typical floor prices. This is acceptable; see the lockup section below for how pre-flight checks handle this.

### Pricing Updates

Only the contract owner can update pricing by calling `updatePricing(newStoragePrice, newMinimumRate)`. Maximum allowed values are 10 USDFC for storage price and 0.24 USDFC for minimum rate.

**Effect on existing datasets**: Pricing changes do not immediately update rates for existing datasets. New rates take effect when pieces are next added or removed. This avoids gas-expensive rate recalculations across all active datasets while ensuring new pricing applies to all future storage operations.

### Rate Update Timing

Rate recalculation timing differs for additions and deletions due to proving semantics:

- **Adding pieces**: The rate updates immediately when `piecesAdded()` is called. The client begins paying for new pieces right away, even though those pieces won't be included in proof challenges until the next proving period. This fail-fast behavior protects providers: if the client lacks sufficient funds for the new lockup, the transaction fails before the provider commits resources.

- **Removing pieces**: Deletions are scheduled and take effect at the next proving boundary (`nextProvingPeriod()`). The client continues paying the existing rate until the removal is finalized. This deferral is required because proofs may challenge any portion of the current data set during the proving period—the provider must continue storing and proving all existing data until the period ends.

**Why the asymmetry?**

During each proving period, proofs are generated over a fixed data set. The prover must maintain the complete data set because challenges can target any leaf:

- **Additions expand the proof space** but don't affect existing challenges. New pieces simply won't be challenged until the next period. Payment starts immediately because storage resources are committed.

- **Deletions would shrink the proof space** mid-period, potentially invalidating challenges. The data must remain intact until `nextProvingPeriod()` finalizes the removal. Only then does the rate decrease.

This ensures proof integrity while providing fair payment semantics: you pay when you add, and continue paying for deletions until the proving period boundary.

### Rate Changes After Termination

When a service is terminated (by client or provider), the payment rail enters a lockup period during which funds continue flowing to the provider. Rate change behavior differs from active rails:

- **Additions are blocked**: `piecesAdded()` reverts after termination. No new pieces can be added to a terminated dataset.

- **Deletions are allowed**: Piece removals can still be scheduled during the lockup window via `piecesScheduledRemove()`, and take effect at the next proving boundary.

- **Rate can only decrease or stay the same**: Since additions are blocked, the only size changes come from deletions. FilecoinPay enforces `newRate <= oldRate` on terminated rails—rate increases are rejected with `RateChangeNotAllowedOnTerminatedRail`.

This design ensures the provider receives payment at or above the rate established before termination. The lockup period guarantees payment for the agreed service level, while still allowing the client to reduce their data footprint (and rate) through deletions.

### Funding and Top-Up

Clients pay for storage by depositing USDFC into the Filecoin Pay contract. These funds flow to providers over time based on the storage rate.

**Lockup**: To protect providers from non-payment, FWSS requires clients to maintain a 30-day reserve of funds. This "lockup" guarantees the provider will be paid for at least 30 days even if the client stops adding funds. The lockup is not a pre-payment—funds still flow to the provider gradually—but it cannot be withdrawn while the storage agreement is active.

```
lockupRequired = finalRate × EPOCHS_PER_MONTH
```

At minimum pricing, this equals `minimumStorageRatePerMonth` (0.06 USDFC at default settings). For larger datasets, the lockup equals one month's storage cost.

**Pre-flight check precision**: The pre-flight validation uses a multiply-first formula `(minimumStorageRatePerMonth × EPOCHS_PER_MONTH) ÷ EPOCHS_PER_MONTH` which preserves the exact monthly value. This produces cleaner error messages (the configured floor price rather than a value with precision loss artifacts) and is slightly more conservative than the actual rail lockup. The difference is under 0.0001% and always in the user's favor—they are never required to have less than needed.

**Storage duration** extends as clients deposit additional funds:

```
storageDuration = availableFunds ÷ finalRate
```

Deposits extend the duration without changing the rate (unless adding pieces triggers an immediate rate recalculation, or scheduled deletions take effect at the next proving boundary).

**Delinquency**: When a client's funded epoch falls below the current epoch, the payment rail can no longer be settled—no further payments flow to the provider. The provider may terminate the service to claim payment from the locked funds, guaranteeing up to 30 days of payment from the last funded epoch.

## Settlement and Payment Validation

### Proving Period Epoch Conventions

Proving periods use **exclusive-inclusive** epoch ranges. The activation epoch (set when `nextProvingPeriod()` is first called) is a boundary marker, not a billable epoch.

With activation epoch `A` and period length `M` (maxProvingPeriod, e.g. 2880 for a 1-day proving period):

```
Period 0: epochs (A,   A+M]         (billable epochs A+1 through A+M)
Period 1: epochs (A+M, A+2M]        (billable epochs A+M+1 through A+2M)
Period N: epochs (A+N*M, A+(N+1)*M]
```

The **deadline** for period N is `A + (N+1)*M`, the last epoch of the period, and the last epoch at which a proof can be submitted.

The formula `(epoch - A - 1) / M` maps an epoch to its period number. The `- 1` shifts from inclusive-exclusive `[A, A+M)` to exclusive-inclusive `(A, A+M]` ranges, so the deadline epoch belongs to its own period rather than the next. The activation epoch itself returns an invalid sentinel (`type(uint256).max`) because `epoch < activationEpoch` after the subtraction underflows.

Using the same logic, settlement ranges also use exclusive-inclusive `(fromEpoch, toEpoch]`. The settlement `fromEpoch` should be the last settled epoch, and the range is treated as exclusive of that epoch. `fromEpoch` is also clamped up to `A`, so any `fromEpoch <= A` results in the first billable epoch being `A+1`. `toEpoch` is the last epoch to settle, and the range is treated as inclusive of this epoch.

### Settlement Rules (Proven / Faulted / Open)

`validatePayment()` is called by FilecoinPay during `settleRail()`.

Settlement progress (`settledUpTo`) tracks the epoch up to which payments have been processed. `validatePayment()` determines how far settlement can advance and how much payment is due.

Because payment amount is tied to successfully submitted proofs, it's possible for period can advance `settleUpTo` while contributing zero to the payment.

Each proving period is in one of three states:

- **Proven**: Period has a valid proof. Settlement advances and payment is proportional to proven epochs.
- **Faulted**: Deadline has passed with no proof. Settlement advances but payment is zero.
- **Open**: Deadline has not yet passed, no proof. Settlement is blocked at the period boundary because the provider may still submit a proof.

### Partial-Period Settlement (FilecoinPay Rate Changes)

Where base rail rate changes have occurred (e.g. pieces were added mid-period, changing the payment rate), FilecoinPay settles each rate "segment" independently (see `_settleWithRateChanges`). Each segment gets its own `validatePayment()` call with a `toEpoch` that may fall anywhere within a proving period. So `validatePayment()` must be able to handle settlement of near-arbitrary ranges (see `_findProvenEpochs`).

### Settlement Algorithm (_findProvenEpochs)

The function iterates through each proving period that overlaps the settlement range `(fromEpoch, toEpoch]`, applying the proven/faulted/open rules uniformly to each. Partial periods at the start and end of the range are handled by clamping: each period contributes epochs from `max(periodStart, fromEpoch)` to `min(toEpoch, deadline)`. Only the last period in the range can be open — since `toEpoch <= block.number`, all earlier periods' deadlines have necessarily passed.

`validatePayment()` signals the final settlement epoch to FilecoinPay, which is recorded as `settledUpTo` on the rail. The next setllement call uses this as its `fromEpoch`, so settlement progresses incrementally. The provider is paid proportional to the number of proven epochs within the range requested for settlement by FilecoinPay, whether that range covers multiple periods, or a partial period due to rate change segmentation.

### Settlement During Lockup

After termination, the payment rail enters a lockup period. Settlement continues normally during this time:

- If the provider proves all periods, they receive full payment
- If the provider fails to prove some periods, those epochs receive zero payment
- If the provider abandons entirely, settlement advances with zero payment once all deadlines pass

The client's locked funds are released proportionally as settlement progresses. Unproven epochs result in funds returning to the client rather than flowing to the provider.

### Dataset Deletion Requirements

Dataset deletion (`dataSetDeleted`) requires the payment rail to be fully settled before the dataset can be removed:

```
require(settledUpTo >= endEpoch, RailNotFullySettled)
```

**Rationale**: The `validatePayment()` callback reads dataset state (proving status, periods proven) to calculate payment amounts. If the dataset is deleted before settlement completes, `validatePayment()` cannot function, forcing clients to use `settleTerminatedRailWithoutValidation()` which pays the full amount regardless of proof status.

**Implications**:

- Providers must wait for settlement to complete before deleting datasets
- Clients can always settle rails (with zero payment for unproven periods) once deadlines pass
- Dataset deletion timing is controlled by proving period deadlines, not just the lockup period

**Timing**: To delete a dataset after termination:
1. Wait for `block.number > pdpEndEpoch` (lockup period elapsed)
2. Wait for all proving period deadlines within the lockup to pass
3. Call `settleRail()` to complete settlement (rail may auto-finalize)
4. Call `deleteDataSet()` to remove the dataset

## CDN Payment Rails

Datasets with CDN support have three payment rails: a **PDP rail** for storage proving, and two **CDN rails** for content delivery:

- **Cache-miss rail** (`cacheMissRailId`): Pays to the storage provider (SP) for origin fetches
- **Bandwidth rail** (`cdnRailId`): Pays to the FilBeam beneficiary address (immutably set at deployment)

Both CDN rails have `paymentRate = 0` and use fixed lockup for one-time payments based on usage.

### Payment Models

PDP and CDN rails use fundamentally different payment models:

**PDP rail**: Uses proof-based settlement. FWSS acts as validator, receiving callbacks to verify that storage proofs were submitted before authorizing payment. Settlement amounts depend on proving status.

**CDN rails**: Use usage-based settlement via one-time payments. No validator is set. The FilBeam controller calculates payment amounts based on actual egress metrics and calls `settleFilBeamPaymentRails()` on FWSS, which executes one-time payments from the fixed lockup. This decouples CDN payment logic from the proof-based model used for storage.

### CDN Rail Operations

**Top-up**: Clients call `topUpCDNPaymentRails()` on FWSS to increase their CDN fixed lockup, which extends their egress allowance.

**Settlement**: The FilBeam controller calls `settleFilBeamPaymentRails()` on FWSS to execute one-time payments based on usage data. This is the intended settlement path.

**Termination**: The intended path is `terminateCDNService()` on FWSS, which terminates both CDN rails and clears the `withCDN` metadata.

### Direct FilecoinPay Access

Because CDN rails have no validator, FilecoinPay permits the payer to call `terminateRail()` directly. Since CDN rails have `paymentRate = 0`, the payer's lockup is effectively always settled, so this is always permitted. Direct `settleRail()` calls are also permitted but would be a no-op since there's no streaming rate to settle. This is a constraint of FilecoinPay's design, not the intended usage path.

### CDN Metadata Synchronization

FWSS tracks CDN-enabled datasets using a `withCDN` metadata key. This metadata is set when CDN rails are created and deleted when CDN service is terminated through FWSS.

If CDN rails are terminated directly via FilecoinPay (bypassing FWSS), the `withCDN` metadata remains set because FWSS receives no callback. This creates an out-of-sync state where FWSS believes CDN is active but the underlying rails are terminated or finalized. Subsequent CDN operations (`topUpCDNPaymentRails`, `settleFilBeamPaymentRails`) will fail when they attempt to interact with the inactive rails.

**Note**: There is currently no mechanism to clean up orphaned `withCDN` metadata. The practical impact is limited since `terminateService()` uses best-effort CDN termination (ignoring errors), so full service termination still succeeds.

### Service Termination

When terminating a dataset's service, FWSS terminates the PDP rail (which it validates) and performs best-effort termination of CDN rails, ignoring any errors. This ensures service termination succeeds regardless of CDN rail state—whether rails are active, already terminated, or fully settled and finalized.
