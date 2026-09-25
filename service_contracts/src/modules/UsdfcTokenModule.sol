// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Errors} from "../Errors.sol";

/// @title UsdfcTokenModule
/// @notice Exposes the USDFC token that FWSS charges in, formerly an immutable of the monolith.
contract UsdfcTokenModule {
    /// @notice The USDFC token contract
    IERC20Metadata public immutable usdfcTokenAddress;

    /// @param _usdfc The USDFC token the replaced FWSS implementation was deployed with
    constructor(IERC20Metadata _usdfc) {
        require(address(_usdfc) != address(0), Errors.ZeroAddress(Errors.AddressField.USDFC));
        usdfcTokenAddress = _usdfc;
    }
}
