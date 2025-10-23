# Dataset Status Integration Guide

This guide shows you how to integrate dataset status checking into your applications, whether you're building a web UI, smart contract, SDK, or off-chain monitoring system.

## Table of Contents

- [For Frontend/SDK Developers](#for-frontendsdk-developers)
- [For Smart Contract Integrators](#for-smart-contract-integrators)
- [For Oracle & Off-chain Systems](#for-oracle--off-chain-systems)
- [Examples & Code Snippets](#examples--code-snippets)

---

## For Frontend/SDK Developers

### Quick Start

#### Using Subgraph (Recommended)

The subgraph provides the easiest and most efficient way to query dataset status:

```typescript
import { ApolloClient, InMemoryCache, gql } from '@apollo/client';

const client = new ApolloClient({
  uri: 'https://api.thegraph.com/subgraphs/name/your-subgraph',
  cache: new InMemoryCache(),
});

async function getDataSetStatus(dataSetId: string) {
  const query = gql`
    query GetDataSetStatus($id: Bytes!) {
      dataSet(id: $id) {
        setId
        status
        totalPieces
        pdpEndEpoch
        serviceProvider {
          name
          serviceProvider
        }
        updatedAt
      }
    }
  `;

  const { data } = await client.query({
    query,
    variables: { id: dataSetId },
  });

  return data.dataSet;
}

// Usage
const dataset = await getDataSetStatus('0x1234...');
console.log(`Dataset is ${dataset.status}`); // "ACTIVE" or "INACTIVE"
```

#### Using Web3/Ethers (Direct Contract Call)

```typescript
import { ethers } from 'ethers';
import ViewContractABI from './FilecoinWarmStorageServiceStateView.abi.json';

const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
const viewContract = new ethers.Contract(
  VIEW_CONTRACT_ADDRESS,
  ViewContractABI,
  provider
);

async function getDataSetStatus(dataSetId: number) {
  // Returns 0 for Inactive, 1 for Active
  const status = await viewContract.getDataSetStatus(dataSetId);
  return status === 1 ? 'ACTIVE' : 'INACTIVE';
}

// Get detailed information
async function getDataSetDetails(dataSetId: number) {
  const info = await viewContract.getDataSet(dataSetId);
  const status = await viewContract.getDataSetStatus(dataSetId);
  
  return {
    dataSetId,
    status: status === 1 ? 'ACTIVE' : 'INACTIVE',
    payer: info.payer,
    payee: info.payee,
    serviceProvider: info.serviceProvider,
    pdpEndEpoch: info.pdpEndEpoch.toString(),
    isTerminated: info.pdpEndEpoch.gt(0),
  };
}
```

### Real-Time Status Updates

#### Using Subgraph Subscriptions (WebSocket)

```typescript
import { GraphQLWsLink } from '@apollo/client/link/subscriptions';
import { createClient } from 'graphql-ws';

const wsLink = new GraphQLWsLink(
  createClient({
    url: 'wss://api.thegraph.com/subgraphs/name/your-subgraph',
  })
);

// Subscribe to status changes
const subscription = gql`
  subscription OnStatusChange {
    dataSetStatusHistories(
      orderBy: timestamp
      orderDirection: desc
      first: 1
    ) {
      dataSetId
      oldStatus
      newStatus
      epoch
      timestamp
      transactionHash
    }
  }
`;

client.subscribe({ query: subscription }).subscribe({
  next: ({ data }) => {
    const change = data.dataSetStatusHistories[0];
    console.log(`Dataset ${change.dataSetId} changed from ${change.oldStatus} to ${change.newStatus}`);
    
    // Update UI, send notification, etc.
    handleStatusChange(change);
  },
});
```

#### Using Contract Events

```typescript
// Listen for DataSetStatusChanged events
const contract = new ethers.Contract(
  SERVICE_CONTRACT_ADDRESS,
  ServiceContractABI,
  provider
);

contract.on(
  'DataSetStatusChanged',
  (dataSetId, oldStatus, newStatus, epoch, event) => {
    console.log({
      dataSetId: dataSetId.toString(),
      oldStatus: oldStatus === 0 ? 'INACTIVE' : 'ACTIVE',
      newStatus: newStatus === 0 ? 'INACTIVE' : 'ACTIVE',
      epoch: epoch.toString(),
      txHash: event.transactionHash,
    });
    
    // Update your UI
    updateDataSetInUI(dataSetId, newStatus);
  }
);
```

### UI Components

#### React Status Badge Component

```tsx
import React from 'react';

interface StatusBadgeProps {
  status: 'ACTIVE' | 'INACTIVE';
  pdpEndEpoch?: bigint;
  currentEpoch?: bigint;
}

export const DataSetStatusBadge: React.FC<StatusBadgeProps> = ({
  status,
  pdpEndEpoch,
  currentEpoch,
}) => {
  const getStatusDetails = () => {
    if (status === 'ACTIVE') {
      // Check if terminated to show different message
      if (pdpEndEpoch && pdpEndEpoch > 0n) {
        return {
          label: 'Active (Terminated)',
          color: 'bg-yellow-100 text-yellow-800',
          icon: '⏸',
          description: 'Has data, service terminated',
        };
      }
      
      return {
        label: 'Active',
        color: 'bg-green-100 text-green-800',
        icon: '✓',
        description: 'Data is being actively proven',
      };
    }
    
    return {
      label: 'Inactive',
      color: 'bg-gray-100 text-gray-800',
      icon: '○',
      description: 'No pieces added yet',
    };
  };
  
  const { label, color, icon, description } = getStatusDetails();
  
  return (
    <div className="flex items-center gap-2">
      <span className={`px-3 py-1 rounded-full text-sm font-medium ${color}`}>
        {icon} {label}
      </span>
      <span className="text-sm text-gray-500">{description}</span>
    </div>
  );
};
```

#### Vue Status Component

```vue
<template>
  <div class="status-badge" :class="statusClass">
    <span class="icon">{{ statusIcon }}</span>
    <span class="label">{{ statusLabel }}</span>
    <span class="description">{{ statusDescription }}</span>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

const props = defineProps<{
  status: 'ACTIVE' | 'INACTIVE';
  pdpEndEpoch?: bigint;
  totalPieces?: number;
}>();

const statusDetails = computed(() => {
  if (props.status === 'ACTIVE') {
    return {
      label: 'Active',
      icon: '✓',
      class: 'active',
      description: 'Proving & protected',
    };
  }
  
  if (props.totalPieces === 0) {
    return {
      label: 'Empty',
      icon: '○',
      class: 'empty',
      description: 'No pieces added',
    };
  }
  
  if (props.pdpEndEpoch && props.pdpEndEpoch > 0n) {
    return {
      label: 'Terminated',
      icon: '⏸',
      class: 'terminated',
      description: 'Service ended',
    };
  }
  
  return {
    label: 'Inactive',
    icon: '○',
    class: 'inactive',
    description: 'Not active',
  };
});

const statusLabel = computed(() => statusDetails.value.label);
const statusIcon = computed(() => statusDetails.value.icon);
const statusClass = computed(() => statusDetails.value.class);
const statusDescription = computed(() => statusDetails.value.description);
</script>

<style scoped>
.status-badge {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem 1rem;
  border-radius: 9999px;
  font-size: 0.875rem;
}

.status-badge.active {
  background: #d1fae5;
  color: #065f46;
}

.status-badge.terminated {
  background: #fef3c7;
  color: #92400e;
}

.status-badge.inactive,
.status-badge.empty {
  background: #f3f4f6;
  color: #374151;
}
</style>
```

### Polling Strategy

For applications that need to monitor dataset status changes:

```typescript
class DataSetStatusMonitor {
  private pollingInterval: NodeJS.Timeout | null = null;
  private onStatusChange: (dataSetId: string, newStatus: string) => void;
  
  constructor(
    private dataSetIds: string[],
    private checkIntervalMs: number = 60000, // 1 minute
    onStatusChange: (dataSetId: string, newStatus: string) => void
  ) {
    this.onStatusChange = onStatusChange;
  }
  
  async checkStatus(dataSetId: string) {
    const dataset = await getDataSetStatus(dataSetId);
    return dataset.status;
  }
  
  async checkAllStatuses() {
    for (const dataSetId of this.dataSetIds) {
      const newStatus = await this.checkStatus(dataSetId);
      // Compare with cached status and trigger callback if changed
      this.onStatusChange(dataSetId, newStatus);
    }
  }
  
  start() {
    this.pollingInterval = setInterval(
      () => this.checkAllStatuses(),
      this.checkIntervalMs
    );
  }
  
  stop() {
    if (this.pollingInterval) {
      clearInterval(this.pollingInterval);
      this.pollingInterval = null;
    }
  }
}

// Usage
const monitor = new DataSetStatusMonitor(
  ['0x1234...', '0x5678...'],
  60000, // Check every minute
  (dataSetId, newStatus) => {
    console.log(`Dataset ${dataSetId} is now ${newStatus}`);
    // Update UI, send notification, etc.
  }
);

monitor.start();
```

---

## For Smart Contract Integrators

### Basic Integration

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FilecoinWarmStorageServiceStateLibrary} from "./lib/FilecoinWarmStorageServiceStateLibrary.sol";
import {FilecoinWarmStorageService} from "./FilecoinWarmStorageService.sol";

contract DataMarketplace {
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;
    
    FilecoinWarmStorageService public immutable storageService;
    
    constructor(FilecoinWarmStorageService _service) {
        storageService = _service;
    }
    
    /**
     * @notice Check if a dataset is active before allowing purchase
     */
    function purchaseDataAccess(uint256 dataSetId) external payable {
        // Only allow purchases for active datasets
        require(
            storageService.isDataSetActive(dataSetId),
            "Dataset must be active"
        );
        
        // Process purchase...
    }
    
    /**
     * @notice Get detailed information about a dataset
     */
    function getDataSetInfo(uint256 dataSetId) 
        external 
        view 
        returns (
            FilecoinWarmStorageService.DataSetStatus status,
            bool hasProving,
            bool isTerminated
        ) 
    {
        return storageService.getDataSetStatusDetails(dataSetId);
    }
}
```

### Advanced: Status-Based Pricing

```solidity
contract DynamicPricingMarket {
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;
    
    FilecoinWarmStorageService public immutable storageService;
    
    // Base price in wei
    uint256 public constant BASE_PRICE = 1 ether;
    
    /**
     * @notice Calculate price based on dataset status
     * @dev Active datasets cost more due to guaranteed availability
     */
    function getPrice(uint256 dataSetId) public view returns (uint256) {
        FilecoinWarmStorageService.DataSetStatus status = 
            storageService.getDataSetStatus(dataSetId);
        
        if (status == FilecoinWarmStorageService.DataSetStatus.Active) {
            // Premium price for active, proven data
            return BASE_PRICE;
        } else {
            // Discount for inactive data (may be terminated or empty)
            return BASE_PRICE / 2;
        }
    }
    
    function purchaseWithDynamicPricing(uint256 dataSetId) external payable {
        uint256 price = getPrice(dataSetId);
        require(msg.value >= price, "Insufficient payment");
        
        // Process purchase...
        
        // Refund excess
        if (msg.value > price) {
            payable(msg.sender).transfer(msg.value - price);
        }
    }
}
```

### Gas-Efficient Batch Checking

```solidity
contract BatchStatusChecker {
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;
    
    FilecoinWarmStorageService public immutable storageService;
    
    /**
     * @notice Check multiple datasets' status in one call
     * @dev More gas-efficient than calling individually
     */
    function batchCheckStatus(uint256[] calldata dataSetIds) 
        external 
        view 
        returns (FilecoinWarmStorageService.DataSetStatus[] memory statuses) 
    {
        statuses = new FilecoinWarmStorageService.DataSetStatus[](dataSetIds.length);
        
        for (uint256 i = 0; i < dataSetIds.length; i++) {
            statuses[i] = storageService.getDataSetStatus(dataSetIds[i]);
        }
    }
    
    /**
     * @notice Count active datasets from a list
     */
    function countActiveDataSets(uint256[] calldata dataSetIds) 
        external 
        view 
        returns (uint256 activeCount) 
    {
        for (uint256 i = 0; i < dataSetIds.length; i++) {
            if (storageService.isDataSetActive(dataSetIds[i])) {
                activeCount++;
            }
        }
    }
}
```

### Event Listener Pattern

```solidity
contract DataSetMonitor {
    FilecoinWarmStorageService public immutable storageService;
    
    mapping(uint256 => FilecoinWarmStorageService.DataSetStatus) public lastKnownStatus;
    
    event StatusMonitored(
        uint256 indexed dataSetId,
        FilecoinWarmStorageService.DataSetStatus status,
        uint256 timestamp
    );
    
    constructor(FilecoinWarmStorageService _service) {
        storageService = _service;
    }
    
    /**
     * @notice Manually trigger a status check and emit event
     * @dev Can be called by a keeper/automation system
     */
    function checkAndEmit(uint256 dataSetId) external {
        FilecoinWarmStorageService.DataSetStatus status = 
            storageService.getDataSetStatus(dataSetId);
        
        lastKnownStatus[dataSetId] = status;
        
        emit StatusMonitored(dataSetId, status, block.timestamp);
    }
}
```

---

## For Oracle & Off-chain Systems

### Chainlink Keeper Integration

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {FilecoinWarmStorageServiceStateLibrary} from "./lib/FilecoinWarmStorageServiceStateLibrary.sol";

contract DataSetStatusKeeper is AutomationCompatibleInterface {
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;
    
    FilecoinWarmStorageService public immutable storageService;
    uint256[] public monitoredDataSets;
    
    event StatusCheckPerformed(uint256 indexed dataSetId, uint256 timestamp);
    event DataSetBecameInactive(uint256 indexed dataSetId, uint256 timestamp);
    
    constructor(
        FilecoinWarmStorageService _service,
        uint256[] memory _dataSetIds
    ) {
        storageService = _service;
        monitoredDataSets = _dataSetIds;
    }
    
    function checkUpkeep(bytes calldata /* checkData */)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Check if any monitored datasets need attention
        for (uint256 i = 0; i < monitoredDataSets.length; i++) {
            uint256 dataSetId = monitoredDataSets[i];
            
            if (!storageService.isDataSetActive(dataSetId)) {
                upkeepNeeded = true;
                performData = abi.encode(dataSetId);
                break;
            }
        }
    }
    
    function performUpkeep(bytes calldata performData) external override {
        uint256 dataSetId = abi.decode(performData, (uint256));
        
        // Verify the dataset is indeed inactive
        require(
            !storageService.isDataSetActive(dataSetId),
            "Dataset is active"
        );
        
        emit DataSetBecameInactive(dataSetId, block.timestamp);
        emit StatusCheckPerformed(dataSetId, block.timestamp);
        
        // Perform actions (e.g., notify admin, pause related operations)
    }
}
```

### Python Monitoring Script

```python
from web3 import Web3
from typing import List, Dict
import time
import logging

class DataSetStatusMonitor:
    def __init__(
        self,
        rpc_url: str,
        view_contract_address: str,
        view_contract_abi: List[Dict],
        check_interval: int = 60
    ):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.contract = self.w3.eth.contract(
            address=view_contract_address,
            abi=view_contract_abi
        )
        self.check_interval = check_interval
        self.logger = logging.getLogger(__name__)
    
    def get_status(self, dataset_id: int) -> str:
        """Get current status of a dataset"""
        status_enum = self.contract.functions.getDataSetStatus(dataset_id).call()
        return "ACTIVE" if status_enum == 1 else "INACTIVE"
    
    def get_detailed_status(self, dataset_id: int) -> Dict:
        """Get detailed information about a dataset"""
        info = self.contract.functions.getDataSet(dataset_id).call()
        status = self.get_status(dataset_id)
        
        return {
            "dataSetId": dataset_id,
            "status": status,
            "payer": info[3],  # Based on DataSetInfoView struct
            "payee": info[4],
            "serviceProvider": info[5],
            "pdpEndEpoch": info[8],
            "isTerminated": info[8] > 0,
        }
    
    def monitor_datasets(
        self,
        dataset_ids: List[int],
        on_status_change=None
    ):
        """Monitor datasets and call callback on status change"""
        last_statuses = {}
        
        while True:
            for dataset_id in dataset_ids:
                try:
                    status = self.get_status(dataset_id)
                    
                    if dataset_id not in last_statuses:
                        last_statuses[dataset_id] = status
                        self.logger.info(f"Dataset {dataset_id} initial status: {status}")
                    elif last_statuses[dataset_id] != status:
                        self.logger.warning(
                            f"Dataset {dataset_id} status changed: "
                            f"{last_statuses[dataset_id]} -> {status}"
                        )
                        last_statuses[dataset_id] = status
                        
                        if on_status_change:
                            on_status_change(dataset_id, status)
                
                except Exception as e:
                    self.logger.error(f"Error checking dataset {dataset_id}: {e}")
            
            time.sleep(self.check_interval)

# Usage
def handle_status_change(dataset_id: int, new_status: str):
    print(f"Alert: Dataset {dataset_id} is now {new_status}")
    # Send email, webhook, etc.

monitor = DataSetStatusMonitor(
    rpc_url="https://api.calibration.node.glif.io/rpc/v1",
    view_contract_address="0x...",
    view_contract_abi=[...],
    check_interval=60
)

monitor.monitor_datasets(
    dataset_ids=[1, 2, 3, 4, 5],
    on_status_change=handle_status_change
)
```

### Node.js Monitoring Service

```typescript
import { ethers } from 'ethers';
import { createClient } from '@urql/core';
import fetch from 'node-fetch';

class DataSetMonitoringService {
  private provider: ethers.providers.JsonRpcProvider;
  private viewContract: ethers.Contract;
  private subgraphClient: any;
  
  constructor(
    rpcUrl: string,
    viewContractAddress: string,
    viewContractAbi: any[],
    subgraphUrl: string
  ) {
    this.provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    this.viewContract = new ethers.Contract(
      viewContractAddress,
      viewContractAbi,
      this.provider
    );
    
    this.subgraphClient = createClient({
      url: subgraphUrl,
      fetch,
    });
  }
  
  /**
   * Get all datasets for a payer
   */
  async getPayerDatasets(payerAddress: string) {
    const query = `
      query GetPayerDatasets($payer: Bytes!) {
        dataSets(where: { payer: $payer }) {
          setId
          status
          totalPieces
          pdpEndEpoch
          updatedAt
        }
      }
    `;
    
    const result = await this.subgraphClient
      .query(query, { payer: payerAddress.toLowerCase() })
      .toPromise();
    
    return result.data.dataSets;
  }
  
  /**
   * Monitor datasets and send alerts
   */
  async monitorAndAlert(
    payerAddress: string,
    webhookUrl: string
  ) {
    const datasets = await this.getPayerDatasets(payerAddress);
    
    for (const dataset of datasets) {
      if (dataset.status === 'INACTIVE' && dataset.totalPieces > 0) {
        // Dataset has pieces but is inactive - alert!
        await this.sendAlert(webhookUrl, {
          type: 'DATASET_INACTIVE',
          dataSetId: dataset.setId,
          message: `Dataset ${dataset.setId} is inactive but has ${dataset.totalPieces} pieces`,
          timestamp: new Date().toISOString(),
        });
      }
    }
  }
  
  private async sendAlert(webhookUrl: string, data: any) {
    await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
  }
}

// Usage
const monitor = new DataSetMonitoringService(
  'https://api.calibration.node.glif.io/rpc/v1',
  '0x...',
  viewContractAbi,
  'https://api.thegraph.com/subgraphs/name/your-subgraph'
);

// Run every hour
setInterval(async () => {
  await monitor.monitorAndAlert(
    '0xPayerAddress...',
    'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
  );
}, 3600000);
```

---

## Examples & Code Snippets

### Complete Example: Dataset Dashboard

```typescript
// Full example of a dataset dashboard component
import React, { useEffect, useState } from 'react';
import { useQuery, gql } from '@apollo/client';

const GET_DATASETS = gql`
  query GetDatasets($payer: Bytes!) {
    dataSets(where: { payer: $payer }) {
      setId
      status
      totalPieces
      totalDataSize
      pdpEndEpoch
      serviceProvider {
        name
      }
      statusHistory(first: 1, orderBy: timestamp, orderDirection: desc) {
        newStatus
        timestamp
      }
    }
  }
`;

export const DatasetDashboard = ({ payerAddress }: { payerAddress: string }) => {
  const { loading, error, data } = useQuery(GET_DATASETS, {
    variables: { payer: payerAddress.toLowerCase() },
    pollInterval: 60000, // Refresh every minute
  });
  
  if (loading) return <div>Loading datasets...</div>;
  if (error) return <div>Error: {error.message}</div>;
  
  const activeCount = data.dataSets.filter(ds => ds.status === 'ACTIVE').length;
  const inactiveCount = data.dataSets.length - activeCount;
  
  return (
    <div className="dashboard">
      <div className="stats">
        <div className="stat">
          <h3>{activeCount}</h3>
          <p>Active Datasets</p>
        </div>
        <div className="stat">
          <h3>{inactiveCount}</h3>
          <p>Inactive Datasets</p>
        </div>
      </div>
      
      <table className="datasets-table">
        <thead>
          <tr>
            <th>ID</th>
            <th>Status</th>
            <th>Pieces</th>
            <th>Size</th>
            <th>Provider</th>
            <th>Last Updated</th>
          </tr>
        </thead>
        <tbody>
          {data.dataSets.map(dataset => (
            <tr key={dataset.setId}>
              <td>{dataset.setId}</td>
              <td>
                <StatusBadge status={dataset.status} />
              </td>
              <td>{dataset.totalPieces}</td>
              <td>{formatBytes(dataset.totalDataSize)}</td>
              <td>{dataset.serviceProvider.name}</td>
              <td>
                {dataset.statusHistory[0] && 
                  formatTimestamp(dataset.statusHistory[0].timestamp)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
};

function formatBytes(bytes: string): string {
  const num = BigInt(bytes);
  if (num < 1024n) return `${num} B`;
  if (num < 1024n * 1024n) return `${num / 1024n} KB`;
  if (num < 1024n * 1024n * 1024n) return `${num / (1024n * 1024n)} MB`;
  return `${num / (1024n * 1024n * 1024n)} GB`;
}

function formatTimestamp(timestamp: string): string {
  return new Date(Number(timestamp) * 1000).toLocaleString();
}
```

## Best Practices

1. **Cache Aggressively**: Status doesn't change often, cache for 1-5 minutes
2. **Use Subgraph When Possible**: More efficient than direct RPC calls
3. **Batch Queries**: Query multiple datasets in one request
4. **Handle Errors Gracefully**: Network issues, contract upgrades, etc.
5. **Monitor Status Changes**: Subscribe to status change events for real-time updates
6. **Subscribe to Events**: Real-time updates are more efficient than polling
7. **Test Edge Cases**: Empty datasets, terminated datasets, deleted datasets

## Troubleshooting

### Dataset shows as INACTIVE but should be ACTIVE

Check:
1. Has proving started? (`provingActivationEpoch` > 0)
2. If proving has started, the dataset should be ACTIVE
3. If dataset is terminated (`pdpEndEpoch` > 0) but has pieces, it will still show as ACTIVE

### Status not updating in UI

Check:
1. Cache invalidation strategy
2. Subgraph indexing delay (usually < 1 minute)
3. Polling interval (if using polling)
4. Event subscription connection

### Gas costs too high

Solutions:
1. Use subgraph instead of RPC calls
2. Batch multiple status checks
3. Cache results on your server
4. Use view functions (already gas-free, but may have RPC limits)

## See Also

- [Dataset Lifecycle Documentation](./dataset-lifecycle.md)
- [API Reference](../README.md)
- [Subgraph API](../../subgraph/API.md)

