// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IFWSSEIP712} from "../interfaces/IFWSSEIP712.sol";

/// @title FWSSEIP712
/// @notice Shared internal signing helpers for FWSS modules.
/// @dev Adds no storage or external functions. Requires the signing domain route on the proxy.
abstract contract FWSSEIP712 {
    /**
     * @notice Reads the domain separator from the shared EIP-712 module through the proxy.
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        return IFWSSEIP712(address(this)).domainSeparatorV4();
    }

    /**
     * @notice Combines an operation's struct hash with the shared signing domain.
     */
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    }
}
