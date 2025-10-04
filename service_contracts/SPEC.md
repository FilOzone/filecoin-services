# Filecoin Warm Storage Service Contract Specification

This document provides detailed technical specifications for the Filecoin Warm Storage Service contract, including payment rail behavior, data storage mechanics, and service provider operations.

## Overview

The Filecoin Warm Storage Service contract is a comprehensive storage service that integrates with multiple specialized contracts to provide secure, verifiable, and automatically paid decentralized storage:

### Core Contract Integrations

1. **[PDP (Proof of Data Possession)](https://github.com/FilOzone/pdp)** - Provides cryptographic proof verification
   - `PDPVerifier` - Validates storage proofs and manages data set lifecycle
   - Implements `PDPListener` interface to receive callbacks on data set events

2. **[Filecoin Services Payments](https://github.com/FilOzone/filecoin-services-payments)** - Handles automated payment streams
   - `Payments` contract - Manages payment rails, deposits, and settlements
   - Implements `IValidator` interface to customize payment validation logic

3. **Service Provider Registry** - Manages authorized storage providers
   - Tracks approved providers and their capabilities
   - Controls which providers can offer storage services

4. **[Session Key Registry](https://github.com/FilOzone/session-key-registry)** - Enables delegated operations
   - Allows users to authorize third parties to perform operations on their behalf
   - Supports more flexible user experience patterns

## Deal and Payment Rail Lifecycle

### Deal Duration

**Important**: Deals do **not** have an explicit end date or expiration time. A PDP deal remains active and your data continues to be stored as long as:

1. **The service provider continues submitting valid proofs** to the PDPVerifier contract
2. **The service provider does not manually call `deleteDataSet`** on the PDPVerifier contract
3. **Payment rails remain funded** (though they can go into debt - see below)

This means that once created, a deal continues indefinitely until manually terminated by either the client or service provider.

### Payment Rail Lifecycle

Similarly, **payment rails do not have an automatic end date**. Payment rails remain "alive" until explicitly terminated by either party through the termination functions in the payment contract.

#### Rail States

- **Active**: Rail is processing payments normally
- **In Debt**: Client has insufficient funds, but rail remains active waiting for top-up
- **Terminated**: Either party has called a termination function

#### Debt Behavior

When a client runs out of funds:
- **The payment rail goes into "debt"** rather than automatically terminating
- **Data storage continues** (subject to service provider policies)
- **Rails remain in debt until the client deposits more funds**
- **No automated file deletion occurs** - this is entirely up to service provider policies

### Manual Termination Process

Storage deals can only be terminated through explicit actions:

1. **`terminateDataSet`** (called by client or service provider):
   - Terminates ALL payment rails associated with the data set
   - Sets an `endEpoch` - the final epoch up to which the SP will be paid
   - After `endEpoch`, it becomes the SP's responsibility to clean up

2. **`deleteDataSet`** (called by service provider on PDPVerifier):
   - Removes the data set from the PDPVerifier contract
   - Cleans up on-chain state associated with the dataset
   - Should be called after the payment rail's `endEpoch` has passed

### Monitoring Funding Status

Clients and service providers can check funding status using:

```solidity
// Check account and rail funding status
payments.getAccountInfoIfSettled(clientAddress, railId);
```

This function provides comprehensive information about:
- Total account funds
- Rail-specific funding status  
- Whether a rail is in debt
- Estimated time remaining based on current balance and rate

## Payment Rail Renewal and Top-Up Behavior

This section addresses how pricing updates and fund deposits affect existing storage deals.

### Service Provider Pricing Updates

When a service provider updates their pricing after a payment rail is established, the impact on existing payment rates depends on the rail's current state:

#### Active Rails (Non-terminated)
- **Rate changes are allowed** only if the payer's account is fully settled (has sufficient funds to cover current lockup requirements)
- **Rate can be increased or decreased** by the service operator using `modifyRailPayment()`
- **Rate changes are queued** and take effect starting from the next block after the modification
- **Existing settlements** continue at the old rate until the rate change epoch

#### Terminated Rails  
- **Rate can only be decreased** (never increased)
- **Rate changes must occur** before the rail's maximum settlement epoch
- This protects payers from unexpected cost increases on completed deals

#### Rate Change Process
```solidity
// Service provider updates rate through the operator
payments.modifyRailPayment(
    railId,           // The rail ID
    newRatePerEpoch,  // New payment rate (tokens per epoch)
    oneTimePayment    // Optional immediate payment (from fixed lockup)
);
```

### Client Top-Up Behavior

When a payer (client) deposits additional funds to their account, it affects their storage deal as follows:

#### What Happens When You Deposit More Funds

1. **Funds are added to account balance**: Additional deposits increase the payer's total `funds` in the payment system
2. **Extended service duration**: More funds allow the existing service to run longer at the current rate
3. **No automatic capacity increase**: Simply depositing funds doesn't increase storage capacity - that requires a rate change by the service provider

#### Duration vs. Capacity: Key Distinction

**Storage Duration** (how long data is stored):
- **Estimated duration**: `Available Funds ÷ Payment Rate = Duration in epochs`
- **Important**: When funds run out, storage doesn't automatically stop, the rail goes into debt (see [Deal and Payment Rail Lifecycle](#deal-and-payment-rail-lifecycle))
- **Top-ups extend duration** at the current storage capacity and bring rails out of debt
- Example: If you're paying 10 tokens/epoch for current storage, depositing 100 tokens extends service by 10 epochs

**Storage Capacity** (how much data is stored):
- Determined by the service provider's rate calculation based on data size
- **Requires service provider to update the rate** via `updatePaymentRates()` when data size changes
- Example: Adding more files requires the service to recalculate and update the rate based on new total bytes

#### Top-Up Process

Clients can top-up their account using several methods:

```solidity
// Standard deposit
payments.deposit(tokenAddress, clientAddress, amount);

// Deposit with EIP-2612 permit (no prior approval needed)  
payments.depositWithPermit(token, to, amount, deadline, v, r, s);

// Deposit with ERC-3009 authorization (off-chain signature)
payments.depositWithAuthorization(token, to, amount, validAfter, validBefore, nonce, v, r, s);
```

#### Lockup and Available Funds

The payment system maintains:
- **Total funds**: All deposited tokens  
- **Lockup current**: Funds reserved for active rails (unavailable for withdrawal)
- **Available balance**: `Total funds - Lockup current` (can be withdrawn)

When you top-up:
- New funds are added to total funds
- The lockup amount stays the same (unless rail parameters change)
- Your available balance increases, extending how long you can pay the current rate

### Practical Examples

**Scenario 1: Service provider increases pricing**
- You have a rail paying 5 tokens/epoch for 100GB storage
- Service provider updates rate to 7 tokens/epoch  
- Your existing funds now last for fewer epochs at the higher rate
- You may need to deposit more funds to maintain the same service duration

**Scenario 2: You want to store more data**
- You add 50GB more files to your dataset
- Service provider detects the change and updates the rate (via `updatePaymentRates()`)
- Your payment rate increases to cover the additional storage
- You may need to deposit more funds or accept shorter service duration

**Scenario 3: Simple top-up for duration extension**
- Current rate: 5 tokens/epoch, current balance: 50 tokens (10 epochs remaining)
- You deposit 100 more tokens  
- New balance: 150 tokens (30 epochs remaining at same rate)
- Storage capacity remains unchanged
- Use `getAccountInfoIfSettled()` to monitor your funding status and remaining time

**Scenario 4: Handling a rail in debt**
- Your rail has gone into debt due to insufficient funds
- Data storage continues (subject to service provider policies)
- You top-up with 200 tokens to bring the rail current and extend service
- Rail transitions from "debt" state back to "active" state
