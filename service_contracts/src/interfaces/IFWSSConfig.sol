// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IFWSSConfig
/// @notice Shared external dependencies exposed through the FWSS proxy.
interface IFWSSConfig {
    /// @notice Returns the FilecoinPay contract holding the FWSS rails.
    function paymentsContractAddress() external view returns (address);

    /// @notice Returns the PDP verifier contract.
    function pdpVerifierAddress() external view returns (address);

    /// @notice Returns the USDFC token used by the FWSS deployment.
    function usdfcTokenAddress() external view returns (IERC20Metadata);
}
