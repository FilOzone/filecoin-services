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

### Pricing Updates

Only the contract owner can update pricing by calling `updatePricing(newStoragePrice, newMinimumRate)`. Maximum allowed values are 10 USDFC for storage price and 0.24 USDFC for minimum rate.

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

At minimum pricing, this equals 0.06 USDFC. For larger datasets, the lockup equals one month's storage cost.

**Storage duration** extends as clients deposit additional funds:

```
storageDuration = availableFunds ÷ finalRate
```

Deposits extend the duration without changing the rate (unless adding pieces triggers an immediate rate recalculation, or scheduled deletions take effect at the next proving boundary).

**Delinquency**: When a client's funded epoch falls below the current epoch, the payment rail can no longer be settled—no further payments flow to the provider. The provider may terminate the service to claim payment from the locked funds, guaranteeing up to 30 days of payment from the last funded epoch.
