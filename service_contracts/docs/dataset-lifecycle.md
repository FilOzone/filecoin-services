# Dataset Lifecycle and Status

## Overview

Datasets in the Filecoin Warm Storage Service have a simplified two-state lifecycle system that makes it easy for clients, developers, and external systems to understand and track the status of their stored data.

## Status Definitions

### Inactive

A dataset is **Inactive** when it meets any of the following conditions:

1. **Newly Created**: Dataset has been created but no pieces have been added yet
   - Payment rate = 0
   - No PDP proving active
   - `provingActivationEpoch` = 0

2. **Terminated**: The service has been terminated by either the payer or service provider
   - `pdpEndEpoch` > 0
   - Payment rails are no longer accepting new payments

3. **Beyond Lockup Period**: More than 1 month (86,400 epochs) has passed since termination
   - Current epoch > (`pdpEndEpoch` + `DEFAULT_LOCKUP_PERIOD`)
   - Payment rails are fully settled
   - Dataset can be deleted

### Active

A dataset is **Active** when:

1. **Has Pieces**: At least one piece has been added to the dataset
   - `leafCount` > 0
   - PDP proving is active

2. **Within Lockup**: Payment rails are operational
   - Either not terminated (`pdpEndEpoch` = 0)
   - Or within lockup period after termination

3. **Proving Active**: Data is being actively proven
   - `provingActivationEpoch` > 0
   - Regular PDP proofs are submitted

## State Transitions

```mermaid
stateDiagram-v2
    [*] --> Inactive: Dataset Created
    note right of Inactive
        No pieces yet
        rate = 0
    end note
    
    Inactive --> Active: First Piece Added
    note right of Active
        Proving starts
        Payment rails active
    end note
    
    Active --> Active: Normal Operation
    note left of Active
        Pieces added/removed
        Proofs submitted
        Payments flowing
    end note
    
    Active --> Inactive: Service Terminated
    note left of Inactive
        Payment rails terminated
        Within lockup period
    end note
    
    Inactive --> Inactive: Beyond Lockup
    note right of Inactive
        > 1 month after termination
        Can be deleted
    end note
    
    Inactive --> [*]: Dataset Deleted
```

## State Transition Events

The contract emits a `DataSetStatusChanged` event whenever the status changes:

```solidity
event DataSetStatusChanged(
    uint256 indexed dataSetId,
    DataSetStatus indexed oldStatus,
    DataSetStatus indexed newStatus,
    uint256 epoch
);
```

### When Events Are Emitted

1. **Dataset Creation**: 
   ```solidity
   emit DataSetStatusChanged(dataSetId, Inactive, Inactive, block.number);
   ```
   - Initial status recorded as Inactive

2. **First Piece Added** (Proving Starts):
   ```solidity
   emit DataSetStatusChanged(dataSetId, Inactive, Active, block.number);
   ```
   - Transition from Inactive to Active
   - Triggered in `nextProvingPeriod` when proving is first initialized

3. **Service Terminated**:
   ```solidity
   emit DataSetStatusChanged(dataSetId, Active, Inactive, block.number);
   ```
   - Transition from Active to Inactive
   - Triggered in `terminateService`

**Note**: The transition from "within lockup" to "beyond lockup" does not emit an event because it's a time-based transition with no on-chain transaction trigger.

## Querying Dataset Status

### 1. From Solidity (On-chain)

#### Direct Contract Call

```solidity
import {FilecoinWarmStorageServiceStateView} from "path/to/view/contract";

contract MyContract {
    FilecoinWarmStorageServiceStateView public viewContract;
    
    function checkDataSetStatus(uint256 dataSetId) public view returns (bool isActive) {
        FilecoinWarmStorageService.DataSetStatus status = 
            viewContract.getDataSetStatus(dataSetId);
        
        return status == FilecoinWarmStorageService.DataSetStatus.Active;
    }
}
```

#### Using State Library (Gas Efficient)

```solidity
import {FilecoinWarmStorageServiceStateLibrary} from "path/to/library";
import {FilecoinWarmStorageService} from "path/to/service";

contract MyContract {
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;
    
    FilecoinWarmStorageService public service;
    
    function checkStatus(uint256 dataSetId) public view returns (
        FilecoinWarmStorageService.DataSetStatus status,
        bool hasProving,
        bool isTerminated,
        bool isBeyondLockup
    ) {
        // Get detailed status information
        return FilecoinWarmStorageServiceStateLibrary.getDataSetStatusDetails(
            service,
            dataSetId
        );
    }
    
    function isActive(uint256 dataSetId) public view returns (bool) {
        return FilecoinWarmStorageServiceStateLibrary.isDataSetActive(
            service,
            dataSetId
        );
    }
}
```

### 2. From Subgraph (Off-chain)

#### Basic Status Query

```graphql
{
  dataSet(id: "0x1234...") {
    setId
    status
    isActive  # Deprecated, use status instead
    totalPieces
    pdpEndEpoch
    createdAt
    updatedAt
  }
}
```

#### Query with Status History

```graphql
{
  dataSet(id: "0x1234...") {
    setId
    status
    statusHistory(orderBy: timestamp, orderDirection: desc) {
      oldStatus
      newStatus
      epoch
      timestamp
      transactionHash
    }
  }
}
```

#### Filter Datasets by Status

```graphql
{
  # Get all active datasets for a payer
  dataSets(
    where: { payer: "0x5678...", status: ACTIVE }
    orderBy: updatedAt
    orderDirection: desc
  ) {
    setId
    status
    totalPieces
    totalDataSize
    serviceProvider {
      name
    }
  }
}
```

#### Status Transition History

```graphql
{
  dataSetStatusHistories(
    where: { dataSetId: "123" }
    orderBy: timestamp
    orderDirection: asc
  ) {
    oldStatus
    newStatus
    epoch
    blockNumber
    timestamp
    transactionHash
  }
}
```

### 3. Via RPC/Web3 (Off-chain)

```javascript
const viewContract = new ethers.Contract(
  VIEW_CONTRACT_ADDRESS,
  VIEW_CONTRACT_ABI,
  provider
);

// Get status enum (0 = Inactive, 1 = Active)
const status = await viewContract.getDataSetStatus(dataSetId);

console.log(`Dataset ${dataSetId} is ${status === 1 ? 'Active' : 'Inactive'}`);
```

## Implementation Details

### Status Calculation Logic

The status is calculated based on multiple factors:

```solidity
function getDataSetStatus(uint256 dataSetId) 
    returns (DataSetStatus status) 
{
    DataSetInfoView memory info = getDataSet(dataSetId);
    
    // Non-existent datasets are inactive
    if (info.pdpRailId == 0) {
        return DataSetStatus.Inactive;
    }
    
    // Check if proving is activated
    uint256 activationEpoch = provingActivationEpoch(dataSetId);
    bool hasProving = activationEpoch != 0;
    
    // Check if terminated
    bool isTerminated = info.pdpEndEpoch != 0;
    
    // Check if beyond lockup period
    bool isBeyondLockup = false;
    if (isTerminated) {
        uint256 DEFAULT_LOCKUP_PERIOD = 2880 * 30; // 1 month
        uint256 lockupEndEpoch = info.pdpEndEpoch + DEFAULT_LOCKUP_PERIOD;
        isBeyondLockup = block.number > lockupEndEpoch;
    }
    
    // Inactive if: no proving OR beyond lockup
    if (!hasProving || isBeyondLockup) {
        return DataSetStatus.Inactive;
    }
    
    return DataSetStatus.Active;
}
```

### Key Constants

```solidity
uint256 constant DEFAULT_LOCKUP_PERIOD = 2880 * 30;  // ~1 month (86,400 epochs)
// Assuming 30-second epochs:
// 2880 epochs/day * 30 days = 86,400 epochs
```

## Use Cases

### 1. Client Dashboard

Display dataset status with appropriate UI:

```javascript
function getStatusBadge(status) {
  if (status === 'ACTIVE') {
    return {
      text: 'Active',
      color: 'green',
      description: 'Data is being actively proven and protected'
    };
  } else {
    return {
      text: 'Inactive',
      color: 'gray',
      description: 'No pieces added, terminated, or beyond lockup'
    };
  }
}
```

### 2. Monitoring & Alerts

Set up alerts based on status changes:

```javascript
subscription {
  dataSetStatusChanged(
    where: { dataSetId: "123" }
  ) {
    dataSetId
    oldStatus
    newStatus
    epoch
  }
}

// Alert when dataset becomes inactive
if (newStatus === 'INACTIVE' && oldStatus === 'ACTIVE') {
  sendAlert('Dataset terminated or expired');
}
```

### 3. Conditional Smart Contract Logic

```solidity
contract DataMarketplace {
    function purchaseData(uint256 dataSetId) external {
        // Only allow purchases for active datasets
        require(
            service.isDataSetActive(dataSetId),
            "Dataset must be active"
        );
        
        // Process purchase...
    }
}
```

### 4. Analytics & Reporting

```graphql
{
  # Count active vs inactive datasets
  activeCount: dataSets(where: { status: ACTIVE }) {
    totalCount
  }
  
  inactiveCount: dataSets(where: { status: INACTIVE }) {
    totalCount
  }
  
  # Recent status changes
  recentTransitions: dataSetStatusHistories(
    first: 10
    orderBy: timestamp
    orderDirection: desc
  ) {
    dataSetId
    newStatus
    timestamp
  }
}
```

## Edge Cases & Considerations

### 1. Status During Termination

When a dataset is terminated:
- Status immediately becomes `Inactive`
- Dataset remains queryable and readable
- PDP proving may continue during lockup period
- Payment rails settle during lockup

### 2. Beyond Lockup Period

After the lockup period expires:
- Status remains `Inactive`
- No more payments can be settled
- Dataset can be deleted by calling `dataSetDeleted`
- Metadata and pieces remain accessible until deletion

### 3. Empty Datasets

Datasets with no pieces:
- Always `Inactive`
- `provingActivationEpoch` = 0
- Can add pieces to transition to `Active`

### 4. Time-Based Transitions

The "beyond lockup" condition is time-based:
- No on-chain transaction triggers this transition
- Status changes automatically based on `block.number`
- No `DataSetStatusChanged` event is emitted for this transition
- Clients should periodically check status for terminated datasets

## Migration from Old Status System

### Old System (3 States)

```solidity
enum DataSetStatus {
    NotFound,    // 0
    Active,      // 1
    Terminating  // 2
}
```

### New System (2 States)

```solidity
enum DataSetStatus {
    Inactive,    // 0
    Active       // 1
}
```

### Mapping

| Old Status | New Status | Condition |
|------------|------------|-----------|
| `NotFound` | `Inactive` | Non-existent dataset |
| `Active` | `Active` | Has proving, not beyond lockup |
| `Active` | `Inactive` | No proving yet |
| `Terminating` | `Inactive` | Terminated, within or beyond lockup |

### Breaking Changes

⚠️ **Important**: This is a breaking change for systems checking status:
- Enum values have changed
- `NotFound` and `Terminating` are removed
- Both map to `Inactive`

Update your code:
```solidity
// OLD CODE ❌
if (status == DataSetStatus.NotFound) { ... }
if (status == DataSetStatus.Terminating) { ... }

// NEW CODE ✅
if (status == DataSetStatus.Inactive) {
    // Check additional conditions if needed
    (,, bool isTerminated, bool isBeyondLockup) = 
        service.getDataSetStatusDetails(dataSetId);
    
    if (isTerminated) { ... }
    if (isBeyondLockup) { ... }
}
```

## Best Practices

1. **Use Status for Business Logic**: Make decisions based on `Active` vs `Inactive`

2. **Use Details for Fine-Grained Control**: When you need to distinguish between different inactive states, use `getDataSetStatusDetails()`

3. **Monitor Status Changes**: Subscribe to `DataSetStatusChanged` events or subgraph subscriptions

4. **Cache Appropriately**: Status can change over time (especially when reaching beyond lockup)

5. **Batch Queries**: Use subgraph for querying multiple datasets efficiently

6. **Handle Edge Cases**: Always check for edge cases like empty datasets or very old terminated datasets

## See Also

- [Integration Guide](./integration-guide.md) - How to integrate dataset status into your application
- [API Reference](../README.md) - Complete API documentation
- [Subgraph Schema](../../subgraph/schemas/schema.v1.graphql) - GraphQL schema definition

