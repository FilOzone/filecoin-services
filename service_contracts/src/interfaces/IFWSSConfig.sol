// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

/// @title IFWSSConfig
/// @notice Shared external dependencies exposed through the FWSS proxy.
interface IFWSSConfig {
    /// @notice Returns the FilecoinPay contract holding the FWSS rails.
    function paymentsContractAddress() external view returns (address);

    /// @notice Returns the PDP verifier contract.
    function pdpVerifierAddress() external view returns (address);
}
