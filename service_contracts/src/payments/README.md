# Filecoin Pay

The Filecoin Pay Payments contract enables ERC20 token payment flows through "rails" - automated payment channels between payers and recipients. The contract supports continuous rate based payments, one-time transfers, and payment validation during settlement.

- [Deployment Info](#deployment-info)
- [Key Concepts](#key-concepts)
  - [Account](#account)
  - [Rail](#rail)
  - [Validator](#validator)
  - [Operator](#operator)
  - [Per-Rail Lockup: The Guarantee Mechanism](#per-rail-lockup-the-guarantee-mechanism)
- [Core Functions](#core-functions)
  - [Account Management](#account-management)
  - [Operator Management](#operator-management)
  - [Rail Management](#rail-management)
  - [One-Time Payments](#one-time-payments)
  - [Operator One-Time Payment Window](#operator-one-time-payment-window)
  - [Handling Reductions to maxLockupPeriod](#handling-reductions-to-maxlockupperiod)
  - [Settlement](#settlement)
  - [Validation](#validation)
- [Worked Example](#worked-example)
  - [1. Initial Funding](#1-initial-funding)
  - [2. Operator Approval](#2-operator-approval)
  - [3. Deal Proposal (Rail Creation)](#3-deal-proposal-rail-creation)
  - [4. Deal Acceptance and Service Start](#4-deal-acceptance-and-service-start)
  - [5. Periodic Settlement](#5-periodic-settlement)
  - [6. Deal Modification](#6-deal-modification)
  - [7. Ending a Deal](#7-ending-a-deal)
  - [8. Final Settlement and Withdrawal](#8-final-settlement-and-withdrawal)
- [Emergency Scenarios](#emergency-scenarios)
  - [Reducing Operator Allowance](#reducing-operator-allowance)
  - [Rail Termination (by payer)](#rail-termination-by-payer)
  - [Rail Termination (by operator)](#rail-termination-by-operator)
  - [Rail Settlement Without Validation](#rail-settlement-without-validation)
  - [Payer Reducing Operator Allowance After Deal Proposal](#payer-reducing-operator-allowance-after-deal-proposal)
- [Contributing](#contributing)
  - [Before Contributing](#before-contributing)
  - [Pull Request Guidelines](#pull-request-guidelines)
  - [Commit Message Guidelines](#commit-message-guidelines)
- [License](#license)

## Deployment Info

- On calibration net at `0x0E690D3e60B0576D01352AB03b258115eb84A047`
- Filecoin Pay Contract (Alpha) is on Mainnet at `0x8c81C77E433725393Ba1eD5439ACdA098278eE1A`
  - **⚠️ WARNING (issued 2025-08-18): May be deprecated within 1-month without migration support. DO NOT use this deployment for production applications or store significant value.**

## Security Audits

The Filecoin-Pay contracts have undergone the following security audits:
- [Zellic Security Audit (August 2025)](https://github.com/Zellic/publications/blob/master/Filecoin%20Services%20Payments%20-%20Zellic%20Audit%20Report.pdf)

## Key Concepts

- **Account**: Represents a user's token balance and locked funds
- **Rail**: A payment channel between a payer and recipient with configurable terms
- **Validator**: An optional contract that acts as a trusted "arbitrator". It can:
  - Validate and modify payment amounts during settlement.
  - Veto a rail termination attempt from any party by reverting the `railTerminated` callback.
  - Decide the final financial outcome (the total payout) of a rail that has been successfully terminated.
- **Operator**: An authorized third party who can manage rails on behalf of payers

### Account

Tracks the funds, lockup, obligations, etc. associated with a single “owner” (where the owner is a smart contract or a wallet). Accounts can be both *payers* and *payees* but we’ll often talk about them as if they were separate types.

- **Payer —** An account that *pays* a payee (this may be for a service, in which case we may refer to the Payer as the *Client*)
- **Payee** — An account which receives payment from a payer (this may be for a service, in which case we may refer to the Payee as the *Service Provider*).

### Rail

A rail along which payments flow from a payer to a payee. Rails track lockup, maximum payment rates, and obligations between a payer and a payee. Payer ↔ Payee pairs can have multiple payment rails between them but they can also reuse the same rail across multiple deals. Importantly, rails:
- Specify the maximum rate at which the payer will pay the payee, the actual amount paid for any given period is subject to validation by the **validator** described below.
- Define a lockup period. The lockup period of a rail is the time period over which the payer is required to maintain locked funds to fully cover the current outgoing payment rate from the rail if the payer stops adding funds to the account. This provides a reliable way for payees to verify that a payer is guaranteed to pay up to a certain point in the future. When a rail's payer account drops to only cover the lockup period this is a signal to the payee that the payer is at risk of defaulting. The lockup period gives the payee time to settle and gracefully close down the rail without missing payment.
- Strictly enforce lockups. While the contract cannot force a payer to deposit funds from their external wallet, it strictly enforces lockups on all funds held within their contract account. It prevents payers from withdrawing locked funds and blocks operator actions that would increase a payer's lockup obligation beyond their available balance. This system provides an easy way for payees to verify a payer's funding commitment for the rail.


### Validator

A validator is an optional contract that acts as a trusted arbitrator for a rail. Its primary role is to validate payments during settlement, but it also plays a crucial part in the rail's lifecycle, especially during termination.

When a validator is assigned to a rail, it gains the ability to:

-   **Mediate Payments:** During settlement, a validator can prevent a payment, refuse to settle past a certain epoch, or reduce the payout amount to account for actual services rendered, penalties, etc.
-   **Oversee Termination:** When `terminateRail` is called by either the payer or the operator, the Payments contract makes a synchronous call to the validator's `railTerminated` function. The payee (payee) cannot directly terminate a rail.
-   **Veto Termination:** The validator can block the termination attempt entirely by reverting inside the `railTerminated` callback. This gives the validator the ultimate say on whether a rail can be terminated, irrespective of who initiated the call.

### Operator

An operator is a smart contract (typically the main contract for a given service) that manages payment rails on behalf of payers. It is also sometimes referred to as the "service contract". A payer must explicitly approve an operator and grant it specific allowances, which act as a budget for how much the operator can spend or lock up on the payer's behalf.

The operator role is powerful, so the operator contract must be trusted by both the payer and the payee. The payer trusts it not to abuse its spending allowances, and the payee trusts it to correctly configure and manage the payment rail.

An approved operator can perform the following actions:

-   **Create Rails (`createRail`):** Establish a new payment rail from a payer to a payee, specifying the token, payee, and an optional validator.
-   **Modify Rail Terms (`modifyRailLockup`, `modifyRailPayment`):** Adjust the payment rate, lockup period, and fixed lockup amount for any rail it manages. Any increase in the payer's financial commitment is checked against the operator's allowances.
-   **Execute One-Time Payments (`modifyRailPayment`):** Execute one-time payments from the rail's fixed lockup.
-   **Settle Rails (`settleRail`):** Trigger payment settlement for a rail to process due payments within the existing terms of the rail. As a rail participant, the operator can initiate settlement at any time. The operator cannot, however, arbitrarily settle a rail for a higher-than-expected amount or higher than expected duration.
-   **Terminate Rails (`terminateRail`):** End a payment rail. Unlike payers, an operator can terminate a rail even if the payer's account is not fully funded.

### Per-Rail Lockup: The Guarantee Mechanism

Each payment rail can be configured to require the payer to lock funds to guarantee future payments. This lockup is composed of two distinct components:

-   **Streaming Lockup (`paymentRate × lockupPeriod`):** A calculated guarantee for rate based payments for a pre-agreed lockup period.
-   **Fixed Lockup (`lockupFixed`):** A specific amount set aside for one-time payments.

The total lockup for a payer's account is the sum of these requirements across *all* their active rails. This total is reserved from their deposited funds and cannot be withdrawn.

#### The Crucial Role of Streaming Lockup: A Safety Hatch, Not a Pre-payment

It is critical to understand that the streaming lockup is **not** a pre-paid account that is drawn from during normal operation. Instead, it functions as a **safety hatch** that can only be fully utilized *after* a rail is terminated.

**1. During Normal Operation (Before Termination)**

While a rail is active, the streaming lockup acts as a **guarantee of solvency for a pre-agreed number of epochs**, not as a direct source of payment.

-   **Payments from General Funds:** When `settleRail` is called on an active rail, payments are drawn from the payer's general `funds`.
-   **Lockup as a Floor:** The lockup simply acts as a minimum balance. The contract prevents the payer from withdrawing funds below this floor.
-   **Settlement Requires Solvency:** Critically, the contract will only settle an active rail up to the epoch where the payer's account is fully funded (`lockupLastSettledAt`). If a payer stops depositing funds and their account becomes insolvent for new epochs, **settlement for new epochs will stop**, even if there is a large theoretical lockup. The lockup itself is not automatically spent.

**2. After Rail Termination (Activating the Safety Hatch)**

The true purpose of the streaming lockup is realized when a rail is terminated. It becomes a guaranteed payment window for the payee.

-   **Activating the Guarantee:** When `terminateRail` is called, the contract sets a final, unchangeable settlement deadline (`endEpoch`), calculated as the payer's last solvent epoch (`lockupLastSettledAt`) plus the `lockupPeriod`.
-   **Drawing from Locked Funds:** The contract now permits `settleRail` to process payments up to this `endEpoch`, drawing directly from the funds that were previously reserved by the lockup.
-   **Guaranteed Payment Window:** This mechanism is the safety hatch. It guarantees that the payee can continue to get paid for the full `lockupPeriod` after the payer's last known point of solvency. This protects the provider if a payer stops paying and disappears.

#### Fixed Lockup (`lockupFixed`)

The fixed lockup is more straightforward. It is a dedicated pool of funds for immediate, one-time payments. When an operator makes a one-time payment, the funds are drawn directly from `lockupFixed`, and the payer's total lockup requirement is reduced at the same time.

#### Detailed Example of Lockup Calculations

The following scenarios illustrate how the lockup for a single rail is calculated and how changes affect the payer's total lockup obligation.

Assume a rail is configured as follows:
- `paymentRate = 3 tokens/epoch`
- `lockupPeriod = 8 epochs`
- `lockupFixed = 7 tokens`

The total lockup requirement for this specific rail is:
`(3 tokens/epoch × 8 epochs) + 7 tokens = 31 tokens`

The payer's account must have at least 31 tokens in *available* funds before this lockup can be established. Once set, 31 tokens will be added to the payer's `Account.lockupCurrent`.

**Scenario 1: Making a One-Time Payment**
The operator makes an immediate one-time payment of 4 tokens.
- **Action:** `modifyRailPayment` is called with `oneTimePayment = 4`.
- **Result:** The 4 tokens are paid from the payer's `funds`. The `lockupFixed` on the rail is reduced to `3` (7 - 4).
- **New Lockup Requirement:** The rail's total lockup requirement drops to `(3 × 8) + 3 = 27 tokens`. The payer's `Account.lockupCurrent` is reduced by 4 tokens.

**Scenario 2: Increasing the Streaming Rate**
The operator needs to increase the payment rate to 4 tokens/epoch.
- **Action:** `modifyRailPayment` is called with `newRate = 4`.
- **New Lockup Requirement:** The rail's streaming lockup becomes `4 × 8 = 32 tokens`. The total requirement is now `32 + 3 = 35 tokens`.
- **Funding Check:** This change increases the rail's lockup requirement by 8 tokens (from 27 to 35). The transaction will only succeed if the payer's account has at least 8 tokens in available (non-locked) funds to cover this increase. If not, the call will revert.

**Scenario 3: Reducing the Lockup Period**
The operator reduces the lockup period to 5 epochs.
- **Action:** `modifyRailLockup` is called with `period = 5`.
- **New Lockup Requirement:** The streaming lockup becomes `3 × 5 = 15 tokens`. The total requirement is now `15 + 3 = 18 tokens`.
- **Result:** The rail's total lockup requirement is reduced from 27 to 18 tokens. This frees up 9 tokens in the payer's `Account.lockupCurrent`, which they can now withdraw (assuming no other lockups).


#### Best Practices for Payees

This lockup mechanism places clear responsibilities on the payee to manage risk:

-   **Settle Regularly:** Depending on the solvency guarantees put in place by the operator contract's lockup requirements, you must settle rails frequently. A rail's `lockupPeriod` is a measure of the risk you are willing to take. If you wait longer than the `lockupPeriod` to settle, you allow a payer to build up a payment obligation that may not be fully covered by the lockup guarantee if they become insolvent.
-   **Monitor Payer Solvency:** Use the `getAccountInfoIfSettled` function to check if a payer is funded. If their `fundedUntilEpoch` is approaching the current epoch, they are at risk.
-   **Terminate Proactively:** If a payer becomes insolvent or unresponsive, request the operator to terminate the rail immediately. This is the **only way** to activate the safety hatch and ensure you can claim payment from the funds guaranteed by the streaming lockup.

## Core Functions

### Account Management

Functions for managing user accounts, including depositing and withdrawing funds. These functions support both ERC20 tokens and the native network token ($FIL) by using `address(0)` as the token address.

#### `deposit(address token, address to, uint256 amount)`

Deposits tokens into a specified account. This is the standard method for funding an account if not using permits. It intelligently handles fee-on-transfer tokens by calculating the actual amount received by the contract.

**When to use:** Use this for direct transfers from a wallet or another contract that has already approved the Payments contract to spend tokens.

**Native Token (FIL):** To deposit the native network token, use `address(0)` for the `token` parameter and send the corresponding amount in the transaction's `value`.

**Parameters**:
- `token`: ERC20 token contract address (`address(0)` for FIL).
- `to`: The account address to credit with the deposit.
- `amount`: The amount of tokens to transfer.

**Requirements**:
- For ERC20s, the direct caller (`msg.sender`) must have approved the Payments contract to transfer at least `amount` of the specified `token`.
- For the native token, `msg.value` must equal `amount`.

#### `depositWithPermit(address token, address to, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)`

Deposits tokens using an EIP-2612 permit, allowing for gasless token approval.

**When to use:** Ideal for user-facing applications where the user can sign a permit off-chain. This combines approval and deposit into a single on-chain transaction, saving gas and improving user experience.

**Note:** This function is for ERC20 tokens only and does not support the native token.

**Parameters**:
- `token`: ERC20 token contract address supporting EIP-2612 permits.
- `to`: The account address to credit (must be the signer of the permit).
- `amount`: Token amount to deposit.
- `deadline`: Permit expiration timestamp.
- `v`, `r`, `s`: Signature components for the EIP-2612 permit.

**Requirements**:
- Token must support EIP-2612.
- `to` must be `msg.sender` (the one submitting the transaction).

#### `depositWithPermitAndApproveOperator(...)`

A powerful convenience function that combines three actions into one transaction:
1. Approves token spending via an EIP-2612 permit.
2. Deposits tokens into the specified account.
3. Sets approval for an operator.

**When to use:** This is the most efficient way for a new user to get started. It funds their account and authorizes a service contract (operator) in a single step.

**Note:** This function is for ERC20 tokens only.

**Parameters**:
- `token`: ERC20 token contract address supporting EIP-2612 permits.
- `to`: The account address to credit (must be the signer of the permit).
- `amount`: Token amount to deposit.
- `deadline`: Permit expiration timestamp.
- `v`, `r`, `s`: Signature components for the EIP-2612 permit.
- `operator`: The address of the operator to approve.
- `rateAllowance`: The maximum payment rate the operator can set across all rails.
- `lockupAllowance`: The maximum funds the operator can lock up for future payments.
- `maxLockupPeriod`: The maximum lockup period in epochs the operator can set.

#### `depositWithPermitAndIncreaseOperatorApproval(...)`

Similar to the above, but for increasing the allowances of an *existing* operator while depositing funds.

**When to use:** Useful when a user needs to top up their funds and simultaneously grant an existing operator higher spending or lockup limits for new or modified deals.

**Note:** This function is for ERC20 tokens only.

**Requirements**:
- Operator must already be approved.

**Parameters**:
- `token`: ERC20 token contract address supporting E-2612 permits.
- `to`: The account address to credit (must be the signer of the permit).
- `amount`: Token amount to deposit.
- `deadline`: Permit expiration timestamp.
- `v`, `r`, `s`: Signature components for the EIP-2612 permit.
- `operator`: The address of the operator whose allowances are being increased.
- `rateAllowanceIncrease`: The amount to increase the rate allowance by.
- `lockupAllowanceIncrease`: The amount to increase the lockup allowance by.

#### `withdraw(address token, uint256 amount)`

Withdraws available (unlocked) tokens from the caller's account to their own wallet address.

**When to use:** When a user wants to retrieve funds from the Payments contract that are not currently reserved in lockups for active rails.

**Native Token (FIL):** To withdraw the native network token, use `address(0)` for the `token` parameter.

**Parameters**:
- `token`: ERC20 token contract address.
- `amount`: Token amount to withdraw.

**Requirements**:
- The `amount` must not exceed the user's available funds (`account.funds - account.lockupCurrent`). The contract runs a settlement check before withdrawal to ensure the lockup accounting is up-to-date.

#### `withdrawTo(address token, address to, uint256 amount)`

Withdraws available tokens from the caller's account to a *specified* recipient address.

**When to use:** Same as `withdraw`, but allows sending the funds to any address, not just the caller's wallet.

**Native Token (FIL):** To withdraw the native network token, use `address(0)` for the `token` parameter.

**Parameters**:
- `token`: ERC20 token contract address.
- `to`: Recipient address.
- `amount`: Token amount to withdraw.

**Requirements**:
- Amount must not exceed the caller's unlocked funds.

#### `getAccountInfoIfSettled(address token, address owner)`

This is a key read-only function that provides a real-time snapshot of an account's financial health. It works by performing an off-chain simulation of what the account's state *would be* if a settlement were to happen at the current block, without actually making any state changes.

This function is the primary tool for monitoring an account's solvency and should be used by all participants in the system.

-   **For Payees and Operators:** Before performing a service or attempting a transaction that increases a payer's lockup (like `modifyRailLockup` or `modifyRailPayment`), call this function to assess risk. A `fundedUntilEpoch` that is in the past or very near the current block number is a strong indicator that the payer is underfunded and that a termination of the rail may be necessary to activate the safety hatch.
-   **For Payers (Payers):** This function allows payers to monitor their own account health. By checking `fundedUntilEpoch` and `availableFunds`, they can determine when a top-up is needed to avoid service interruptions or defaulting on their payment obligations.
-   **For UIs and Dashboards:** This is the essential endpoint for building user-facing interfaces. It provides all the necessary information to display an account's total balance, what's available for withdrawal, its "burn rate", and a clear "funded until" status.

**Parameters**:
- `token`: The token address to get account info for.
- `owner`: The address of the account owner.

**Returns**:
- `fundedUntilEpoch`: The future epoch at which the account is projected to run out of funds, given its current balance and `currentLockupRate`.
    - If this value is `type(uint256).max`, it means the account has a zero lockup rate and is funded indefinitely.
    - If this value is in the past, the account is currently in deficit and cannot be settled further for active rails.
- `currentFunds`: The raw, total balance of tokens held by the account in the contract.
- `availableFunds`: The portion of `currentFunds` that is *not* currently locked. This is the amount the user could successfully withdraw if they called `withdraw` right now.
- `currentLockupRate`: The aggregate "burn rate" of the account, representing the total `paymentRate` per epoch summed across all of the owner's active rails.

### Operator Management

Functions for payers to manage the permissions of operators.

#### `setOperatorApproval(address token, address operator, bool approved, uint256 rateAllowance, uint256 lockupAllowance, uint256 maxLockupPeriod)`

Configures an operator's permissions to manage rails on behalf of the caller (payer). This is the primary mechanism for delegating rail management.

**When to use:** A payer calls this to authorize a new service contract as an operator or to completely overwrite the permissions of an existing one.

**Parameters**:
- `token`: ERC20 token contract address.
- `operator`: The address being granted or denied permissions.
- `approved`: A boolean to approve or revoke the operator's ability to create new rails.
- `rateAllowance`: The maximum cumulative payment rate the operator can set across all rails they manage for this payer.
- `lockupAllowance`: The maximum cumulative funds the operator can lock (both streaming and fixed) across all rails.
- `maxLockupPeriod`: The maximum `lockupPeriod` (in epochs) the operator can set on any single rail.

#### `increaseOperatorApproval(address token, address operator, uint256 rateAllowanceIncrease, uint256 lockupAllowanceIncrease)`

Increases the rate and lockup allowances for an existing operator approval without affecting other settings.

**When to use:** Use this as a convenient way to grant an operator more spending or lockup power without having to re-specify their `maxLockupPeriod` or approval status.

**Parameters**:
- `token`: ERC20 token contract address.
- `operator`: The address of the approved operator.
- `rateAllowanceIncrease`: The amount to add to the existing `rateAllowance`.
- `lockupAllowanceIncrease`: The amount to add to the existing `lockupAllowance`.

**Requirements**:
- The operator must already be approved.

### Rail Management

Functions for operators to create and manage payment rails. These are typically called by service contracts on behalf of payers.

#### `createRail(address token, address from, address to, address validator, uint256 commissionRateBps, address serviceFeeRecipient)`

Creates a new payment rail. This is the first step in setting up a new payment relationship.

**When to use:** An operator calls this to establish a payment channel from a payer (`from`) to a payee (`to`).

**Parameters**:
- `token`: ERC20 token contract address.
- `from`: The payer (payer) address.
- `to`: The recipient (payee) address.
- `validator`: Optional validation contract address (`address(0)` for none).
- `commissionRateBps`: Optional operator commission in basis points (e.g., 100 BPS = 1%).
- `serviceFeeRecipient`: The address that receives the operator commission. This is **required** if `commissionRateBps` is greater than 0.

**Returns**:
- `railId`: A unique `railId`.

**Requirements**:
- The caller (`msg.sender`) must be an approved operator for the `from` address and `token`.

#### `getRail(uint256 railId)`

Retrieves the current state of a payment rail.

**When to use:** To inspect the parameters of an existing rail.

**Parameters**:
- `railId`: The rail's unique identifier.

**Returns**:
- `RailView`: A `RailView` struct containing the rail's public data.
  ```solidity
  struct RailView {
      address token; // The ERC20 token used for payments
      address from; // The payer's address
      address to; // The payee's address
      address operator; // The operator's address
      address validator; // The validator's address
      uint256 paymentRate; // The current payment rate per epoch
      uint256 lockupPeriod; // The lockup period in epochs
      uint256 lockupFixed; // The fixed lockup amount
      uint256 settledUpTo; // The epoch up to which the rail has been settled
      uint256 endEpoch; // The epoch at which a terminated rail can no longer be settled
      uint256 commissionRateBps; // The operator's commission rate in basis points
      address serviceFeeRecipient; // The address that receives the operator's commission
  }
  ```

**Requirements**:
- The rail must be active (not yet finalized).

#### `terminateRail(uint256 railId)`

Initiates the graceful shutdown of a payment rail. This is a critical function that formally ends a payment agreement and activates the lockup safety hatch for the payee.

-   **When to use:** Called by an operator or a payer to end a service agreement, either amicably or in an emergency.

**Who Can Call This Function?**

Authorization to terminate a rail is strictly controlled:

-   **The Operator:** The rail's operator can call this function at any time.
-   **The Payer (Payer):** The payer can only call this function if their account is fully funded (`isAccountLockupFullySettled` is true).
-   **The Payee:** The payee (payee) **cannot** call this function.

**Core Logic and State Changes**

-   **Sets a Final Deadline:** Termination sets a final settlement deadline (`endEpoch`). This is calculated as `payer.lockupLastSettledAt + rail.lockupPeriod`, activating the `lockupPeriod` as a guaranteed payment window.
-   **Stops Future Lockups:** The payer's account `lockupRate` is immediately reduced by the rail's `paymentRate`. This is a crucial step that stops the payer from accruing any *new* lockup obligations for this rail.
-   **Frees Operator Allowances:** The operator's rate usage is decreased, freeing up their `rateAllowance` for other rails.

**Validator Callback**

If the rail has a validator, `terminateRail` makes a synchronous call to the `validator.railTerminated` function. This is a powerful mechanism:

-   **Veto Power:** The validator can block the termination attempt entirely by reverting inside this callback. This gives the validator the ultimate say on whether a rail can be terminated, irrespective of who initiated the call.
-   **Notification:** It serves as a direct notification to the validator that a rail it oversees is being terminated, allowing it to update its own internal state if needed.

**Parameters**:
- `railId`: The rail's unique identifier.

**Requirements**:
- Caller must be the rail's payer (and have a fully funded account) or the rail's operator.
- The rail must not have been already terminated.

#### `modifyRailLockup(uint256 railId, uint256 period, uint256 lockupFixed)`

Changes a rail's lockup parameters (`lockupPeriod` and `lockupFixed`).

-   **When to use:** An operator calls this to adjust the payer's funding guarantee. This is used to set an initial `lockupFixed` for an onboarding fee, increase the `lockupPeriod` for a longer-term commitment, or decrease lockups when a deal's terms change.

**Lockup Calculation and State Changes**

This function recalculates the rail's total lockup requirement based on the new `period` and `lockupFixed` values. The change in the rail's individual lockup is then applied to the payer's total account lockup (`Account.lockupCurrent`).

-   **State Impact:** It modifies both the `Rail` struct (updating `lockupPeriod` and `lockupFixed`) and the payer's `Account` struct (updating `lockupCurrent`).

**Parameters**:
- `railId`: The rail's unique identifier.
- `period`: The new lockup period in epochs.
- `lockupFixed`: The new fixed lockup amount.

**Requirements**:
- Caller must be the rail operator.
- **For Terminated Rails:** The lockup period cannot be changed, and the `lockupFixed` can only be decreased.
- **For Active Rails:**
    - Any increase to the `period` is checked against the operator's `maxLockupPeriod` allowance.
    - **Critical**: If the payer's account is **not** fully funded (`isAccountLockupFullySettled` is false), changes are heavily restricted: the `period` cannot be changed, and `lockupFixed` can only be decreased. This prevents increasing the financial burden on an underfunded payer.

#### `modifyRailPayment(uint256 railId, uint256 newRate, uint256 oneTimePayment)`

Modifies a rail's payment rate, makes an immediate one-time payment, or both.

-   **When to use:** This is the primary function for starting a payment stream (by setting an initial `newRate`), adjusting it, or making ad-hoc [One-Time Payments](#one-time-payments).

**Rate Change Behavior**

When this function is used to change a rail's payment rate (`newRate` is different from the current rate), the change is not applied retroactively. The contract uses an internal queue to ensure that rate changes are applied precisely at the correct epoch:

-   **Old Rate Preservation:** The contract records the *old* payment rate with a deadline (`untilEpoch`) set to the current block number.
-   **Future Application:** The `newRate` becomes the rail's new default rate and will be used for settlement for all epochs *after* the current one.
-   **Settlement Logic:** When `settleRail` is called, it processes this queue. It will use the old rate to settle payments up to and including the block where the change was made, and then use the new rate for subsequent blocks. This ensures perfect, per-epoch accounting even if rates change frequently.

**Parameters**:
- `railId`: The rail's unique identifier.
- `newRate`: The new per-epoch payment rate.
- `oneTimePayment`: An optional amount for an immediate payment, drawn from `lockupFixed`.

**Requirements**:
- Caller must be the rail operator.
- `oneTimePayment` cannot exceed the rail's current `lockupFixed`.
- **For Terminated Rails:**
    - The rate can only be decreased (`newRate <= oldRate`).
    - **Edge Case**: This function will revert if called after the rail's final settlement window (`endEpoch`) has passed.
- **For Active Rails:**
    - **Critical**: If the payer's account is **not** fully funded (`isAccountLockupFullySettled` is false), the payment rate **cannot be changed at all**. `newRate` must equal `oldRate`. This is a strict safety measure.

#### `getRailsForPayerAndToken(address payer, address token)`

Retrieves all rails where the given address is the payer for a specific token.

**When to use:** Useful for UIs or payer-side applications to list all outgoing payment rails for a user.

**Parameters**:
- `payer`: The payer's address.
- `token`: The ERC20 token contract address.

**Returns**:
- `RailInfo[]`: An array of `RailInfo` structs.

#### `getRailsForPayeeAndToken(address payee, address token)`

Retrieves all rails where the given address is the payee for a specific token.

**When to use:** Useful for UIs or payee-side applications to list all incoming payment rails.

**Parameters**:
- `payee`: The payee's address.
- `token`: The ERC20 token contract address.

**Returns**:
- `RailInfo[]`: An array of `RailInfo` structs.

#### `getRateChangeQueueSize(uint256 railId)`

Returns the number of pending rate changes in the queue for a specific rail. When `modifyRailPayment` is called, the old rate is enqueued to ensure past periods are settled correctly.

**When to use:** For debugging or advanced monitoring to see if there are pending rate changes that need to be cleared through settlement.

**Parameters**:
- `railId`: Rail identifier.

**Returns**:
- `uint256`: The number of `RateChange` items in the queue.

**Requirements**: None.

### One-Time Payments

One-time payments enable operators to transfer fixed amounts immediately from payer to payee, bypassing the regular rate-based payment flow. These payments are deducted from the rail's fixed lockup amount.

#### Key Characteristics

- **Operator-Initiated**: Only the rail operator can execute one-time payments through `modifyRailPayment`
- **Fixed Lockup Source**: Payments are drawn from `rail.lockupFixed`, which must be pre-allocated via `modifyRailLockup`
- **Always Available**: Once locked, these funds remain available regardless of the payer's account balance
- **Operator Approval**: Counts against the operator's `lockupAllowance` and reduces `lockupUsage` when spent
- **Commission Applied**: One-time payments are subject to the rail's operator commission rate, just like regular payments

#### Usage

One-time payments require a two-step process:

1. **Lock funds** using `modifyRailLockup` to allocate fixed lockup:

```solidity
// Allocate 10 tokens for one-time payments
Payments.modifyRailLockup(
    railId,       // Rail ID
    lockupPeriod, // Lockup period (unchanged or new value)
    10 * 10**18   // Fixed lockup amount
);
```

This will revert if:
- The payer lacks sufficient unlocked funds to cover the requested lockup
- The operator exceeds their `lockupAllowance` or `maxLockupPeriod` limits

2. **Make payments** using `modifyRailPayment` with a non-zero `oneTimePayment`:

```solidity
// Make a 5 token one-time payment from the locked funds
Payments.modifyRailPayment(
    railId,      // Rail ID
    newRate,     // Payment rate (can remain unchanged)
    5 * 10**18   // One-time payment amount (must be ≤ rail.lockupFixed)
);
```

#### Lifecycle

1. **Allocation**: Fixed lockup is set when creating / modifying a rail via `modifyRailLockup`
2. **Usage**: Operator makes one-time payments, reducing the available fixed lockup
3. **Termination**: Unused fixed lockup remains available for one-time payments even after rail termination
4. **Finalization**: After full rail settlement, any remaining fixed lockup is automatically refunded to the payer

#### Example Use Cases

- Onboarding fees or setup costs
- Performance bonuses or penalties
- Urgent payments outside regular settlement cycles
- Termination fees when canceling services

### Operator One-Time Payment Window

**Lifecycle:**

1. **Rail Active:** While the rail is active, the operator can make one-time payments at any time, provided there is sufficient fixed lockup remaining.
2. **Rail Termination:** When a rail is terminated (either by the payer or operator), the payment stream stops flowing out of the payer's account. However the payment stream does not stop flowing to the payee. Instead, the lockup period acts as a grace period with funds flowing to the payee out of the payee's rate based lockup. Additionally the fixed lockup is not released until the end of the lockup period allowing the operator to continue making one-time payments for a limited time after termination.
   * **The end of this window is calculated as the last epoch up to which the payer's account lockup was settled (`lockupLastSettledAt`) plus the rail's lockup period.** If the account was only settled up to an earlier epoch, the window will close sooner than if it was fully up to date at the time of termination.
1. **End of Window:** Once the current epoch surpasses `(rail termination epoch + rail lockup period)`, the one-time payment window closes. At this point, any unused fixed lockup is automatically refunded to the payer, and no further one-time payments can be made.

**Example Timeline:**
  - Rail is created at epoch 100, with a lockup period of 20 epochs.
  - At epoch 150, the operator calls `terminateRail`, but the payer's lockup is only settled up to epoch 120.
  - The rail's termination epoch is set to 120 (the last settled lockup epoch).
  - The operator can make one-time payments from the fixed lockup until epoch 140 (`120 + 20`).
  - After epoch 140, any remaining fixed lockup is refunded to the payer.

**Note:** The one-time payment window after termination is **not** always the epoch at which `terminateRail` is called plus the lockup period. It depends on how far the payer's account lockup has been settled at the time of termination. If the account is not fully settled, the window will be shorter.

### Handling Reductions to maxLockupPeriod

A payer can reduce the operator's `maxLockupPeriod` or `lockupAllowance` after a deal proposal, which may prevent the operator from setting a meaningful lockup period and thus block one-time payments.

**Edge Case Explanation:**
  - If the payer reduces the operator's `maxLockupPeriod` or `lockupAllowance` after a deal is proposed but before the operator has set the lockup, the operator may be unable to allocate enough fixed lockup for one-time payments. This can hamper the operator's ability to secure payment for work performed, especially if the lockup period is set to a very low value or zero.
  - This risk exists because the operator's ability to set or increase the lockup is always subject to the current allowances set by the payer. If the payer reduces these allowances before the operator calls `modifyRailLockup`, the transaction will fail, and the operator cannot secure the funds.

**Best Practice:**
  - Before performing any work or incurring costs, the operator should always call `modifyRailLockup` to allocate the required fixed lockup. Only if this call is successful should the operator proceed with the work. This guarantees that the fixed lockup amount is secured for one-time payments, regardless of any future reductions to operator allowances by the payer.

**Practical Scenario:**
  1. Operator and payer agree on a deal, and the operator intends to lock 10 tokens for one-time payments.
  2. Before the operator calls `modifyRailLockup`, the payer reduces the operator's `maxLockupPeriod` to 0 or lowers the `lockupAllowance` below 10 tokens.
  3. The operator's attempt to set the lockup fails, and they cannot secure the funds for one-time payments.
  4. If the operator had called `modifyRailLockup` and succeeded before the payer reduced the allowance, the lockup would be secured, and the operator could draw one-time payments as needed, even if the payer later reduces the allowance.

**Summary:**
  - Always secure the fixed lockup before starting work. This is the only way to guarantee access to one-time payments, regardless of changes to operator allowances by the payer.

### Settlement

Functions for processing payments by moving funds from the payer to the payee based on the rail's terms.

#### `settleRail(uint256 railId, uint256 untilEpoch)`

This is the primary function for processing payments. It can be called by any rail participant (payer, payee, or operator) to settle due payments up to a specified epoch. A network fee in the native token may be required for this transaction.

**Parameters**:
- `railId`: The ID of the rail to settle.
- `untilEpoch`: The epoch up to which to settle.

**Returns**:
- `totalSettledAmount`: The total amount settled and transferred.
- `totalNetPayeeAmount`: The net amount credited to the payee after fees.
- `totalOperatorCommission`: The commission credited to the operator.
- `finalSettledEpoch`: The epoch up to which settlement was actually completed.
- `note`: Additional information about the settlement (especially from validation).

The behavior of `settleRail` critically depends on whether the rail is active or terminated:

-   **For Active Rails:** Settlement can only proceed up to the epoch the payer's account was last known to be fully funded (`lockupLastSettledAt`). This is a key safety feature: if a payer becomes insolvent, settlement of an active rail halts, preventing it from running a deficit.
-   **For Terminated Rails:** Settlement can proceed up to the rail's final `endEpoch`, drawing directly from the streaming lockup.

**The Role of the Validator in Settlement**

If a rail has a validator, `settleRail` will call the `validatePayment` function on the validator contract for each segment being settled. This gives the validator significant power:

-   **It can approve the proposed payment** by returning the same amount and end epoch.
-   **It can partially settle** by returning a `settleUpto` epoch that is earlier than the proposed end of the segment.
-   **It can modify the payment amount** for the settled period by returning a `modifiedAmount`.
-   **It can effectively reject settlement** for a segment by returning 0 for the settlement duration (`result.settleUpto` equals `epochStart`).

However, the validator's power is not absolute. The Payments contract enforces these critical constraints on the validator's response:
-   It **cannot** settle a rail beyond the proposed settlement segment.
-   It **cannot** approve a payment amount that is greater than the maximum allowed by the rail's `paymentRate` for the duration it is approving.

**Note**: While the validator has significant control, the final settlement outcome is also dependent on the payer having sufficient funds for the amount being settled.

#### `settleTerminatedRailWithoutValidation(uint256 railId)`

This is a crucial escape-hatch function that allows the **payer** to finalize a terminated rail that is otherwise stuck, for example, due to a malfunctioning validator.

**When to use:** As a last resort, after a rail has been terminated and its full settlement window (`endEpoch`) has passed.

**What it does:** It settles the rail in full up to its `endEpoch`, completely bypassing the `validator`. This ensures that any funds owed to the payee are paid and any remaining payer funds are unlocked.

**Parameters**:
- `railId`: The ID of the rail to settle.

**Returns**:
- `totalSettledAmount`: The total amount settled and transferred.
- `totalNetPayeeAmount`: The net amount credited to the payee after fees.
- `totalOperatorCommission`: The commission credited to the operator.
- `finalSettledEpoch`: The epoch up to which settlement was actually completed.
- `note`: Additional information about the settlement.

**Requirements**:
-   Caller must be the rail's payer.
-   The rail must be terminated.
-   The current block number must be past the rail's final settlement window (`rail.endEpoch`).

### Validation

The contract supports optional payment validation through the `IValidator` interface. When a rail has a validator:

1. During settlement, the validator contract is called
2. The validator can adjust payment amounts or partially settle epochs
3. This provides dispute resolution capabilities for complex payment arrangements

## Worked Example

This worked example demonstrates how users interact with the FWS Payments contract through a typical service deal lifecycle.

### 1. Initial Funding

A payer first deposits tokens to fund their account in the payments contract:

#### Traditional Approach (Two transactions):

```solidity
// 1. Payer approves the Payments contract to spend tokens
IERC20(tokenAddress).approve(paymentsContractAddress, 100 * 10**18); // 100 tokens

// 2. Payer or anyone else can deposit to the payer's account
Payments(paymentsContractAddress).deposit(
    tokenAddress,   // ERC20 token address
    payerAddress,  // Recipient's address (the payer)
    100 * 10**18    // Amount to deposit (100 tokens)
);
```

#### Single Transaction Alternative (for EIP-2612 tokens):

```solidity
// Payer signs a permit off-chain and deposits in one transaction
Payments(paymentsContractAddress).depositWithPermit(
    tokenAddress,   // ERC20 token address (must support EIP-2612)
    payerAddress,  // Recipient's address (must be the permit signer)
    100 * 10**18,   // Amount to deposit (100 tokens)
    deadline,       // Permit expiration timestamp
    v, r, s         // Signature components from signed permit
);
```

After this operation, the payer's `Account.funds` is credited with 100 tokens, enabling them to use services within the FWS ecosystem.

This operation _may_ be deferred until the funds are actually required, funding is always "on-demand".

### 2. Operator Approval

Before using a service, the payer must approve the service's contract as an operator. This can be done in two ways:

#### Option A: Separate Operator Approval

If you've already deposited funds, you can approve operators separately:

```solidity
// Payer approves a service contract as an operator
Payments(paymentsContractAddress).setOperatorApproval(
    tokenAddress,           // ERC20 token address
    serviceContractAddress, // Operator address (service contract)
    true,                   // Approval status
    5 * 10**18,             // Maximum rate (tokens per epoch) the operator can allocate
    20 * 10**18,            // Maximum lockup the operator can set
    100                     // Maximum lockup period in epochs
);
```

#### Option B: Combined Deposit and Operator Approval (Single transaction)

For EIP-2612 tokens, you can combine funding and operator approval:

```solidity
// Payer signs permit off-chain, then deposits AND approves operator in one transaction
Payments(paymentsContractAddress).depositWithPermitAndApproveOperator(
    tokenAddress,           // ERC20 token address (must support EIP-2612)
    payerAddress,          // Recipient's address (must be the permit signer)
    100 * 10**18,           // Amount to deposit (100 tokens)
    deadline,               // Permit expiration timestamp
    v, r, s,                // Signature components from signed permit
    serviceContractAddress, // Operator to approve
    5 * 10**18,             // Rate allowance (5 tokens/epoch)
    20 * 10**18,            // Lockup allowance (20 tokens)
    100                     // Max lockup period (100 epochs)
);
```

This approval has three key components:

- The `rateAllowance` (5 tokens/epoch) limits the total continuous payment rate across all rails created by this operator
- The `lockupAllowance` (20 tokens) limits the total fixed amount the operator can lock up for one-time payments or escrow
- The `maxLockupPeriod` (100 epochs) limits how far in advance the operator can lock funds

### 3. Deal Proposal (Rail Creation)

When a payer proposes a deal with a payee, the service contract (acting as an operator) creates a payment rail:

```solidity
// Service contract creates a rail
uint256 railId = Payments(paymentsContractAddress).createRail(
    tokenAddress,       // Token used for payments
    payerAddress,      // Payer (payer)
    payee,    // Payee (payee)
    validatorAddress,   // Optional validator (can be address(0) for no validation / arbitration)
    commissionRateBps,  // Optional operator commission rate in basis points
    serviceFeeRecipient // The address that receives the operator commission
);

// Set up initial lockup for onboarding costs - for example, 10 tokens as fixed lockup
Payments(paymentsContractAddress).modifyRailLockup(
    railId,         // Rail ID
    100,            // Lockup period (100 epochs)
    10 * 10**18     // Fixed lockup amount (10 tokens for onboarding)
);
```

At this point:

- A rail is established between the payer and payee
- The rail has a `fixedLockup` of 10 tokens and a `lockupPeriod` of 100 epochs
- The payment `rate` is still 0 (service hasn't started yet)
- The payer's account `lockupCurrent` is increased by 10 tokens.

### 4. Deal Acceptance and Service Start

When the payee accepts the deal, the operator starts the payment stream:

```solidity
// Service contract (operator) increases the payment rate and makes a one-time payment
Payments(paymentsContractAddress).modifyRailPayment(
    railId,           // Rail ID
    2 * 10**18,       // New payment rate (2 tokens per epoch)
    3 * 10**18        // One-time onboarding payment (3 tokens)
);
```

This single operation has several effects:
- An immediate one-time payment of 3 tokens is transferred to the payee. This is deducted from the rail's `lockupFixed`, which is now 7 tokens.
- The payer's total `lockupCurrent` is recalculated. The old rail lockup (10) is replaced by the new lockup: `(2 * 100) + 7 = 207` tokens. This change requires the payer to have sufficient available funds.
- The payer's account `lockupRate` is now increased by 2 tokens/epoch. This rate is used to calculate future lockup requirements whenever settlement occurs.

### 5. Periodic Settlement

Payment settlement can be triggered by any rail participant to process due payments.

```solidity
// Settlement call - can be made by payer, payee, or operator
(uint256 amount, uint256 settledEpoch, string memory note) = Payments(paymentsContractAddress).settleRail(
    railId,        // Rail ID
    block.number   // Settle up to current epoch
);
```

This settlement:

- Calculates amount owed based on the rail's rate and time elapsed since the last settlement.
- Transfers tokens from the payer's `funds` to the payee's account.
- If a validator is specified, it may modify the payment amount or limit settlement epochs.
- Records the new `settledUpTo` epoch for the rail.

A rail may only be settled if either (a) the payer's account is fully funded or (b) the rail is terminated (in which case the rail may be settled up to the rail's `endEpoch`).

### 6. Deal Modification

If service terms change, the operator can adjust the rail's parameters.

```solidity
// Operator modifies payment parameters
Payments(paymentsContractAddress).modifyRailPayment(
    railId,           // Rail ID
    4 * 10**18,       // Increased rate (4 tokens per epoch)
    0                 // No one-time payment
);

// If lockup terms need changing
Payments(paymentsContractAddress).modifyRailLockup(
    railId,         // Rail ID
    150,            // Extended lockup period (150 epochs)
    15 * 10**18     // Increased fixed lockup (15 tokens)
);
```

### 7. Ending a Deal

There are two primary ways to end a deal:

**Method 1: Soft End (Rate to Zero)**

The operator can set the payment rate to zero and optionally charge a final termination fee. This keeps the rail active but stops recurring payments.

```solidity
// Service contract reduces payment rate and issues an optional termination payment
Payments(paymentsContractAddress).modifyRailPayment(
    railId,        // Rail ID
    0,             // Zero out payment rate
    5 * 10**18     // Termination fee (5 tokens)
);
```

**Method 2: Hard Termination (Safety Hatch)**

The operator (or a fully-funded payer) can call `terminateRail`. This formally ends the agreement and activates the `lockupPeriod` as a final, guaranteed settlement window for the payee.

```solidity
// Operator or payer terminates the rail
Payments(paymentsContractAddress).terminateRail(railId);
```

### 8. Final Settlement and Withdrawal

After a rail is terminated and its final settlement window (`endEpoch`) has been reached, a final settlement call will unlock any remaining funds.

```solidity
// 1. First, get the rail's details to find its endEpoch
RailView memory railInfo = Payments(paymentsContractAddress).getRail(railId);

// 2. Perform the final settlement up to the endEpoch
(uint256 amount, uint256 settledEpoch, string memory note) = Payments(paymentsContractAddress).settleRail(
    railId,
    railInfo.endEpoch
);

// 3. Payer can now withdraw all remaining funds that are no longer locked
Payments(paymentsContractAddress).withdraw(
    tokenAddress,
    remainingAmount // Amount to withdraw
);
```

## Emergency Scenarios

If some component in the system (operator, validator, payer, payee) misbehaves, all parties have escape hatches that allow them to walk away with predictable losses.

### Reducing Operator Allowance

At any time, the payer can reduce the operator's allowance (e.g., to zero) and / or change whether or not the operator is allowed to create new rails. Such modifications won't affect existing rails, although the operator will not be able to increase the payment rates on any rails they manage until they're back under their limits.

### Rail Termination (by payer)

If something goes wrong (e.g., the operator is buggy and is refusing to terminate deals or stop payments), the payer may terminate the rail to prevent future payment obligations beyond the guaranteed lockup period.

```solidity
// Payer terminates the rail
Payments(paymentsContractAddress).terminateRail(railId);
```

- **Requirements**: The payer must ensure their account is fully funded (`isAccountLockupFullySettled` is true) before they can terminate any rails.

**Consequences of Termination:**

-   **Sets a Final Deadline:** Termination sets a final settlement deadline (`endEpoch`). This activates the `lockupPeriod` as a guaranteed payment window for the payee.
-   **Stops Future Lockups:** The payer's account immediately stops accruing new lockup for this rail's payment rate.
-   **Unlocks Funds After Final Settlement:** The funds reserved for the rail (both streaming and fixed) are only released back to the payer after the `endEpoch` has passed *and* a final `settleRail` call has been made. They do not unlock automatically.

### Rail Termination (by operator)

At any time, even if the payer's account isn't fully funded, the operator can terminate a rail. This will allow the recipient to settle any funds available in the rail to receive partial payment.

### Rail Settlement Without Validation

If a validator contract is malfunctioning, the _payer_ may forcibly settle the rail the rail "in full" (skipping validation) to prevent the funds from getting stuck in the rail pending final validation. This can only be done after the rail has been terminated (either by the payer or by the operator), and should be used as a last resort.

```solidity
// Emergency settlement for terminated rails with stuck validation
(uint256 amount, uint256 settledEpoch, string memory note) = Payments(paymentsContractAddress).settleTerminatedRailWithoutValidation(railId);
```

### Payer Reducing Operator Allowance After Deal Proposal

#### Scenario

If a payer reduces an operator’s `rateAllowance` after a deal proposal, but before the payee accepts the deal, the following can occur:
1. The operator has already locked a fixed amount in a rail for the deal.
2. The payee, seeing the locked funds, does the work and tries to accept the deal.
3. The payer reduces the operator’s `rateAllowance` before the operator can start the payment stream.
4. When the operator tries to begin payments (by setting the payment rate), the contract checks the current allowance and **the operation fails** if the new rate exceeds the reduced allowance—even if there is enough fixed lockup.

#### Contract Behavior

- The contract enforces that operators cannot lock funds at a rate higher than their current allowance.
- The operator might not be able to initiate the payment stream as planned if the allowance is decreased after the rail setup.

#### Resolution: One-Time Payment from Fixed Lockup

From the fixed lockup, the operator can still use the `modifyRailPayment` function to make a **one-time payment** to the payee. Even if the rate allowance was lowered following the deal proposal, this still enables the payee to be compensated for their work.

**Example Usage:**
```solidity
Payments.modifyRailPayment(
    railId,
    0,
    oneTimePayment
);
```

#### Best Practice

- Unless absolutely required, payers should refrain from cutting operator allowances for ongoing transactions.
- In the event that the rate stream cannot be initiated, operators should be prepared for this possibility and utilize one-time payments as a backup.

## Contributing

We welcome contributions to the payments contract! To ensure consistency and quality across the project, please follow these guidelines when contributing.

### Before Contributing

- **New Features**: Always create an issue first and discuss with maintainers before implementing new features. This ensures alignment with project goals and prevents duplicate work.
- **Bug Fixes**: While you can submit bug fix PRs without prior issues, please include detailed reproduction steps in your PR description.

### Pull Request Guidelines

- **Link to Issue**: All feature PRs should reference a related issue (e.g., "Closes #123" or "Addresses #456").
- **Clear Description**: Provide a detailed description of what your PR does, why it's needed, and how to test it.
- **Tests**: Include comprehensive tests for new functionality or bug fixes.
- **Documentation**: Update relevant documentation for any API or behavior changes.

### Commit Message Guidelines

This project follows the [Conventional Commits specification](https://www.conventionalcommits.org/). All commit messages should be structured as follows:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

**Types:**
- `feat`: A new feature
- `fix`: A bug fix
- `docs`: Documentation only changes
- `style`: Changes that do not affect the meaning of the code (white-space, formatting, missing semi-colons, etc)
- `refactor`: A code change that neither fixes a bug nor adds a feature
- `test`: Adding missing tests or correcting existing tests
- `chore`: Changes to the build process or auxiliary tools and libraries

**Examples:**
- `feat: add rail termination functionality`
- `fix: resolve settlement calculation bug`
- `docs: update README with new API examples`
- `chore: update dependencies`

Following these conventions helps maintain a clear project history and makes handling of releases and changelogs easier.

## License

Dual-licensed under [MIT](https://github.com/filecoin-project/lotus/blob/master/LICENSE-MIT) + [Apache 2.0](https://github.com/filecoin-project/lotus/blob/master/LICENSE-APACHE)
