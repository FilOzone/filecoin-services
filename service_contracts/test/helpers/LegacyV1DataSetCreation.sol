// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {ProxyStorage} from "@erc8167/lib/ProxyStorage.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {FWSSDeployer} from "../../script/lib/FWSSDeployer.sol";
import {ServiceProviderRegistry} from "../../src/ServiceProviderRegistry.sol";
import {CDNPaymentRailsToppedUp} from "../../src/lib/LibRails.sol";
import {
    CDN_LOCKUP_PERIOD,
    DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
    DEFAULT_CDN_LOCKUP_AMOUNT,
    DEFAULT_LOCKUP_PERIOD,
    LIFECYCLE_RESERVE_TARGET,
    SERVICE_COMMISSION_BPS
} from "../../src/lib/PriceListUSDFC.sol";
import {StoragePricing} from "../../src/lib/StoragePricing.sol";
import {FWSSDataSetModule} from "../../src/modules/FWSSDataSetModule.sol";

/// @dev Test-only data set module that opens the rails on FilecoinPayV1, as FWSS did before FilecoinPayV2.
/// Data sets created that way stay live on mainnet until their rails drain, so the flows after creation are
/// still tested on them.
contract LegacyV1DataSetModule is FWSSDataSetModule {
    constructor(FWSSDeployer.FWSSDeployment memory deployment)
        FWSSDataSetModule(
            deployment.payments,
            deployment.pdpVerifier,
            IERC20Metadata(deployment.usdfc),
            deployment.filBeamBeneficiary,
            ServiceProviderRegistry(deployment.serviceProviderRegistry),
            SessionKeyRegistry(deployment.sessionKeyRegistry),
            deployment.filecoinPayV2
        )
    {}

    function _createRails(
        uint256 dataSetId,
        address token,
        uint8 tokenDecimals,
        address payer,
        address payee,
        bool hasCDN
    ) internal override returns (uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId) {
        FilecoinPayV1 payments = paymentContract;
        pdpRailId =
            payments.createRail(IERC20(token), payer, payee, address(this), SERVICE_COMMISSION_BPS, address(this));
        payments.modifyRailLockup(
            pdpRailId, DEFAULT_LOCKUP_PERIOD, StoragePricing.scaleAmount(LIFECYCLE_RESERVE_TARGET, tokenDecimals)
        );

        if (hasCDN) {
            uint256 cacheMissLockup = StoragePricing.scaleAmount(DEFAULT_CACHE_MISS_LOCKUP_AMOUNT, tokenDecimals);
            uint256 cdnLockup = StoragePricing.scaleAmount(DEFAULT_CDN_LOCKUP_AMOUNT, tokenDecimals);
            cacheMissRailId = payments.createRail(IERC20(token), payer, payee, address(0), 0, address(this));
            payments.modifyRailLockup(cacheMissRailId, CDN_LOCKUP_PERIOD, cacheMissLockup);
            cdnRailId =
                payments.createRail(IERC20(token), payer, filBeamBeneficiaryAddress, address(0), 0, address(this));
            payments.modifyRailLockup(cdnRailId, CDN_LOCKUP_PERIOD, cdnLockup);
            emit CDNPaymentRailsToppedUp(dataSetId, cdnLockup, cdnLockup, cacheMissLockup, cacheMissLockup);
        }
    }
}

/// @dev Routes dataSetCreated on an FWSS proxy to LegacyV1DataSetModule.
abstract contract LegacyV1DataSetCreation is FWSSDeployer {
    /// @return dataSetModule The module that served dataSetCreated before, which creates FilecoinPayV2 rails
    function _routeV1DataSetCreation(address fwss, FWSSDeployment memory deployment)
        internal
        returns (address dataSetModule)
    {
        bytes32 key = ProxyStorage.delegateStorageKey(FWSSDataSetModule.dataSetCreated.selector);
        dataSetModule = address(uint160(uint256(vm.load(fwss, key))));
        vm.store(fwss, key, bytes32(uint256(uint160(address(new LegacyV1DataSetModule(deployment))))));
    }
}
