// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {FilecoinPayV2} from "@filecoin-pay-v2/FilecoinPayV2.sol";
import {CREATE_RAIL} from "@filecoin-pay-v2/lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, Stream} from "@filecoin-pay-v2/lib/RailId.sol";
import {ScriptBuilder, newScript} from "@filecoin-pay-v2/lib/Script.sol";
import {CDNPaymentRailsToppedUp} from "./LibRails.sol";
import {StoragePricing} from "./StoragePricing.sol";
import {
    DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
    DEFAULT_CDN_LOCKUP_AMOUNT,
    LIFECYCLE_RESERVE_TARGET
} from "./PriceListUSDFC.sol";

/// @title LibRailsV2
/// @notice FilecoinPayV2 rail operations inlined into the FWSS modules.
library LibRailsV2 {
    using RailIdLibrary for Stream;

    // Each rail role gets its own nonce, so rails stay distinct when the payee is the FilBeam beneficiary.
    uint64 internal constant CDN_RAIL_NONCE_FLAG = 1 << 62;

    error DataSetIdTooLarge(uint256 dataSetId);

    /// @notice Opens the data set's rails on FilecoinPayV2 in one script, with this contract as their operator.
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
        uint64 pdpNonce = FLAG_CALLBACK | cacheMissNonce;
        uint64 cdnNonce = CDN_RAIL_NONCE_FLAG | cacheMissNonce;

        // The lifecycle reserve is a lock on the PDP rail. A payer balance short of the locks reverts in executeScript.
        uint256 lifecycleReserve = StoragePricing.scaleAmount(LIFECYCLE_RESERVE_TARGET, tokenDecimals);
        uint256 cacheMissLockup;
        uint256 cdnLockup;
        if (hasCDN) {
            cacheMissLockup = StoragePricing.scaleAmount(DEFAULT_CACHE_MISS_LOCKUP_AMOUNT, tokenDecimals);
            cdnLockup = StoragePricing.scaleAmount(DEFAULT_CDN_LOCKUP_AMOUNT, tokenDecimals);
        }

        // ScriptBuilder grows at the free-memory pointer, so nothing may allocate between newScript() and build().
        ScriptBuilder script =
            newScript().setToken(token).createRail(payer, payee, pdpNonce).lock(uint128(lifecycleReserve));
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
