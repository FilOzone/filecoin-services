// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

/// @title IFWSSEIP712
/// @notice Shared signing domain exposed through the FWSS proxy.
interface IFWSSEIP712 is IERC5267 {
    /**
     * @notice Returns the EIP-712 domain separator for the current chain and proxy.
     */
    function domainSeparatorV4() external view returns (bytes32);
}
