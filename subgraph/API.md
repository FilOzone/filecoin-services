# Pandora - GraphQL API Documentation

This document provides a comprehensive guide to the GraphQL API for the Pandora subgraph. It includes query examples, available parameters, and entity relationships to help you effectively interact with the Pandora Service data.

## Table of Contents

- [Overview](#overview)
- [Common Query Parameters](#common-query-parameters)
- [Entity Relationships](#entity-relationships)
- [Query Examples](#query-examples)
  - [Providers](#providers)
  - [Proof Sets](#proof-sets)
  - [Roots](#roots)
  - [Rails](#rails)
  - [Rate Change Queue](#rate-change-queue)
- [Advanced Queries](#advanced-queries)
- [Integrating with the API](#integrating-with-the-api)
  - [GraphQL Request](#graphql-request)
  - [Apollo Client](#apollo-client)
  - [urql](#urql)
  - [fetch API](#fetch-api)
  - [axios](#axios)

## Overview

The Pandora subgraph indexes data from the Pandora Service on the Filecoin network. It provides structured access to providers, proof sets, roots, and proof set Rails.

## Common Query Parameters

Most queries support the following parameters:

| Parameter        | Description                              | Example                     |
| ---------------- | ---------------------------------------- | --------------------------- |
| `first`          | Number of results to return (pagination) | `first: 10`                 |
| `skip`           | Number of results to skip (pagination)   | `skip: 20`                  |
| `orderBy`        | Field to order results by                | `orderBy: createdAt`        |
| `orderDirection` | Direction of ordering (`asc` or `desc`)  | `orderDirection: desc`      |
| `where`          | Filter conditions                        | `where: { isActive: true }` |

## Entity Relationships

Understanding the relationships between entities helps in constructing effective queries:

- **Provider** → **ProofSet**: One-to-many (A provider can have multiple proof sets)
- **ProofSet** → **Root**: One-to-many (A proof set can have multiple roots)
- **ProofSet** → **Rail**: One-to-one (A proof set can have one rail)
- **Rail** → **RateChangeQueue**: One-to-many (A rail can have multiple rate changes)
- **ProofSet** → **FaultRecord**: One-to-many (A proof set can have multiple fault records)
- **Root** → **FaultRecord**: Many-to-many (Multiple roots can be in multiple fault records)

## Query Examples

### Providers

Providers are entities that manage proof sets in the PDP system.

#### Query All Providers

```graphql
query AllProviders($first: Int, $skip: Int) {
  providers(
    first: $first
    skip: $skip
    orderBy: createdAt
    orderDirection: desc
  ) {
    id
    address
    totalDataSize
    totalProofSets
    totalRoots
    totalFaultedPeriods
    totalFaultedRoots
    createdAt
  }
}
```

#### Query Provider by ID

```graphql
query ProviderById($providerId: ID!) {
  provider(id: $providerId) {
    id
    address
    totalDataSize
    totalProofSets
    totalRoots
    totalFaultedPeriods
    totalFaultedRoots
    createdAt
    updatedAt
    blockNumber
  }
}
```

#### Query Provider with Proof Sets

```graphql
query ProviderWithProofSets($providerId: ID!, $first: Int, $skip: Int) {
  provider(id: $providerId) {
    id
    address
    totalDataSize
    totalProofSets
    totalRoots
    totalFaultedRoots
    totalFaultedPeriods
    createdAt
    proofSets(
      first: $first
      skip: $skip
      orderBy: createdAt
      orderDirection: desc
    ) {
      id
      setId
      isActive
      totalDataSize
      totalRoots
      createdAt
      lastProvenEpoch
    }
  }
}
```

#### Filter Providers by Criteria

```graphql
query FilteredProviders($minDataSize: BigInt) {
  providers(
    where: { totalDataSize_gte: $minDataSize }
    orderBy: totalDataSize
    orderDirection: desc
    first: 10
  ) {
    id
    address
    totalDataSize
    totalProofSets
    createdAt
  }
}
```

### Proof Sets

Proof Sets are collections of roots that providers maintain and prove possession of.

#### Query All Proof Sets

```graphql
query AllProofSets($first: Int, $skip: Int) {
  proofSets(
    first: $first
    skip: $skip
    orderBy: createdAt
    orderDirection: desc
  ) {
    id
    setId
    isActive
    totalRoots
    totalProofs
    totalDataSize
    createdAt
    owner {
      address
    }
  }
}
```

#### Query Proof Set by ID

```graphql
query ProofSetById($proofSetId: ID!) {
  proofSet(id: $proofSetId) {
    id
    setId
    isActive
    owner {
      id
      address
    }
    leafCount
    challengeRange
    lastProvenEpoch
    nextChallengeEpoch
    totalRoots
    totalDataSize
    totalProofs
    totalProvedRoots
    totalFeePaid
    totalFaultedPeriods
    totalFaultedRoots
    createdAt
    updatedAt
    blockNumber
  }
}
```

#### Query Proof Set with Roots

```graphql
query ProofSetWithRoots($proofSetId: ID!, $first: Int, $skip: Int) {
  proofSet(id: $proofSetId) {
    id
    setId
    isActive
    totalRoots
    totalDataSize
    roots(first: $first, skip: $skip, orderBy: rootId, orderDirection: desc) {
      id
      rootId
      rawSize
      cid
      removed
      totalProofsSubmitted
      totalPeriodsFaulted
      lastProvenEpoch
      lastProvenAt
      createdAt
    }
  }
}
```

#### Filter Proof Sets by Status

```graphql
query ActiveProofSets($first: Int) {
  proofSets(
    where: { isActive: true }
    orderBy: totalDataSize
    orderDirection: desc
    first: $first
  ) {
    id
    setId
    totalRoots
    totalDataSize
    createdAt
    owner {
      address
    }
  }
}
```

### Roots

Roots represent data commitments within proof sets.

#### Query All Roots

```graphql
query AllRoots($first: Int, $skip: Int) {
  roots(first: $first, skip: $skip, orderBy: createdAt, orderDirection: desc) {
    id
    rootId
    setId
    rawSize
    cid
    removed
    totalProofsSubmitted
    totalPeriodsFaulted
    createdAt
    proofSet {
      id
      setId
    }
  }
}
```

#### Query Root by ID

```graphql
query RootById($rootId: ID!) {
  root(id: $rootId) {
    id
    rootId
    setId
    rawSize
    leafCount
    cid
    removed
    totalProofsSubmitted
    totalPeriodsFaulted
    lastProvenEpoch
    lastProvenAt
    lastFaultedEpoch
    lastFaultedAt
    createdAt
    updatedAt
    blockNumber
    proofSet {
      id
      setId
      owner {
        address
      }
    }
  }
}
```

#### Filter Roots by Criteria

```graphql
query FilteredRoots($minSize: BigInt, $isRemoved: Boolean) {
  roots(
    where: { rawSize_gte: $minSize, removed: $isRemoved }
    orderBy: rawSize
    orderDirection: desc
    first: 10
  ) {
    id
    rootId
    setId
    rawSize
    cid
    createdAt
    proofSet {
      id
      owner {
        address
      }
    }
  }
}
```

### Rails

Rails represent payment channels associated with proof sets.

#### Query All Rails

```graphql
query AllRails($first: Int, $skip: Int) {
  rails(first: $first, skip: $skip, orderBy: createdAt, orderDirection: desc) {
    id
    railId
    token
    from
    to
    operator
    arbiter
    paymentRate
    lockupPeriod
    lockupFixed
    settledUpto
    endEpoch
    queueLength
    proofSet {
      id
      setId
    }
  }
}
```

#### Query Rail by ID

```graphql
query RailById($railId: ID!) {
  rail(id: $railId) {
    id
    railId
    token
    from
    to
    operator
    arbiter
    paymentRate
    lockupPeriod
    lockupFixed
    settledUpto
    endEpoch
    queueLength
    proofSet {
      id
      setId
      owner {
        address
      }
    }
    rateChangeQueue {
      id
      untilEpoch
      rate
    }
  }
}
```

#### Query Rails by Client Address

```graphql
query RailsByClient($clientAddress: Bytes!) {
  rails(
    where: { from: $clientAddress }
    orderBy: createdAt
    orderDirection: desc
  ) {
    id
    railId
    token
    to
    paymentRate
    lockupPeriod
    lockupFixed
    settledUpto
    endEpoch
    proofSet {
      id
      setId
      metadata
    }
  }
}
```

#### Query Rails by Provider Address

```graphql
query RailsByProvider($providerAddress: Bytes!) {
  rails(
    where: { to: $providerAddress }
    orderBy: createdAt
    orderDirection: desc
  ) {
    id
    railId
    token
    from
    paymentRate
    lockupPeriod
    lockupFixed
    settledUpto
    endEpoch
    proofSet {
      id
      setId
      metadata
    }
  }
}
```

#### Filter Rails by Payment Rate

```graphql
query HighPaymentRails($minRate: BigInt!) {
  rails(
    where: { paymentRate_gte: $minRate }
    orderBy: paymentRate
    orderDirection: desc
    first: 10
  ) {
    id
    railId
    token
    from
    to
    paymentRate
    lockupPeriod
    lockupFixed
    proofSet {
      id
      setId
    }
  }
}
```

### Rate Change Queue

Rate Change Queue entries represent scheduled payment rate changes for Rails.

#### Query All Rate Changes

```graphql
query AllRateChanges($first: Int, $skip: Int) {
  rateChangeQueues(
    first: $first
    skip: $skip
    orderBy: untilEpoch
    orderDirection: asc
  ) {
    id
    untilEpoch
    rate
    rail {
      id
      railId
      from
      to
    }
  }
}
```

#### Query Rate Changes for a Rail

```graphql
query RateChangesForRail($railId: ID!) {
  rail(id: $railId) {
    id
    railId
    paymentRate
    from
    to
    rateChangeQueue {
      id
      untilEpoch
      rate
    }
  }
}
```

#### Query Upcoming Rate Changes

```graphql
query UpcomingRateChanges($currentEpoch: BigInt!) {
  rateChangeQueues(
    where: { untilEpoch_gt: $currentEpoch }
    orderBy: untilEpoch
    orderDirection: asc
    first: 20
  ) {
    id
    untilEpoch
    rate
    rail {
      id
      railId
      paymentRate
      from
      to
      proofSet {
        id
        setId
      }
    }
  }
}
```

## Advanced Queries

### Combined Provider and Proof Set Data

```graphql
query ProviderWithDetailedProofSets($providerId: ID!, $first: Int, $skip: Int) {
  provider(id: $providerId) {
    id
    address
    totalDataSize
    totalProofSets
    totalRoots
    totalFaultedRoots
    totalFaultedPeriods
    proofSets(
      first: $first
      skip: $skip
      orderBy: createdAt
      orderDirection: desc
    ) {
      id
      setId
      isActive
      totalRoots
      totalDataSize
      totalProofs
      totalProvedRoots
      totalFaultedPeriods
      lastProvenEpoch
      nextChallengeEpoch
      createdAt
      roots(first: 5, orderBy: rootId, orderDirection: desc) {
        id
        rootId
        rawSize
        cid
        removed
        lastProvenEpoch
      }
    }
    weeklyProviderActivities(first: 4, orderBy: id, orderDirection: desc) {
      id
      totalRootsAdded
      totalDataSizeAdded
      totalProofs
    }
  }
}
```

### Search by Provider or Proof Set ID

```graphql
query Search($providerId: ID, $proofSetId: Bytes) {
  # Search for provider
  provider(id: $providerId) {
    id
    address
    totalProofSets
    totalDataSize
  }
  # Search for proof set
  proofSets(where: { id: $proofSetId }) {
    id
    setId
    isActive
    totalDataSize
    owner {
      address
    }
  }
}
```

### Search by client address for proof sets and their providers

```graphql
query Search($clientAddress: Bytes!) {
  proofSets(where: { clientAddr: $clientAddress }) {
    id
    setId
    isActive
    totalDataSize
    metadata
    owner {
      address
    }
  }
}
```

### Search by piece Cid for proof sets and their providers

This query returns the root and proof set details for a specific piece Cid.

_Need to parse cid before using it in the query._

```js
import { CID } from "multiformats/cid";

const rootCid = "baga6ea4seaq..........";
const parsedCid = CID.parse(rootCid); // "0x0181e203922020........."
```

_**Use parsedCid in the query.**_

```graphql
query Search($cid: Bytes!) {
  roots(where: { cid: $cid }) {
    id
    rootId
    setId
    rawSize
    cid
    metadata
    proofSet {
      id
      setId
      metadata
      owner {
        address
      }
    }
  }
}
```

## Integrating with the API

This section provides examples of how to integrate with the Pandora GraphQL API using various JavaScript/TypeScript libraries. Choose the approach that best fits your project's requirements.

### GraphQL Request

[graphql-request](https://github.com/prisma-labs/graphql-request) is a minimal GraphQL client supporting Node and browsers.

#### Installation

```bash
npm install graphql graphql-request
# or
yarn add graphql graphql-request
```

#### Usage Example

```typescript
import { request, gql } from "graphql-request";

const SUBGRAPH_URL =
  "https://api.goldsky.com/api/public/${YOUR_PROJECT_ID}/subgraphs/${YOUR_PROJECT_NAME}/${SUBGRAPH_DEPLOYMENT_VERSION}/gn";

const fetchProofSets = async () => {
  const query = gql`
    query GetProofSets($first: Int) {
      proofSets(first: $first, orderBy: createdAt, orderDirection: desc) {
        id
        setId
        isActive
        totalRoots
        totalDataSize
        metadata
        owner {
          address
        }
      }
    }
  `;

  const variables = {
    first: 10,
  };

  try {
    const data = await request(SUBGRAPH_URL, query, variables);
    console.log("ProofSets:", data.proofSets);
    return data.proofSets;
  } catch (error) {
    console.error("Error fetching proof sets:", error);
    return [];
  }
};

// Call the function
fetchProofSets();
```

### Apollo Client

[Apollo Client](https://www.apollographql.com/docs/react/) is a comprehensive state management library for JavaScript that enables you to manage both local and remote data with GraphQL.

#### Installation

```bash
npm install @apollo/client graphql
# or
yarn add @apollo/client graphql
```

#### Usage Example (React)

```typescript
import { ApolloClient, InMemoryCache, gql, useQuery } from '@apollo/client'
import { ApolloProvider } from '@apollo/client/react'

// Initialize Apollo Client
const client = new ApolloClient({
  uri: 'https://api.goldsky.com/api/public/${YOUR_PROJECT_ID}/subgraphs/${YOUR_PROJECT_NAME}/${SUBGRAPH_DEPLOYMENT_VERSION}/gn',
  cache: new InMemoryCache()
})

// Query definition
const GET_PROVIDER = gql`
  query GetProvider($providerId: ID!) {
    provider(id: $providerId) {
      id
      address
      totalProofSets
      totalDataSize
      totalRoots
      createdAt
      proofSets(first: 5, orderBy: createdAt, orderDirection: desc) {
        id
        setId
        isActive
        totalRoots
      }
    }
  }
`

// Component using the query
function ProviderDetails({ providerId }) {
  const { loading, error, data } = useQuery(GET_PROVIDER, {
    variables: { providerId },
  })

  if (loading) return <p>Loading...</p>
  if (error) return <p>Error: {error.message}</p>

  const provider = data.provider

  return (
    <div>
      <h2>Provider: {provider.address}</h2>
      <p>Total Proof Sets: {provider.totalProofSets.toString()}</p>
      <p>Total Data Size: {provider.totalDataSize.toString()} bytes</p>
      <h3>Recent Proof Sets</h3>
      <ul>
        {provider.proofSets.map(set => (
          <li key={set.id}>
            Set ID: {set.setId.toString()} -
            Roots: {set.totalRoots.toString()} -
            Status: {set.isActive ? 'Active' : 'Inactive'}
          </li>
        ))}
      </ul>
    </div>
  )
}

// Wrap your app with ApolloProvider
function App() {
  return (
    <ApolloProvider client={client}>
      <ProviderDetails providerId="0x1234..." />
    </ApolloProvider>
  )
}
```

### urql

[urql](https://formidable.com/open-source/urql/) is a highly customizable and versatile GraphQL client.

#### Installation

```bash
npm install urql graphql
# or
yarn add urql graphql
```

#### Usage Example (React)

```typescript
import { createClient, Provider, gql, useQuery } from 'urql'

// Create a client
const client = createClient({
  url: 'https://api.goldsky.com/api/public/${YOUR_PROJECT_ID}/subgraphs/${YOUR_PROJECT_NAME}/${SUBGRAPH_DEPLOYMENT_VERSION}/gn',
})

// Query definition
const GET_RAILS = gql`
  query GetRails($first: Int) {
    rails(first: $first, orderBy: createdAt, orderDirection: desc) {
      id
      railId
      token
      from
      to
      paymentRate
      lockupPeriod
      lockupFixed
      proofSet {
        id
        setId
      }
    }
  }
`

// Component using the query
function RailsList() {
  const [result] = useQuery({
    query: GET_RAILS,
    variables: { first: 10 },
  })

  const { data, fetching, error } = result

  if (fetching) return <p>Loading...</p>
  if (error) return <p>Error: {error.message}</p>

  return (
    <div>
      <h2>Rails</h2>
      <ul>
        {data.rails.map(rail => (
          <li key={rail.id}>
            Rail ID: {rail.railId.toString()}<br />
            From: {rail.from}<br />
            To: {rail.to}<br />
            Payment Rate: {rail.paymentRate.toString()}
          </li>
        ))}
      </ul>
    </div>
  )
}

// Wrap your app with Provider
function App() {
  return (
    <Provider value={client}>
      <RailsList />
    </Provider>
  )
}
```

### fetch API

You can also use the native `fetch` API for simple GraphQL requests without additional libraries.

#### Usage Example

```typescript
const SUBGRAPH_URL =
  "https://api.goldsky.com/api/public/${YOUR_PROJECT_ID}/subgraphs/${YOUR_PROJECT_NAME}/${SUBGRAPH_DEPLOYMENT_VERSION}/gn";

async function fetchFaultRecords() {
  const query = `
    query GetFaultRecords {
      faultRecords(first: 10, orderBy: createdAt, orderDirection: desc) {
        id
        proofSetId
        rootIds
        currentChallengeEpoch
        nextChallengeEpoch
        periodsFaulted
        deadline
        createdAt
        proofSet {
          id
          setId
        }
      }
    }
  `;

  try {
    const response = await fetch(SUBGRAPH_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query }),
    });

    const { data } = await response.json();
    console.log("Fault Records:", data.faultRecords);
    return data.faultRecords;
  } catch (error) {
    console.error("Error fetching fault records:", error);
    return [];
  }
}

// Call the function
fetchFaultRecords();
```

### axios

[axios](https://axios-http.com/) is a popular HTTP client that can be used for GraphQL requests.

#### Installation

```bash
npm install axios
# or
yarn add axios
```

#### Usage Example

```typescript
import axios from "axios";

const SUBGRAPH_URL =
  "https://api.goldsky.com/api/public/${YOUR_PROJECT_ID}/subgraphs/${YOUR_PROJECT_NAME}/${SUBGRAPH_DEPLOYMENT_VERSION}/gn";

async function searchByCid(cid) {
  const query = `
    query SearchByCid($cid: Bytes!) {
      roots(where: { cid: $cid }) {
        id
        rootId
        setId
        rawSize
        cid
        metadata
        proofSet {
          id
          setId
          metadata
          owner {
            address
          }
        }
      }
    }
  `;

  const variables = {
    cid: cid,
  };

  try {
    const response = await axios.post(SUBGRAPH_URL, {
      query,
      variables,
    });

    return response.data.data.roots;
  } catch (error) {
    console.error("Error searching by CID:", error);
    return [];
  }
}

// Example usage
async function findRootByCid() {
  // Note: In a real application, you would parse the CID first
  const roots = await searchByCid("0x0181e203922020.........");
  console.log("Found roots:", roots);
}

findRootByCid();
```

## Conclusion

This documentation provides a comprehensive overview of the GraphQL API for the Pandora subgraph. By using these query examples and understanding the entity relationships, you can effectively interact with and analyze data from the Proof of Data Possession protocol on the Filecoin network.

For more information on how to deploy your own subgraph, refer to the [Deployment Guide](./README.md).
