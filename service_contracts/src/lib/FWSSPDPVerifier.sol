// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Errors} from "../Errors.sol";

/// @title FWSSPDPVerifier
/// @notice Shared PDP verifier authorization for FWSS modules.
/// @dev Adds no storage or external functions.
abstract contract FWSSPDPVerifier {
    /// @notice The implementation-bound PDP verifier authorized to invoke FWSS callbacks.
    address internal immutable pdpVerifierAddress;

    /// @param _pdpVerifierAddress The PDP verifier authorized to invoke FWSS callbacks.
    constructor(address _pdpVerifierAddress) {
        require(_pdpVerifierAddress != address(0), Errors.ZeroAddress(Errors.AddressField.PDPVerifier));
        pdpVerifierAddress = _pdpVerifierAddress;
    }

    /// @notice Ensures the caller is the configured PDP verifier.
    modifier onlyPDPVerifier() {
        _onlyPDPVerifier();
        _;
    }

    /// @notice Reverts when the caller is not the configured PDP verifier.
    function _onlyPDPVerifier() internal view {
        require(msg.sender == pdpVerifierAddress, Errors.OnlyPDPVerifierAllowed(pdpVerifierAddress, msg.sender));
    }
}
