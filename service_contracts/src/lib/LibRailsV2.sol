// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {FilecoinPayV2} from "@filecoin-pay-v2/FilecoinPayV2.sol";
import {IExtsload} from "@filecoin-pay-v2/interfaces/IExtsload.sol";
import {CREATE_RAIL, NONE} from "@filecoin-pay-v2/lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, Stream} from "@filecoin-pay-v2/lib/RailId.sol";
import {ScriptBuilder, newScript} from "@filecoin-pay-v2/lib/Script.sol";
import {CDNPaymentRailsToppedUp, RailRateUpdated} from "./LibRails.sol";
import {StoragePricing} from "./StoragePricing.sol";
import {
    CREATE_DATA_SET_FEE,
    DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
    DEFAULT_CDN_LOCKUP_AMOUNT,
    DEFAULT_LOCKUP_PERIOD,
    TERMINATE_FEE
} from "./PriceListUSDFC.sol";

/// @title LibRailsV2
/// @notice FilecoinPayV2 rail operations inlined into the FWSS modules.
library LibRailsV2 {
    using RailIdLibrary for Stream;

    // Each rail role gets its own nonce, so rails stay distinct when the payee is the FilBeam beneficiary.
    uint64 internal constant CDN_RAIL_NONCE_FLAG = 1 << 62;

    error DataSetIdTooLarge(uint256 dataSetId);
    error RateTooLarge(uint256 rate);

    /// @notice Opens the data set's rails on FilecoinPayV2 in one script, with this contract as their operator,
    /// and pays the creation fee to the payee.
    /// @param payments The FilecoinPayV2 contract instance
    /// @param dataSetId The data set the rail nonces derive from
    /// @param token The currency selected by the data set's storage terms; address(0) is native FIL
    /// @param payer The payer whose FilecoinPayV2 balance funds the rails
    /// @param payee The service provider's payee
    /// @param filBeamBeneficiaryAddress The CDN rail's recipient, or address(0) to open no CDN rails
    /// @param tokenDecimals The selected currency's precision
    /// @return pdpRailId The PDP rail, which settles through FWSS
    /// @return cacheMissRailId The cache-miss rail, or zero without CDN
    /// @return cdnRailId The CDN rail, or zero without CDN
    function createRails(
        FilecoinPayV2 payments,
        uint256 dataSetId,
        address token,
        address payer,
        address payee,
        address filBeamBeneficiaryAddress,
        uint8 tokenDecimals
    ) internal returns (uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId) {
        require(dataSetId < CDN_RAIL_NONCE_FLAG, DataSetIdTooLarge(dataSetId));
        bool hasCDN = filBeamBeneficiaryAddress != address(0);
        uint64 cacheMissNonce = uint64(dataSetId);
        uint64 pdpNonce = pdpRailNonce(dataSetId);
        uint64 cdnNonce = CDN_RAIL_NONCE_FLAG | cacheMissNonce;

        // The PDP rail keeps only the termination fee locked, the one fee that may come due when the payer has nothing
        // left. The creation fee passes through the rail to the payee. A short payer balance reverts in executeScript.
        uint256 createFee = StoragePricing.scaleAmount(CREATE_DATA_SET_FEE, tokenDecimals);
        uint256 terminateFee = StoragePricing.scaleAmount(TERMINATE_FEE, tokenDecimals);
        uint256 cacheMissLockup;
        uint256 cdnLockup;
        if (hasCDN) {
            cacheMissLockup = StoragePricing.scaleAmount(DEFAULT_CACHE_MISS_LOCKUP_AMOUNT, tokenDecimals);
            cdnLockup = StoragePricing.scaleAmount(DEFAULT_CDN_LOCKUP_AMOUNT, tokenDecimals);
        }

        // ScriptBuilder grows at the free-memory pointer, so nothing may allocate between newScript() and build().
        ScriptBuilder script = newScript().setToken(token).createRail(payer, payee, pdpNonce)
            .lock(uint128(terminateFee + createFee)).disburse(uint128(createFee));
        if (hasCDN) {
            script = script.createRail(payer, payee, cacheMissNonce).lock(uint128(cacheMissLockup))
                .createRail(payer, filBeamBeneficiaryAddress, cdnNonce).lock(uint128(cdnLockup));
        }
        payments.executeScript(CREATE_RAIL, script.build());

        pdpRailId = railId(payer, payee, token, pdpNonce);
        if (hasCDN) {
            cacheMissRailId = railId(payer, payee, token, cacheMissNonce);
            cdnRailId = railId(payer, filBeamBeneficiaryAddress, token, cdnNonce);
            emit CDNPaymentRailsToppedUp(dataSetId, cdnLockup, cdnLockup, cacheMissLockup, cacheMissLockup);
        }
    }

    /// @notice The nonce of a data set's PDP rail, which settles through the FWSS callback
    /// @param dataSetId The data set the rail pays for
    /// @return The rail nonce with FLAG_CALLBACK set
    function pdpRailNonce(uint256 dataSetId) internal pure returns (uint64) {
        return FLAG_CALLBACK | uint64(dataSetId);
    }

    /// @notice Pays a one-time fee from the payer's FilecoinPayV2 balance to the payee through the data set's PDP rail
    /// @dev Lock, disburse and setRail need no grant from the payer, so the script runs with no permissions. The lock
    /// and the disburse cancel out, so the rail's available balance, and the payment it holds, stay as they were.
    /// @param payments The FilecoinPayV2 contract instance
    /// @param dataSetId The data set the PDP rail pays for
    /// @param token The rail's currency; address(0) is native FIL
    /// @param payer The rail's payer
    /// @param payee The rail's recipient
    /// @param fee The amount to pay
    function chargeOnPdpRail(
        FilecoinPayV2 payments,
        uint256 dataSetId,
        address token,
        address payer,
        address payee,
        uint256 fee
    ) internal {
        uint64 nonce = pdpRailNonce(dataSetId);
        // ScriptBuilder grows at the free-memory pointer, so nothing may allocate between newScript() and build().
        payments.executeScript(
            NONE,
            newScript().setToken(token).setRail(payer, payee, nonce).lock(uint128(fee)).disburse(uint128(fee)).build()
        );
    }

    /// @notice Sets a data set's PDP rail rate, moves the rate lockup with it, and pays a one-time fee to the payee
    /// @dev Lock, unlock, disburse, setRate and setRail need no grant from the payer, so the script runs with no
    /// permissions. setRate goes first: it settles the rail, and the settleRail callback sizes the held payment by the
    /// old rate's lockup.
    /// @param payments The FilecoinPayV2 contract instance
    /// @param dataSetId The data set the PDP rail pays for
    /// @param pdpRailId The data set's PDP rail
    /// @param token The rail's currency; address(0) is native FIL
    /// @param payer The rail's payer
    /// @param payee The rail's recipient
    /// @param newRate The rail's new rate per epoch
    /// @param fee The one-time fee to pay
    function setPdpRate(
        FilecoinPayV2 payments,
        uint256 dataSetId,
        uint256 pdpRailId,
        address token,
        address payer,
        address payee,
        uint256 newRate,
        uint256 fee
    ) internal {
        require(newRate <= type(uint88).max, RateTooLarge(newRate));
        uint256 oldLockup =
            rateLockup(RailIdLibrary.getRail(IExtsload(address(payments)), RailId.wrap(pdpRailId)).incomingRate);
        uint256 newLockup = rateLockup(newRate);
        uint256 lockAmount = fee;
        uint256 unlockAmount;
        if (newLockup > oldLockup) {
            lockAmount += newLockup - oldLockup;
        } else {
            unlockAmount = oldLockup - newLockup;
        }
        uint64 nonce = pdpRailNonce(dataSetId);

        // ScriptBuilder grows at the free-memory pointer, so nothing may allocate between newScript() and build().
        ScriptBuilder script = newScript().setToken(token).setRail(payer, payee, nonce).setRate(uint88(newRate));
        if (unlockAmount != 0) script = script.unlock(uint128(unlockAmount));
        if (lockAmount != 0) script = script.lock(uint128(lockAmount));
        if (fee != 0) script = script.disburse(uint128(fee));
        payments.executeScript(NONE, script.build());

        emit RailRateUpdated(dataSetId, pdpRailId, newRate);
    }

    /// @notice The lock that backs a PDP rail's rate: DEFAULT_LOCKUP_PERIOD epochs of payment, as FilecoinPayV1 keeps
    /// @dev Nothing stores the lock, so changing DEFAULT_LOCKUP_PERIOD needs a migration of the locks on live rails.
    /// @param rate The rail's rate per epoch
    /// @return The amount locked on the rail for the rate
    function rateLockup(uint256 rate) internal pure returns (uint256) {
        return rate * DEFAULT_LOCKUP_PERIOD;
    }

    /// @notice Derives the id of a rail this contract operates
    /// @param payer The rail's payer
    /// @param recipient The rail's recipient
    /// @param token The rail's currency; address(0) is native FIL
    /// @param nonce The rail's nonce
    /// @return The FilecoinPayV2 rail id
    function railId(address payer, address recipient, address token, uint64 nonce) internal view returns (uint256) {
        return RailId.unwrap(
            RailIdLibrary.deriveRail(address(this), payer, recipient, uint256(uint160(token)), nonce).getRailId()
        );
    }
}
