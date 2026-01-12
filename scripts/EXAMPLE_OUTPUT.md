# Example Output

This document shows example outputs from the fault status query script.

## Example 1: Dataset with No Faults

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Filecoin Warm Storage Service - Fault Status Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dataset ID: 123
Contract: 0x80617b65FD2EEa1D7fDe2B4F85977670690ed348
RPC: https://api.calibration.node.glif.io/rpc/v1

Fetching current block number...
✓ Current block: 3245678

Querying proving configuration...
✓ Proving configuration retrieved
  Activation Epoch: 3100000
  Current Deadline: 3250000
  Max Proving Period: 25000 epochs
  Challenge Window: 5000 epochs

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Proving Period Analysis
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Current Period: 5
Challenge Window: blocks 3245000 to 3250000
✓ Currently in challenge window

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Fault History (Periods 0 to 5)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Scanning 6 proving periods...

Period     Deadline        Status          Result
────────────────────────────────────────────────────────────
0          3125000         Checked         ✓ PROVEN
1          3150000         Checked         ✓ PROVEN
2          3175000         Checked         ✓ PROVEN
3          3200000         Checked         ✓ PROVEN
4          3225000         Checked         ✓ PROVEN
5          3250000         Pending         ○ Not yet due

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Total Periods Checked: 6
Proven Periods: 5
Faulted Periods: 0

✓ NO FAULTS DETECTED - All checked periods proven successfully

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Example 2: Dataset with Faults

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Filecoin Warm Storage Service - Fault Status Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dataset ID: 456
Contract: 0x80617b65FD2EEa1D7fDe2B4F85977670690ed348
RPC: https://api.calibration.node.glif.io/rpc/v1

Fetching current block number...
✓ Current block: 3345678

Querying proving configuration...
✓ Proving configuration retrieved
  Activation Epoch: 3100000
  Current Deadline: 3250000
  Max Proving Period: 25000 epochs
  Challenge Window: 5000 epochs

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Proving Period Analysis
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Current Period: 9
Challenge Window: blocks 3245000 to 3250000
⚠ DEADLINE MISSED by 95678 blocks (3 period(s))

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Fault History (Periods 0 to 9)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Scanning 10 proving periods...

Period     Deadline        Status          Result
────────────────────────────────────────────────────────────
0          3125000         Checked         ✓ PROVEN
1          3150000         Checked         ✓ PROVEN
2          3175000         Checked         ✗ FAULTED
3          3200000         Checked         ✓ PROVEN
4          3225000         Checked         ✗ FAULTED
5          3250000         Checked         ✗ FAULTED
6          3275000         Checked         ✓ PROVEN
7          3300000         Checked         ✓ PROVEN
8          3325000         Checked         ✓ PROVEN
9          3350000         Pending         ○ Not yet due

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Total Periods Checked: 10
Proven Periods: 6
Faulted Periods: 3

Faulted Period IDs: 2 4 5

⚠ FAULTS DETECTED - Fault rate: 30.00%

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Example 3: Dataset with Proving Not Started

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Filecoin Warm Storage Service - Fault Status Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dataset ID: 789
Contract: 0x80617b65FD2EEa1D7fDe2B4F85977670690ed348
RPC: https://api.calibration.node.glif.io/rpc/v1

Fetching current block number...
✓ Current block: 3245678

Querying proving configuration...
✓ Proving configuration retrieved
  Activation Epoch: 0
  Current Deadline: 0
  Max Proving Period: 25000 epochs
  Challenge Window: 5000 epochs

⚠ Proving has not been activated for this dataset
```

## Example 4: Recent Period Check (--periods 10)

```bash
./query-fault-status.sh --periods 10 123
```

This limits the scan to only the 10 most recent periods, useful for datasets with many proving periods when you only care about recent history:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Filecoin Warm Storage Service - Fault Status Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dataset ID: 123
Contract: 0x80617b65FD2EEa1D7fDe2B4F85977670690ed348
RPC: https://api.calibration.node.glif.io/rpc/v1

Fetching current block number...
✓ Current block: 3345678

Querying proving configuration...
✓ Proving configuration retrieved
  Activation Epoch: 3100000
  Current Deadline: 3350000
  Max Proving Period: 25000 epochs
  Challenge Window: 5000 epochs

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Proving Period Analysis
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Current Period: 9
Challenge Window: blocks 3345000 to 3350000
✓ Currently in challenge window

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Fault History (Periods 0 to 9)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Scanning 10 proving periods...

Period     Deadline        Status          Result
────────────────────────────────────────────────────────────
0          3125000         Checked         ✓ PROVEN
1          3150000         Checked         ✓ PROVEN
2          3175000         Checked         ✓ PROVEN
3          3200000         Checked         ✓ PROVEN
4          3225000         Checked         ✓ PROVEN
5          3250000         Checked         ✓ PROVEN
6          3275000         Checked         ✓ PROVEN
7          3300000         Checked         ✓ PROVEN
8          3325000         Checked         ✓ PROVEN
9          3350000         Pending         ○ Not yet due

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Total Periods Checked: 10
Proven Periods: 9
Faulted Periods: 0

✓ NO FAULTS DETECTED - All checked periods proven successfully

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Note: If the current period is 100 and you use `--periods 10`, it will check periods 91-100 (the 10 most recent), not periods 0-9.

## Interpreting the Output

### Status Indicators

- **✓ PROVEN** (Green) - The provider successfully submitted proof for this period
- **✗ FAULTED** (Red) - The deadline passed without a valid proof being submitted
- **○ Not yet due** (White) - The deadline for this period has not yet arrived

### Key Metrics

1. **Current Block** - The latest block on the chain
2. **Activation Epoch** - When proving started for this dataset
3. **Current Deadline** - The block number of the next proving deadline
4. **Max Proving Period** - How many blocks between each proof requirement
5. **Challenge Window** - How many blocks before the deadline proofs can be submitted

### Understanding Deadlines

- If `Current Block < Challenge Window Start`: Too early to submit proof
- If `Challenge Window Start <= Current Block <= Deadline`: Can submit proof now
- If `Current Block > Deadline`: Deadline missed - provider is late!

### Fault Rate

The fault rate is calculated as:
```
Fault Rate = (Faulted Periods / Total Checked Periods) × 100%
```

A fault rate of 0% means perfect proving performance. Higher fault rates indicate reliability issues.
