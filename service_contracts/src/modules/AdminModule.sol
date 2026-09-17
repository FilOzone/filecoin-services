// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Errors} from "../Errors.sol";
import {IFilecoinServiceMetadata} from "../IFilecoinServiceMetadata.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";

/// @title AdminModule
/// @notice Manages FWSS ownership and static service metadata.
contract AdminModule is OwnableUpgradeable, IFilecoinServiceMetadata, FWSSStorage {
    // Version tracking
    string public constant VERSION = "1.4.0";
    string private constant SERVICE_NAME = "Filecoin Warm Storage Service";
    string private constant SERVICE_DESCRIPTION =
        "Warm storage service for the Filecoin Onchain Cloud. Manages PDP-backed datasets, Filecoin Pay storage rails, lifecycle fees, and optional CDN payment rails.";
    string private constant SERVICE_HOMEPAGE = "https://github.com/FilOzone/filecoin-services";

    event ViewContractSet(address indexed viewContract);

    function name() external pure override returns (string memory) {
        return SERVICE_NAME;
    }

    function description() external pure override returns (string memory) {
        return SERVICE_DESCRIPTION;
    }

    function homepage() external pure override returns (string memory) {
        return SERVICE_HOMEPAGE;
    }

    /**
     * @notice Sets the view contract address (one-time setup)
     * @dev Only callable by the contract owner. This is intended to be called once after deployment
     * or during migration. The view contract should not be changed after initial setup as external
     * systems may cache this address. If a view contract upgrade is needed, deploy a new main
     * contract with the updated view contract reference.
     * @param _viewContract Address of the view contract
     */
    function setViewContract(address _viewContract) external onlyOwner {
        // Ensure the view contract address is not the zero address
        require(_viewContract != address(0), Errors.ZeroAddress(Errors.AddressField.View));

        // Require that the existing set address is still zero (one-time setup only)
        // NOTE: This check is commented out to allow setting the view contract easily during migrations prior to GA
        //       GH ISSUE: https://github.com/FilOzone/filecoin-services/issues/303
        //       This check needs to be re-enabled before mainnet deployment to prevent changing the view contract later.

        // require(viewContractAddress == address(0), Errors.AddressAlreadySet(Errors.AddressField.View));

        viewContractAddress = _viewContract;
        emit ViewContractSet(_viewContract);
    }
}
