// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DEFAULT_LOCKUP_PERIOD, SYBIL_FEE} from "./PriceListUSDFC.sol";

event CDNPaymentRailsToppedUp(
    uint256 indexed dataSetId,
    uint256 cdnAmountAdded,
    uint256 totalCdnLockup,
    uint256 cacheMissAmountAdded,
    uint256 totalCacheMissLockup
);

event CDNServiceTerminated(
    address indexed caller, uint256 indexed dataSetId, uint256 cacheMissRailId, uint256 cdnRailId
);

library Rails {
    function burnSybil(FilecoinPayV1 payments, IERC20 token, address payer) public {
        uint256 burnRailId = payments.createRail(
            token,
            payer, // from: client
            address(payments), // to: payments contract (auction pool)
            address(0), // no validator
            0, // no commission
            address(0) // service fee recipient (unused, commission=0)
        );
        payments.modifyRailLockup(burnRailId, 0, SYBIL_FEE);
        payments.modifyRailPayment(burnRailId, 0, SYBIL_FEE);
        payments.terminateRail(burnRailId);
        payments.settleRail(burnRailId, block.number);
    }

    function terminateCDNRails(FilecoinPayV1 payments, uint256 dataSetId, uint256 cacheMissRailId, uint256 cdnRailId)
        public
    {
        try payments.terminateRail(cacheMissRailId) {} catch {}
        try payments.terminateRail(cdnRailId) {} catch {}
        emit CDNServiceTerminated(msg.sender, dataSetId, cacheMissRailId, cdnRailId);
    }

    function topUpCDNRails(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        uint256 cacheMissRailId,
        uint256 cdnRailId,
        uint256 cacheMissAmountToAdd,
        uint256 cdnAmountToAdd
    ) public {
        // Both rails must be active for any top-up operation
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(cacheMissRailId);

        require(cdnRail.endEpoch == 0, Errors.CDNPaymentAlreadyTerminated(dataSetId));
        require(cacheMissRail.endEpoch == 0, Errors.CacheMissPaymentAlreadyTerminated(dataSetId));

        // Require at least one amount to be non-zero
        if (cdnAmountToAdd == 0 && cacheMissAmountToAdd == 0) {
            revert Errors.InvalidTopUpAmount(dataSetId);
        }

        // Calculate total lockup amounts
        uint256 totalCdnLockup = cdnRail.lockupFixed + cdnAmountToAdd;
        uint256 totalCacheMissLockup = cacheMissRail.lockupFixed + cacheMissAmountToAdd;

        // Only modify rails if amounts are being added
        payments.modifyRailLockup(cdnRailId, DEFAULT_LOCKUP_PERIOD, totalCdnLockup);
        payments.modifyRailLockup(cacheMissRailId, DEFAULT_LOCKUP_PERIOD, totalCacheMissLockup);
        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnAmountToAdd, totalCdnLockup, cacheMissAmountToAdd, totalCacheMissLockup
        );
    }

    function settleCDNRails(
        FilecoinPayV1 payments,
        uint256 cdnRailId,
        uint256 cacheMissRailId,
        uint256 cdnAmount,
        uint256 cacheMissAmount
    ) public {
        if (cdnAmount > 0) {
            payments.modifyRailPayment(cdnRailId, 0, cdnAmount);
        }

        if (cacheMissAmount > 0) {
            payments.modifyRailPayment(cacheMissRailId, 0, cacheMissAmount);
        }
    }
}
