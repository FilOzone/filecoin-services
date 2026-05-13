// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SYBIL_FEE} from "./PriceListUSDFC.sol";

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
}
