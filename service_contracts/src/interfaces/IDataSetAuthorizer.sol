// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

/// @title IDataSetAuthorizer
/// @notice Optional per-data-set write ACL.
/// @dev FWSS calls this with a fixed gas budget. Revert or out-of-gas means "not authorized".
interface IDataSetAuthorizer {
    /// @param dataSetId The data set being operated on.
    /// @param signer The secp256k1 signer recovered from the operation signature.
    /// @param operation The operation type hash, e.g. FWSS.ADD_PIECES_OPERATION().
    /// @param digest The EIP-712 digest signed for the operation.
    /// @param signature The raw signature over `digest`.
    /// @param metadata ABI-encoded signed operation payload forwarded by FWSS.
    /// @return True if `signer` is allowed to perform `operation` on `dataSetId`.
    function isAuthorized(
        uint256 dataSetId,
        address signer,
        bytes32 operation,
        bytes32 digest,
        bytes calldata signature,
        bytes calldata metadata
    ) external view returns (bool);
}
