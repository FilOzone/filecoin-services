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

Price changes take effect on existing rails when their rates are recalculated (e.g., when pieces are added or removed from a data set).

### Top-Up and Renewal

Clients extend storage duration by depositing additional funds to their account. The relationship is:

```
storageDuration = availableFunds ÷ railPaymentRate
```

Adding funds increases duration; the rail rate remains unchanged until the data set size changes or global pricing is updated.
