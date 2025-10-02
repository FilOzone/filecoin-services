
# Payments Contract In Depth Implementation SPEC 

This document exists as a supplement to the very thorough and useful README. The README covers essentially everything you need to know as a user of the payments contract. This document exists for very advanced users and implementers to cover the internal workings of the contract in depth. You should understand the README first before reading this document.

- [Skeleton Keys for Understanding](#skeleton-keys-for-understanding)
	- [Three Core Datastructures](#three-core-data-structures)
	- [The Fundamental Flow of Funds](#the-fundamental-flow-of-funds)
	- [Mixing of Buckets](#mixing-of-buckets)
	- [Invariants Enforced Eagerly](#invariants-are-enforced-eagerly)
- [Operator Approval](#operator-approval)
- [Accounts and Account Settlement](#accounts-and-account-settlement)
- [Rails and Rail Settlement](#rails-and-rail-settlement)
	- [One Time Payments](#one-time-payments)
	- [Rail Changes](#rail-changes)
    - [Validation](#validation)	
- [Rail Termination](#rail-termination)



## Skeleton Keys for Understanding 

Some concepts are a bit tricky and show up throughout the code in subtle ways. Once you understand them it makes things easier.

### Three Core Data Structures

There are three essential data structures in this contract.  The [`Account`](#accounts-and-account-settlement), the [`Rail`](#rails-and-rail-settlement) and the [`OperatorApproval`](#operator-approval). Accounts hold funds of a particular token associated with a public key. They are used for paying and receiving payment. Rails are used to track point to point payments between Accounts. OperatorApprovals allow an operator contract to set up and modify payments between parties under usage constraints.

A public key identity can have multiple Accounts of different token type. Each Account can have multiple operators that it has approved to process payments. Each Account can also have multiple outgoing payment rails. Each rail represents a different payee. There is one operator per rail. One operator can manage many rails and each rail can have a different operator. To consider the general picture it can be helpful to think of a set of operators per account and a set of rails per operator. 

Finally note that independent to its outgoing payment rails accounts can have any amount of incoming payment rails from different payers.

### The Fundamental Flow of Funds

The first key principle of fund movements: 

> All funds paid from payer to payee in the payment contract are 1) deposited into the payer's account 2) temporarily locked up in the `lockupCurrent` of the payer account 3) moved into the payee account

This applies to both one time payments and standard rate based rail payment flows.

In the case of live rail payment flows, funds are temporarily locked during account settlement and moved into the payee account during rail settlement.  We'll refer to these lockup funds as "temporary settling lockup" in this document.

For one time payments lockup is explicitly added to `lockupCurrent` of the payer account when setting up the rail with a call to`modifyRailLockup`.  Payments are processed immediately in `modifyRailPayment` with a nonzero `oneTimePayment` parameter -- there is no waiting for rail settlement to process these funds.

Rail payment flows on terminated rails are locked and known as the streaming lockup. These funds are locked when `modifyRailPayment` increases the rail's payment rate or when `modifyRailLockup` changes the lockup period.  These funds can never be withdrawn from a live rail and are only released during settlement of the rail after termination.  This is a very essential point to understand the payments contract.  Rate based payments paid out during the `lockupPeriod` for a terminated rail share characteristics of both one time payments and live rail payment streams.  Like one time payments all rails are required to lockup up front the amount needed to cover the lockup period payment.  Like live rail payments the `lockupPeriod` payments are released at the rail's rate through time. Unique to rail payments after termination is that they *must* flow from payer to payee, barring validation interference.  One time payments have no such requirement and live rail payments can always be stopped by terminating the rail.

One important difference between these three cases is how they interact with operator approval.  Live rail payment flow approval is managed with `rateAllowance` and `rateUsage`.  Hence temporary settling lockup is added to `lockupCurrent` without any modifications to `lockupUsage` or requirements on `lockupAllowance`.  In contrast the streaming lockup that covers terminated rail settlement is locked throughout rail duration and consumes `lockupAllowance` to increase the operator approval's `lockupUsage`. And of course this is also true of fixed lockup for one time payments.

The second key principle of fund movements:

> Payer account funds may be set aside for transfer but end up unused in which case they are 1) first deposited into the payer's account 2) temporarily locked up in `lockupCurrent` of the payer account 3) moved back to the available balance of the payer account

This is the case for unused fixed lockup set aside for one time payments that are never made when a rail is finalized.  This is also true for funds that don't end up flowing during rail settlement because rail validation fails.

One last thing to note is that all funds that complete movement from payer to payee are potentially charged a percentage commission fee to a serviceFeeRecipient.  This address is specified per rail.

### Mixing of Buckets

Schematic of the contents of the Operator approval `lockupUsage` bucket of funds

```
+-------------------+         +-------------------------------+         
| Operator Approval |         | rail 1 fixed lockup usage     |
|                   |         +-------------------------------+
|   lockupUsage     |   ==    | rail 1 streaming lockup usage |
|                   |         +-------------------------------+
|                   |         | rail 2 fixed lockup usage     |
|                   |         +-------------------------------+
|                   |         | rail 2 streaming lockup usage | 
|                   |         +-------------------------------+
|                   |         |     ...                       |
+-------------------+         +-------------------------------+
```

Schematic of the contents of the account `lockupCurrent` bucket of funds. 
Fixed, streaming and temporary settling lockup from all rails of all operators are contained in the single `lockupCurrent` bucket of funds tracked in the `Account` datastructure.
```
+-------------------+         +-----------------------------------+         
|      Account      |         | rail 1 (operator A) fixed lockup  |
|                   |         +-----------------------------------+
|  lockupCurrent    |   ==    | rail 1 (op A) streaming lockup    |
|                   |         +-----------------------------------+
|                   |         | rail 1 (op A) tmp settling lockup |
|                   |         +-----------------------------------+
|                   |         | rail 2 (op B) fixed lockup usage  |
|                   |         +-----------------------------------+
|                   |         | rail 2 (op B) streaming lockup    | 
|                   |         +-----------------------------------+
|                   |         | rail 2 (op B) tmp settling lockup |
|                   |         +-----------------------------------+
|                   |         |     ...                           |
+-------------------+         +-----------------------------------+
```

The payments contract has two main methods of payment: rate based payments and one time payments. Each core datastructure has a pairs of variables that seem to reflect this dichotomy: (`rateUsage`/`rateAllowance`, `lockupUsage`/`lockupAllowance`) for operator approval, (`lockupCurrent`, `lockupRate`) for accounts, and (`lockupFixed`, `paymentRate`) for rails. The payments contract does separate accounting based on rates and funds available for one time payment largely by manipulating these separate variables. But there is a big exception that shows up throughout -- the streaming lockup.

As explained in the README the streaming lockup are funds that must be locked to cover a rail's `lockupPeriod` between rail termination and rail finalization, i.e. its end of life. For motivation on the `lockupPeriod` see the README. Internally the payments contract does not consistently organize these buckets of funds separately but sometimes mixes them together. The accounting for approval and accounts *mixes these buckets* while rail accounting keeps them separate. `lockupUsage` and `lockupCurrent` both track one number that is a sum of streaming lockups for rate requirements during the `lockupPeriod` and fixed lockup for one time payment coverage.  Further complicating things the account data structure also inclues temporary settling lockup between account settlement and rail settlement.  See the schematics above.

As an example of how this manifests itself consider a call to `modifyRailPayment` increasing the payment rate of a rail.  For this operation to go through not only does the `rateAllowance` need to be high enough for the operator increase its `rateUsage`, the `lockupAllowance` must also be high enough to cover the new component of streaming lockup in the `lockupUsage`.

### Invariants are Enforced Eagerly

The most pervasive pattern in the payments contract is the usage of pre and post condition modifiers. The bulk of these modifier calls force invariants within the fields of the three core datastructures to be true. The major invariant being enforced is that accounts are always settled as far as possible. In fact function modifiers is the only place where account settlement occurs (for more detail see [section below](#accounts-and-account-settlement)). Additionally there are invariants making sure that rails don't attempt to spend more than their fixed lockup and that account locked funds are always covered by account balance. There are also selectively used invariants asserting that rails are in particular termination states for particular methods.

Every interesting function modifying the state of the payments contract runs a group of core account settlement related invariant pre and post conditions via the `settleAccountLockupBeforeAndAfter` or the `settleAccountLockupBeforeAndAfterForRail` modifier. This is a critical mechanism to be aware of when reasoning through which invariants apply during the execution of payments contract methods.

## Operator Approval

As describe above operator approvals consist of the pair of `rateAllowance` and `lockupAllowance`.  Approvals are per operator and rate and lockup resource usage are summed across all of an operator's rails when checking for sufficient operator approval during rail operations.  Approvals also include a `maxLockupPeriod` restricting the operator's ability to make lockup period too long.

The OperatorApproval struct 

```solidity
    struct OperatorApproval {
        bool isApproved;
        uint256 rateAllowance;
        uint256 lockupAllowance;
        uint256 rateUsage; // Track actual usage for rate
        uint256 lockupUsage; // Track actual usage for lockup
        uint256 maxLockupPeriod; // Maximum lockup period the operator can set for rails created on behalf of the client
    }
```

An important counterintuitive fact about the approval allowances is that they are not constrained in relation to current usage. Usage can be lower than allowance if an operator has not used all of their existing allowance. Usage can be higher than allowance if a client has manually reduced the operator's allowance. As explained in the README, reducing allowance below usage on any of the allowance resources (rate, lockup, period) will not impact existing rails. Allowance invariants are checked at the point in time of rail modification not continuously enforced, so a new modification increasing a rail's usage can fail after reducing allowance. Furthermore reductions in usage always go through even if the current allowance is below the new usage. For example if a rail has an allowance of 20 locked tokens and uses all of them to lock up 20 tokens, and then the client brings allowance for the operator down to 1 locked token the operator can still modify the rail usage down to 15 locked tokens even though it exceeds the operator's current allowance.

Another quirk of the allowance system is the difference with which rate changes and one time payments impact the lockup allowance. When modifying a rail's rate change down, say from 5 tokens a block to 4 tokens a block, the operator's lockup approval usage can go down by 1 token * `lockupPeriod` to account for the reduction in streaming lockup. Now the operator can leverage this reduced usage to modify payments upwards in other rails. For one time payments this is not true. When a one time payment clears the approval lockup usage goes down, but additionally the `lockupAllowance` *also goes down* limiting the operator from doing this again. This is essential for the payments sytem to work correctly, otherwise 1 unit of `lockupAllowance` could be used to spend an entire accounts funds in repeated one time payments.

## Accounts and Account Settlement

Account settlement roughly speaking flows funds out of a depositing payer's account into a staging bucket (`lockupCurrent`) without completing the flow of funds to the payee -- that part is done per-rail during rail settlement.  To enable the contract to efficiently handle account settlement over many rails, accounts only maintain global state of the lockup requirements of all rails: `lockupRate`.  Accounts track deposited funds, total locked funds, rate of continuous lockup and the last epoch they were settled at.  

The Account struct 
```solidity
    struct Account {
        uint256 funds;
        uint256 lockupCurrent;
        uint256 lockupRate;
        // epoch up to and including which lockup has been settled for the account
        uint256 lockupLastSettledAt;
    }
```

The `lockupCurrent` field is the intermediate bucket holding onto funds claimed by rails.  The free funds of the account are `funds` - `lockupCurrent`.  Free funds flow into `lockupCurrent` at `lockupRate` tokens per epoch. 

As mentioned above account settlement is a precondition to every state modifying call in the payments contract. It is actually structured as both a pre and post condition 

```solidity
 modifier settleAccountLockupBeforeAndAfter(address token, address owner, bool settleFull) {
        Account storage payer = accounts[token][owner];

        // Before function execution
        performSettlementCheck(token, owner, payer, settleFull, true);

        _;

        // After function execution
        performSettlementCheck(token, owner, payer, settleFull, false);
    }
```

The core of account settlement is calculating how much funds should be flowing out of this account since the previous settlement epoch `lockupLastSettledAt`. In this simple case `lockupRate * (block.current - lockupLastSettledAt)` is added to `lockupCurrent`.  If there are insufficient funds to do this then account settlement first calculates how many epochs can be settled up to with the current funds: `fractionalEpochs = availableFunds / account.lockupRate;`.  Then settlement is completed up to `lockupLastSettledAt + fractoinalEpochs`.

The withdraw function is special in that it requires that the account is fully settled by assigning `true` to `settleFull` in its modifier. All other methods allow account settlement to progress as far as possible without fully settling as valid pre and post conditions.  This means that accounts are allowed to be in debt with lower temporary settling lockup in their `lockupCurrent` then the total that all the account's rails have a claim on. Note that this notion of debt does not take into account the streaming lockup. If the rail is terminated then a `lockupPeriod` of funds is guaranteed to be covered since those funds are enforced to be locked in `lockupCurrent` upon rail modification.

## Rails and Rail Settlement

Rail settlement completes the fundamental flow of funds from payer account to payee account by moving funds from account `lockupCurrent` to the rail payee's account. Any party involved in the rail, operator, payee or payer, can call settlement.  It is useful to keep the rail datastructure in mind when discussing rail settlement:

```solidity
    struct Rail {
        address token;
        address from;
        address to;
        address operator;
        address validator;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        // epoch up to and including which this rail has been settled
        uint256 settledUpTo;
        RateChangeQueue.Queue rateChangeQueue;
        uint256 endEpoch; // Final epoch up to which the rail can be settled (0 if not terminated)
        // Operator commission rate in basis points (e.g., 100 BPS = 1%)
        uint256 commissionRateBps;
        address serviceFeeRecipient; // address to collect operator comission
    }
```

At its core rail settlement simply multiplies the duration of the total time being settled by the rail's outgoing rate, reduces the payer Account's `lockupCurrent` and `funds` by this amount and adds this amount to the `funds` of the payee Account. 

This is a bit more complicated in practice because rail rates can change. For more on how this happens see [Rail Changes](#rail-changes) below.  For this reason Rails are always settled in segments.  Segments are a record of the rail's changing rate over time.  Each rail tracks its segments in a RateChangeQueue.  New segments are added to the queue each time the rate is changed.  Rail settlement then performs the core settlement operation on each segment with a different rate.  The function at the heart of rail settlement is called `_settleSegment`. The function organizing traversal of segments and calling `_settleSegment` on each one individually is `_settleWithRateChanges`.

Settlement is further complicated because the settlement period can vary. Rails are settled up to a user defined parameter `untilEpoch` which may be any epoch before the current network epoch. The `untilEpoch` is internally restricted to be the minimum of the user specified epoch and the payer account's `lockupLastSettledAt` epoch.  This comes from the nature of the fundamental flow of funds -- funds cannot flow into a payee rail without first being locked up in the payer account's `lockupCurrent` and the last epoch the rail's rate of funds are locked is exactly the `lockupLastSettledAt`.

Each segment of the rate change queue is pushed once and popped once. Rail settlment reads every segment up to the `untilEpoch` and processes them.  Rail settlment may not empty the queue in the case that the `untilEpoch` is in the past.  Logic in `_settleWithRateChanges` handles edge cases like partially settled segments and zero rate segments.

As part of its logic `_settleSegment` checks the rail's `validator` address.  If it is nonzero then the validator contract is consulted for modifying the payment.  Validator's can modify the rail settlement amount adn the final `untilEpoch`.  For background on the purpose of rail validation please see the README. For more about validation see [the section below](#validation). 

### Terminated Rail Settlement

Terminated rails settle in much the same way as live rails. Terminated rails are also processed via calls to `_settleSegment` and move funds locked in an accounts `lockupCurrent` into the payee account.  The major difference is that terminated rail settlement funds are completely covered by the streaming lockup which contract invariants enforce must be held in `lockupCurrent`.  For this reason the `untilEpoch` is not checked against the account's `lockupLastSettledAt` in the termianted rail case -- the funds are already kept locked in the account and can be spent without checking.

Rail settlement always tries to finalize a terminated rail before returning. Finalization has three effects. First it has the effect of flowing unused rail fixed lockup funds out of the payer account `lockupCurrent` and back to the account's available balance. Second the operator usage for streaming lockup and unused fixed lockup is removed and the operator reclaims this allowance for lockup operations on other rails.  Finally the `Rail` datastructure is zeroed out indicating that the rail is finalized and therefore invalid for modifications.  The zeroed out condition is checked in various places in the code and operations on rails meeting this condition revert with `Errors.RailInactiveOrSettled(railId)`.

### Validation 

With one exception validation is run for all instances of rail segment settlement live and terminated.  When many segments are settled validation is run on each segment.  The validation interface is 

```solidity
interface IValidator {
    struct ValidationResult {
        // The actual payment amount determined by the validator after validation of a rail during settlement
        uint256 modifiedAmount;
        // The epoch up to and including which settlement should occur.
        uint256 settleUpto;
        // A placeholder note for any additional information the validator wants to send to the caller of `settleRail`
        string note;
    }

    function validatePayment(
        uint256 railId,
        uint256 proposedAmount,
        // the epoch up to and including which the rail has already been settled
        uint256 fromEpoch,
        // the epoch up to and including which validation is requested; payment will be validated for (toEpoch - fromEpoch) epochs
        uint256 toEpoch,
        uint256 rate
    ) external returns (ValidationResult memory result);
}
```

The parameters encode a settlement segment and the result allows the validator to change the total amount settled and the epoch up to which settlement takes place.  A few sanity checks constrain the `ValidationResult`. The validator can't authorize more payment than would flow through the rail without validation or settle the rail up to an epoch beyond the provided `toEpoch`.  The zero address is an allowed validator.

Note that when the validator withholds some of the funds from being paid out the rail settlement code still unlocks those funds from the `lockupCurrent` bucket in the payer account.  Essentially the validator flows those funds back to the payer account's available balance.

The one exception when rails can be settled without validation is in the post termination failsafe `settleTerminatedRailWithoutValidation` which exists to protect against buggy validators stopping all payments between parties.  This method calls `_settleSegment` with no validation and hence pays in full.

### One Time Payments

One time payments are a way to pay lump sums of tokens over a rail.  They require a rail to be setup but do not have any persistent rate based flow.  One time payments don't interact with rail or account settlement at all but still follow the fundamental principle of flow of funds.  All one time payments are paid directly out of the fixed lockup of a rail which is locked into account `lockupCurrent` during rail changes via `modifyRailLockup`.  One time payments are initiated with a call to `modifyRailPayment` with a nonzero third parameter.  This method reduces all lockup tracking parameters by the one time payment amount -- the account `lockupCurrent` and `funds`, the  rail `fixedLockup` and the approval `lockupUsage` and `lockupAllowance`.  Then it increases the payee's `funds` by the payment.

One time payments can be made after termination but only before the rail's end epoch.

### Rail Changes 

All rails start with no payments or lockup.  `createRail` just makes an empty rail between a payer and payee overseen by an operator and optionally arbitrated with a validator.

Rails can be modified in three main ways.  The first is by changing the rail's `fixedLockup` via the `modifyRailLockup` call.  The second is by changing the rail's `lockupPeriod` and hence streaming lockup, again via `modifyRailLockup` call.  And the third is by chaning `modifyRailPayment` with a new rail rate.

Rate changes to a rail are the most complex.  They require adding a segment to the rate change queue to enable correct accounting of future rail settlement.  They also enforce changes to locked funds because rate changes alway imply a change to the streaming lockup (which is `rate * lockupPeriod`).

All three modifications change the total amount of `lockupCurrent` in the payer's account.  These changes are made over the payer's account under the assumption that they have enough available balance which is then checked in the post condition modifier.

Only live fully settled accounts without any debt, i.e. with `lockupLastSettledAt == block.number`, are allowed to increase `fixedLockup`, make any changes to the `lockupPeriod` or increase to the rail's `paymentRate`. Terminated and debtor rails *are* allowed to *reduce* their `fixedLockup`.  And terminated rails are allowed to decrease the rail's payment rate (debtors can't make any changes).

For all three changes the operator approval must be consulted to check that the proposed modifications are within the operator's remaining allowances.  It is worth noting that the operator approval has a field `maxLockupPeriod` which sets a ceiling on the lockup period and hence streaming lockup.

All rail modifications including rail creation must be called by the operator.


## Rail Termination

If you've read this far you've seen several implications of termination on rail modification, settlement, and allowance accounting.  By now it is not too surprising to hear that terminated and not yet finalized rails are not so much an edge case as a distinct third type of payment process alongside one time payments and live rails. 

The process of termination itself is very simple compared to its handling throughout the rail code.  Rail termination does exactly three things.  First it sets up an end epoch on the rail equal to one `lockupPeriod` past the rail's last settlement epoch.  Second it removes the rail's `paymentRate` from the payee account's `lockupRate`.  And finally it reduces the operator approval's rate usage to match the reduction in rate usage.

With this account settlement no longer flows funds into the `lockupCurrent` of the payer.  The streaming lockup is now used for exactly one `lockupPeriod` to move payments to the payee's account.  And with the end epoch set the rail will only payout exactly the streaming lockup for exactly the `lockupPeriod`.

Rails become finalized when settled at or beyond their end epoch.  Finalization refunds the unused fixed lockup back to the payer and releases the `lockupUsage` from any remaining fixed lockup and all of the recently paid streaming lockup.




