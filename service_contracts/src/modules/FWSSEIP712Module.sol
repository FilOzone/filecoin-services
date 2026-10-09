// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IFWSSEIP712} from "../interfaces/IFWSSEIP712.sol";

/// @title FWSSEIP712Module
/// @notice Exposes the shared FWSS signing domain using OpenZeppelin's existing proxy storage.
/// @dev The domain is initialized by FWSS before the dispatcher transition.
contract FWSSEIP712Module is EIP712Upgradeable, IFWSSEIP712 {
    /// @inheritdoc IFWSSEIP712
    function domainSeparatorV4() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }
}
