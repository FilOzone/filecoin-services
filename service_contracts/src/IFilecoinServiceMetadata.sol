// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

/// @title IFilecoinServiceMetadata
/// @notice Minimal service identity interface for Filecoin Onchain Cloud service contracts.
interface IFilecoinServiceMetadata {
    /// @notice Human-readable service name.
    function name() external view returns (string memory);

    /// @notice Human-readable service description.
    function description() external view returns (string memory);
}
