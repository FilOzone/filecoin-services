# Proven Periods Bitmap - Technical Reference

This document explains the bitmap storage system used for tracking proving periods in the FilecoinWarmStorageService contract.

## Overview

The contract uses an optimized bitmap storage mechanism to efficiently track which proving periods have been successfully proven. Instead of storing one boolean per period (which would consume one storage slot per period), the contract packs 256 periods into a single `uint256` storage slot.

## Storage Structure

```solidity
mapping(uint256 dataSetId => mapping(uint256 bucketId => uint256)) private provenPeriods;
```

- **Outer mapping**: Maps each dataset ID to its own proving history
- **Inner mapping**: Maps bucket IDs to uint256 values (each holds 256 bits)
- **Each bit**: Represents whether a specific period was proven (1) or faulted (0)

## Bit Manipulation

### Setting a Period as Proven

```solidity
provenPeriods[dataSetId][periodId >> 8] |= (1 << (periodId & 255));
```

**Breaking this down:**

1. **`periodId >> 8`** - Right shift by 8 bits (divide by 256)
   - This calculates which bucket to use
   - Example: Period 1000 → Bucket 3 (1000 ÷ 256 = 3)

2. **`periodId & 255`** - Bitwise AND with 255 (modulo 256)
   - This calculates which bit within the bucket
   - Example: Period 1000 → Bit 232 (1000 % 256 = 232)

3. **`1 << (periodId & 255)`** - Left shift 1 by the bit position
   - Creates a bitmask with only that bit set
   - Example: For bit 232 → `0x...0100000000000000000000000000000000000000000000000000000000000000`

4. **`|=`** - Bitwise OR assignment
   - Sets the bit to 1 without affecting other bits
   - Preserves all existing bits in the bucket

### Checking if a Period is Proven

```solidity
function _isPeriodProven(uint256 dataSetId, uint256 periodId) private view returns (bool) {
    return provenPeriods[dataSetId][periodId >> 8] & (1 << (periodId & 255)) != 0;
}
```

**Breaking this down:**

1. **Get the bucket**: `provenPeriods[dataSetId][periodId >> 8]`
2. **Create bitmask**: `1 << (periodId & 255)`
3. **Bitwise AND**: Checks if the specific bit is set
4. **Compare to 0**: Returns true if bit is set, false otherwise

## Examples

### Example 1: Period 0

```
periodId = 0

Bucket calculation: 0 >> 8 = 0
Bit position: 0 & 255 = 0
Bitmask: 1 << 0 = 0x0000...0001

Storage location: provenPeriods[dataSetId][0]
Bit position: 0 (rightmost bit)
```

### Example 2: Period 255

```
periodId = 255

Bucket calculation: 255 >> 8 = 0
Bit position: 255 & 255 = 255
Bitmask: 1 << 255 = 0x8000...0000

Storage location: provenPeriods[dataSetId][0]
Bit position: 255 (leftmost bit)
```

### Example 3: Period 256

```
periodId = 256

Bucket calculation: 256 >> 8 = 1
Bit position: 256 & 255 = 0
Bitmask: 1 << 0 = 0x0000...0001

Storage location: provenPeriods[dataSetId][1]
Bit position: 0 (rightmost bit of second bucket)
```

### Example 4: Period 1000

```
periodId = 1000

Bucket calculation: 1000 >> 8 = 3
Bit position: 1000 & 255 = 232
Bitmask: 1 << 232 = 0x0100000000000000000000000000000000000000000000000000000000000000

Storage location: provenPeriods[dataSetId][3]
Bit position: 232
```

## Visualization

### Bucket Layout

```
Bucket 0: Periods 0-255
┌────────────────────────────────────────────────────────┐
│ [255][254]...[2][1][0]                                 │
│  ↑    ↑       ↑  ↑  ↑                                  │
│  Bit Bit     Bit Bit Bit                              │
│  255 254     2   1   0                                 │
└────────────────────────────────────────────────────────┘

Bucket 1: Periods 256-511
┌────────────────────────────────────────────────────────┐
│ [511][510]...[258][257][256]                           │
└────────────────────────────────────────────────────────┘

Bucket 2: Periods 512-767
Bucket 3: Periods 768-1023
... and so on
```

### Single uint256 Bucket Example

```
uint256 value = provenPeriods[dataSetId][0]

Bit layout (256 bits total):
Position: 255 254 253 ... 003 002 001 000
Value:      1   0   1  ...  1   0   1   1
Meaning:    ✓   ✗   ✓  ...  ✓   ✗   ✓   ✓

✓ = Period proven (bit = 1)
✗ = Period faulted (bit = 0)
```

## Gas Efficiency

### Without Bitmap (naive approach)
```solidity
mapping(uint256 dataSetId => mapping(uint256 periodId => bool)) private provenPeriods;
```
- **Storage**: 1 slot per period
- **Cost**: ~20,000 gas per period to set from 0 to 1

### With Bitmap (optimized)
```solidity
mapping(uint256 dataSetId => mapping(uint256 bucketId => uint256)) private provenPeriods;
```
- **Storage**: 1 slot per 256 periods
- **Cost**:
  - First bit in bucket: ~20,000 gas (cold storage)
  - Additional bits in same bucket: ~5,000 gas (warm storage)
- **Space savings**: 256× reduction in storage slots

## Querying via RPC

### Direct Storage Query (Advanced)

To read the raw bitmap directly from storage:

```bash
# Calculate storage slot for provenPeriods[dataSetId][bucketId]
# This requires knowing the storage layout

cast storage <CONTRACT_ADDRESS> <STORAGE_SLOT> --rpc-url <RPC_URL>
```

### View Function Query (Recommended)

```bash
# Check if a specific period is proven
cast call <CONTRACT_ADDRESS> \
  "provenPeriods(uint256,uint256)" \
  <dataSetId> <periodId> \
  --rpc-url <RPC_URL>
```

Returns:
- `0x0000...0001` if period is proven
- `0x0000...0000` if period faulted

## Decoding Bitmap in Scripts

### Pseudocode

```python
def is_period_proven(bitmap_value, period_id):
    """Check if a specific period is proven given the bucket bitmap."""
    bit_position = period_id & 255  # period_id % 256
    bitmask = 1 << bit_position
    return (bitmap_value & bitmask) != 0

def get_all_proven_periods_in_bucket(bitmap_value, bucket_id):
    """Extract all proven periods from a single bucket."""
    proven_periods = []
    base_period = bucket_id * 256

    for bit_pos in range(256):
        if bitmap_value & (1 << bit_pos):
            proven_periods.append(base_period + bit_pos)

    return proven_periods
```

### Shell Script Example

```bash
# Query bucket 0 (periods 0-255)
bucket_value=$(cast call $CONTRACT "provenPeriods(uint256,uint256)" $DATASET_ID 0 --rpc-url $RPC)

# Check specific period (e.g., period 100)
period_id=100
bit_position=$((period_id & 255))  # 100 % 256 = 100
bitmask=$((1 << bit_position))

# Check if period is proven
if (( (bucket_value & bitmask) != 0 )); then
    echo "Period $period_id is PROVEN"
else
    echo "Period $period_id is FAULTED"
fi
```

## Related Contract Code

### File: `service_contracts/src/FilecoinWarmStorageService.sol`

**Setting proven period (line 933):**
```solidity
provenPeriods[dataSetId][currentPeriod >> 8] |= (1 << (currentPeriod & 255));
```

**Checking proven period (line 1621):**
```solidity
function _isPeriodProven(uint256 dataSetId, uint256 periodId) private view returns (bool) {
    return provenPeriods[dataSetId][periodId >> 8] & (1 << (periodId & 255)) != 0;
}
```

**Public view function (StateView.sol line 142):**
```solidity
function provenPeriods(uint256 dataSetId, uint256 periodId) public view returns (bool) {
    return FilecoinWarmStorageServiceStateLibrary.provenPeriods(service, dataSetId, periodId);
}
```

## Common Pitfalls

### ❌ Wrong: Direct boolean storage
```solidity
mapping(uint256 => mapping(uint256 => bool)) provenPeriods;
```
- Uses 1 storage slot per period
- Expensive for long-term storage

### ❌ Wrong: Incorrect bit calculation
```solidity
// Don't use division and modulo operators
uint256 bucket = periodId / 256;      // More expensive than >>
uint256 bitPos = periodId % 256;      // More expensive than &
```

### ✅ Correct: Bitmap with bitwise operations
```solidity
mapping(uint256 => mapping(uint256 => uint256)) provenPeriods;
provenPeriods[dataSetId][periodId >> 8] |= (1 << (periodId & 255));
```
- Uses 1 storage slot per 256 periods
- Efficient bitwise operations
- Scales to thousands of periods

## Performance Comparison

| Approach | Storage per 1000 periods | Gas for setting 1000 periods |
|----------|--------------------------|------------------------------|
| Individual bools | 1000 slots | ~20,000,000 gas |
| Bitmap (optimized) | 4 slots | ~100,000 gas |
| **Savings** | **99.6% less** | **99.5% less** |

## See Also

- [Solidity Bitwise Operations](https://docs.soliditylang.org/en/latest/types.html#bitwise-operators)
- [EVM Storage Layout](https://docs.soliditylang.org/en/latest/internals/layout_in_storage.html)
- [Gas Optimization Techniques](https://github.com/iskdrews/awesome-solidity-gas-optimization)
