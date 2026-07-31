// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

/// @title IFilecoinServiceMetadata
/// @notice Minimal service identity interface for Filecoin Onchain Cloud service contracts.
interface IFilecoinServiceMetadata {
    /// @notice Short, human-readable service name.
    function name() external view returns (string memory);

    /// @notice Concise, human-readable service description.
    /// @dev Implementations must limit the UTF-8 encoded value to 256 bytes.
    ///      Consumers should treat the value as untrusted display-only text.
    function description() external view returns (string memory);

    /// @notice Optional URL for service documentation, specifications, or source code.
    /// @dev Implementations must limit the UTF-8 encoded value to 256 bytes and
    ///      return an empty string when no homepage is provided.
    function homepage() external view returns (string memory);
}
