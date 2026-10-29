// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {StorageTerms} from "../../src/lib/StorageTerms.sol";

/// @dev The storage terms surface of the FWSS proxy, until the generated interface carries it.
interface IFWSSStorageTerms {
    event StorageTermsRegistered(
        bytes32 indexed storageTermsId, address token, uint8 tokenDecimals, uint96 pricePerTiBPerMonth, bytes32 salt
    );
    event StorageTermsDisabled(bytes32 indexed storageTermsId);
    event DataSetStorageTermsSelected(uint256 indexed dataSetId, bytes32 indexed storageTermsId);

    function registerStorageTerms(StorageTerms calldata terms) external returns (bytes32);
    function disableStorageTerms(bytes32 storageTermsId) external;
    function getStorageTerms(bytes32 storageTermsId) external view returns (StorageTerms memory terms, bool enabled);
    function getStorageTermsId(StorageTerms calldata terms) external pure returns (bytes32);
    function getDataSetStorageTermsId(uint256 dataSetId) external view returns (bytes32);
    function legacyStorageTermsId() external view returns (bytes32);
}
