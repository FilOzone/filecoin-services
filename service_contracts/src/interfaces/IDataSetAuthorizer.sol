// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

/// @title IDataSetAuthorizer
/// @notice Optional per-data-set write ACL. When a payer attaches an authorizer, FWSS
///         delegates the entire authorization decision for that data set to it.
/// @dev A revert (or out-of-gas) means "not authorized": the operation reverts.
interface IDataSetAuthorizer {
    /// @param dataSetId The data set being operated on.
    /// @param payer The data set's payer (the on-chain owner of the rails).
    /// @param operation The operation type hash (e.g. SignatureVerificationLib.ADD_PIECES_TYPEHASH).
    /// @param digest The EIP-712 digest signed for the operation.
    /// @param signature The raw signature over `digest`; the authorizer recovers the
    ///        signer itself, on whatever curve it supports.
    /// @param operationData The ABI-encoded raw operation payload forwarded by FWSS, carrying all
    ///        operation-specific data (e.g. piece metadata) so the authorizer can gate on its
    ///        contents — for example enforcing metadata- or path-based ACLs. Empty for operations
    ///        whose data is fully described by the other parameters (e.g. terminate).
    /// @return authorized True if the operation is authorized on `dataSetId`.
    function isAuthorized(
        uint256 dataSetId,
        address payer,
        bytes32 operation,
        bytes32 digest,
        bytes calldata signature,
        bytes calldata operationData
    ) external view returns (bool authorized);
}
