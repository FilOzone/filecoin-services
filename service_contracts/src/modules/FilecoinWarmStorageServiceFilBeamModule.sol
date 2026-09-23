// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {Errors} from "../Errors.sol";
import {LibConfig} from "../lib/LibConfig.sol";
import {LibStoragePayments} from "../lib/LibStoragePayments.sol";
import {Rails} from "../lib/Rails.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";

/// @title FilecoinWarmStorageServiceFilBeamModule
/// @notice Manages FWSS CDN payment rails and the FilBeam controller.
contract FilecoinWarmStorageServiceFilBeamModule is FWSSStorage {
    using Rails for FilecoinPayV1;

    event FilBeamControllerChanged(address oldController, address newController);

    // solidity storage representation of string "withCDN"
    bytes32 private constant WITH_CDN_STRING_STORAGE_REPR =
        0x7769746843444e0000000000000000000000000000000000000000000000000e;

    string private constant METADATA_KEY_WITH_CDN = "withCDN";

    modifier onlyFilBeamController() {
        _onlyFilBeamController();
        _;
    }

    function _onlyFilBeamController() internal view {
        require(
            msg.sender == filBeamControllerAddress,
            Errors.OnlyFilBeamControllerAllowed(filBeamControllerAddress, msg.sender)
        );
    }

    /**
     * @notice Settles CDN payment rails with specified amounts
     * @dev Only callable by FilCDN (Operator) contract
     * @param dataSetId The ID of the data set
     * @param cdnAmount Amount to settle for CDN rail
     * @param cacheMissAmount Amount to settle for cache miss rail
     */
    function settleFilBeamPaymentRails(uint256 dataSetId, uint256 cdnAmount, uint256 cacheMissAmount)
        external
        onlyFilBeamController
    {
        DataSetInfo storage info = dataSetInfo[dataSetId];

        // Check if CDN rails are configured (presence of rails indicates CDN was set up)
        require(info.cdnRailId != 0 && info.cacheMissRailId != 0, Errors.InvalidDataSetId(dataSetId));

        FilecoinPayV1(LibConfig.config().paymentsContractAddress)
            .settleCDNRails(info.cdnRailId, info.cacheMissRailId, cdnAmount, cacheMissAmount);
    }

    /**
     * @notice Allows users to add funds to their CDN-related payment rails
     * @param dataSetId The ID of the data set
     * @param cdnAmountToAdd Amount to add to CDN rail lockup
     * @param cacheMissAmountToAdd Amount to add to cache miss rail lockup
     */
    function topUpCDNPaymentRails(uint256 dataSetId, uint256 cdnAmountToAdd, uint256 cacheMissAmountToAdd) external {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));

        // Check authorization - only payer can top up
        require(msg.sender == info.payer, Errors.CallerNotPayer(dataSetId, info.payer, msg.sender));

        // Check if CDN service is configured
        require(dataSetHasCDNMetadataKey(dataSetId), Errors.FilBeamServiceNotConfigured(dataSetId));

        // Check if cache miss and CDN rails are configured
        require(info.cacheMissRailId != 0 && info.cdnRailId != 0, Errors.InvalidDataSetId(dataSetId));

        FilecoinPayV1(LibConfig.config().paymentsContractAddress)
            .topUpCDNRails(dataSetId, info.cacheMissRailId, info.cdnRailId, cacheMissAmountToAdd, cdnAmountToAdd);
    }

    function terminateCDNService(uint256 dataSetId) external onlyFilBeamController {
        // Check if CDN service is configured
        require(deleteCDNMetadataKey(dataSetMetadataKeys[dataSetId]), Errors.FilBeamServiceNotConfigured(dataSetId));
        delete dataSetMetadata[dataSetId][METADATA_KEY_WITH_CDN];

        // Check if cache miss and CDN rails are configured
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.cacheMissRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.cdnRailId != 0, Errors.InvalidDataSetId(dataSetId));
        FilecoinPayV1 payments = FilecoinPayV1(LibConfig.config().paymentsContractAddress);

        LibStoragePayments.terminateCDNRails(dataSetId, info, payments);
    }

    function transferFilBeamController(address newController) external onlyFilBeamController {
        require(newController != address(0), Errors.ZeroAddress(Errors.AddressField.FilBeamController));
        address oldController = filBeamControllerAddress;
        filBeamControllerAddress = newController;
        emit FilBeamControllerChanged(oldController, newController);
    }

    /**
     * @notice Returns true if key `withCDN` exists in the metadata keys of the data set.
     * @param dataSetId The sequential data set identifier
     * @return True if key exists; false otherwise.
     */
    function dataSetHasCDNMetadataKey(uint256 dataSetId) internal view returns (bool) {
        string[] storage metadataKeys = dataSetMetadataKeys[dataSetId];
        unchecked {
            uint256 len = metadataKeys.length;
            for (uint256 i = 0; i < len; i++) {
                string storage metadataKey = metadataKeys[i];
                bytes32 repr;
                assembly ("memory-safe") {
                    repr := sload(metadataKey.slot)
                }
                if (repr == WITH_CDN_STRING_STORAGE_REPR) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @notice Deletes key `withCDN` if it exists in `metadataKeys`.
     * @param metadataKeys The array of metadata keys to modify
     * @return found Whether the withCDN key was deleted
     */
    function deleteCDNMetadataKey(string[] storage metadataKeys) internal returns (bool found) {
        unchecked {
            uint256 len = metadataKeys.length;
            for (uint256 i = 0; i < len; i++) {
                string storage metadataKey = metadataKeys[i];
                bytes32 repr;
                assembly ("memory-safe") {
                    repr := sload(metadataKey.slot)
                }
                if (repr == WITH_CDN_STRING_STORAGE_REPR) {
                    metadataKeys[i] = metadataKeys[len - 1];
                    metadataKeys.pop();
                    return true;
                }
            }
        }
        return false;
    }
}
