// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Errors} from "../Errors.sol";
import {IFWSSConfig} from "../interfaces/IFWSSConfig.sol";

/// @title FWSSConfigModule
/// @notice Exposes shared immutable dependencies to FWSS modules through the proxy.
/// @dev Uses no proxy storage. Replacing the getter routes can change the exposed configuration.
contract FWSSConfigModule is IFWSSConfig {
    /// @inheritdoc IFWSSConfig
    address public immutable override paymentsContractAddress;

    /// @inheritdoc IFWSSConfig
    address public immutable override pdpVerifierAddress;

    /// @param _paymentsContractAddress The FilecoinPay contract holding the existing FWSS rails.
    /// @param _pdpVerifierAddress The existing FWSS PDP verifier contract.
    constructor(address _paymentsContractAddress, address _pdpVerifierAddress) {
        require(_paymentsContractAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilecoinPayV1));
        require(_pdpVerifierAddress != address(0), Errors.ZeroAddress(Errors.AddressField.PDPVerifier));
        paymentsContractAddress = _paymentsContractAddress;
        pdpVerifierAddress = _pdpVerifierAddress;
    }
}
