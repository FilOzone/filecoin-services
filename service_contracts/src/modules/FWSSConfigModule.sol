// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Errors} from "../Errors.sol";
import {IFWSSConfig} from "../interfaces/IFWSSConfig.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TOKEN_DECIMALS} from "../lib/PriceListUSDFC.sol";

/// @title FWSSConfigModule
/// @notice Exposes shared immutable dependencies to FWSS modules through the proxy.
/// @dev Uses no proxy storage. Replacing the getter routes can change the exposed configuration.
contract FWSSConfigModule is IFWSSConfig {
    /// @inheritdoc IFWSSConfig
    address public immutable override paymentsContractAddress;

    /// @inheritdoc IFWSSConfig
    address public immutable override pdpVerifierAddress;

    /// @inheritdoc IFWSSConfig
    IERC20Metadata public immutable override usdfcTokenAddress;

    /// @param _paymentsContractAddress The FilecoinPay contract holding the existing FWSS rails.
    /// @param _pdpVerifierAddress The existing FWSS PDP verifier contract.
    /// @param _usdfc The USDFC token used by the dataset and payment modules.
    constructor(address _paymentsContractAddress, address _pdpVerifierAddress, IERC20Metadata _usdfc) {
        require(_paymentsContractAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilecoinPayV1));
        require(_pdpVerifierAddress != address(0), Errors.ZeroAddress(Errors.AddressField.PDPVerifier));
        require(_usdfc != IERC20Metadata(address(0)), Errors.ZeroAddress(Errors.AddressField.USDFC));
        require(TOKEN_DECIMALS == _usdfc.decimals());
        paymentsContractAddress = _paymentsContractAddress;
        pdpVerifierAddress = _pdpVerifierAddress;
        usdfcTokenAddress = _usdfc;
    }
}
