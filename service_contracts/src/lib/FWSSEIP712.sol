// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title FWSSEIP712
/// @notice EIP-712 hashing for FWSS modules, backed by the OpenZeppelin EIP712Upgradeable storage slot.
/// @dev Exposes no external functions, so modules can share it without duplicating `eip712Domain()`.
abstract contract FWSSEIP712 {
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.EIP712")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EIP712_STORAGE_LOCATION =
        0xa16a46d94261c7517cc8ff89f61c0ce93598e3c849801011dee649a6a557d100;

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Mirrors OpenZeppelin EIP712Upgradeable.EIP712Storage.
    struct EIP712Storage {
        bytes32 _hashedName;
        bytes32 _hashedVersion;
        string _name;
        string _version;
    }

    /**
     * @notice Returns the domain separator computed as OpenZeppelin EIP712Upgradeable does.
     * @return The EIP-712 domain separator for this proxy.
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        EIP712Storage storage $ = _getEIP712Storage();
        return keccak256(
            abi.encode(
                TYPE_HASH,
                _hashOrStored($._name, $._hashedName),
                _hashOrStored($._version, $._hashedVersion),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Returns the EIP-712 digest of a struct hash under this proxy's domain.
     * @param structHash The hash of the typed struct.
     * @return The typed data digest.
     */
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    /// @dev Like EIP712Upgradeable, prefers the stored string and falls back to the legacy stored hash.
    function _hashOrStored(string storage value, bytes32 storedHash) private view returns (bytes32) {
        if (bytes(value).length > 0) {
            return keccak256(bytes(value));
        }
        if (storedHash != 0) {
            return storedHash;
        }
        return keccak256("");
    }

    function _getEIP712Storage() private pure returns (EIP712Storage storage $) {
        assembly {
            $.slot := EIP712_STORAGE_LOCATION
        }
    }
}
