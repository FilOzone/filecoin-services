// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Errors} from "../Errors.sol";
import {IFWSSConfig} from "../interfaces/IFWSSConfig.sol";

/// @title FWSSPDPVerifier
/// @notice Shared PDP verifier authorization for FWSS modules.
/// @dev Adds no storage or external functions.
abstract contract FWSSPDPVerifier {
    /// @notice Ensures the caller is the configured PDP verifier.
    modifier onlyPDPVerifier() {
        _onlyPDPVerifier();
        _;
    }

    /// @notice Reverts when the caller is not the configured PDP verifier.
    function _onlyPDPVerifier() internal view {
        address pdpVerifierAddress = IFWSSConfig(address(this)).pdpVerifierAddress();
        require(msg.sender == pdpVerifierAddress, Errors.OnlyPDPVerifierAllowed(pdpVerifierAddress, msg.sender));
    }
}
