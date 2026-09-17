// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {IFilecoinServiceMetadata} from "../IFilecoinServiceMetadata.sol";

/// @title MetadataModule
/// @notice Exposes static FWSS service metadata.
contract MetadataModule is IFilecoinServiceMetadata {
    // Version tracking
    string public constant VERSION = "1.4.0";
    string internal constant SERVICE_NAME = "Filecoin Warm Storage Service";
    string internal constant SERVICE_DESCRIPTION =
        "Warm storage service for the Filecoin Onchain Cloud. Manages PDP-backed datasets, Filecoin Pay storage rails, lifecycle fees, and optional CDN payment rails.";
    string private constant SERVICE_HOMEPAGE = "https://github.com/FilOzone/filecoin-services";

    function name() external pure override returns (string memory) {
        return SERVICE_NAME;
    }

    function description() external pure override returns (string memory) {
        return SERVICE_DESCRIPTION;
    }

    function homepage() external pure override returns (string memory) {
        return SERVICE_HOMEPAGE;
    }
}
