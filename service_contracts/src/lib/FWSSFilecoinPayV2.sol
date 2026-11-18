// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {FilecoinPayV2} from "@filecoin-pay-v2/FilecoinPayV2.sol";
import {Errors} from "../Errors.sol";

/// @title FWSSFilecoinPayV2
/// @notice Shared FilecoinPayV2 dependency for FWSS modules.
/// @dev Adds no storage or external functions.
abstract contract FWSSFilecoinPayV2 {
    /// @notice The implementation-bound FilecoinPayV2 contract that FWSS rails move to.
    FilecoinPayV2 internal immutable filecoinPayV2;

    /// @param _filecoinPayV2Address The FilecoinPayV2 contract that FWSS rails move to.
    constructor(address _filecoinPayV2Address) {
        require(_filecoinPayV2Address != address(0), Errors.ZeroAddress(Errors.AddressField.FilecoinPayV2));
        filecoinPayV2 = FilecoinPayV2(_filecoinPayV2Address);
    }

    /// @notice Tells FilecoinPayV1 rail ids, which count up from one, from FilecoinPayV2 rail ids, which are hashes.
    /// @param railId A rail id stored in DataSetInfo
    /// @return True when the rail lives on FilecoinPayV1
    function _isV1Rail(uint256 railId) internal pure returns (bool) {
        return railId < 1 << 64;
    }
}
