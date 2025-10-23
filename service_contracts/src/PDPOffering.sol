// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ServiceProviderRegistry} from "./ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "./ServiceProviderRegistryStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice PDP-specific service data
library PDPOffering {
    struct Schema {
        string serviceURL; // HTTP API endpoint
        uint256 minPieceSizeInBytes; // Minimum piece size accepted in bytes
        uint256 maxPieceSizeInBytes; // Maximum piece size accepted in bytes
        bool ipniPiece; // Supports IPNI piece CID indexing
        bool ipniIpfs; // Supports IPNI IPFS CID indexing
        uint256 storagePricePerTibPerDay; // Storage price per TiB per month (in token's smallest unit)
        uint256 minProvingPeriodInEpochs; // Minimum proving period in epochs
        string location; // Geographic location of the service provider
        IERC20 paymentTokenAddress; // Token contract for payment (IERC20(address(0)) for FIL)
    }

    function fromCapabilities(string[] memory keys, bytes[] memory values)
        internal
        pure
        returns (Schema memory schema)
    {
        require(keys.length == values.length, "Keys and values arrays must have same length");
        for (uint256 i = 0; i < keys.length; i++) {
            bytes32 hash = keccak256(bytes(keys[i]));
            if (hash == keccak256("serviceURL")) {
                schema.serviceURL = string(values[i]);
            } else if (hash == keccak256("minPieceSizeInBytes")) {
                schema.minPieceSizeInBytes = abi.decode(values[i], (uint256));
            }
            if (hash == keccak256("maxPieceSizeInBytes")) {
                schema.maxPieceSizeInBytes = abi.decode(values[i], (uint256));
            }
            if (hash == keccak256("ipniPiece")) {
                schema.ipniPiece = abi.decode(values[i], (bool));
            }
            if (hash == keccak256("ipniIpfs")) {
                schema.ipniIpfs = abi.decode(values[i], (bool));
            }
            if (hash == keccak256("storagePricePerTibPerDay")) {
                schema.storagePricePerTibPerDay = abi.decode(values[i], (uint256));
            }
            if (hash == keccak256("minProvingPeriodInEpochs")) {
                schema.minProvingPeriodInEpochs = abi.decode(values[i], (uint256));
            }
            if (hash == keccak256("location")) {
                schema.location = string(values[i]);
            }
            if (hash == keccak256("paymentTokenAddress")) {
                schema.paymentTokenAddress = abi.decode(values[i], (IERC20));
            }
        }
        return schema;
    }

    function toCapabilities(Schema memory schema, uint256 extraSize)
        internal
        pure
        returns (string[] memory keys, bytes[] memory values)
    {
        keys = new string[](9 + extraSize);
        values = new bytes[](9 + extraSize);
        keys[extraSize] = "serviceURL";
        values[extraSize] = bytes(schema.serviceURL);
        keys[extraSize + 1] = "minPieceSizeInBytes";
        values[extraSize + 1] = abi.encode(schema.minPieceSizeInBytes);
        keys[extraSize + 2] = "maxPieceSizeInBytes";
        values[extraSize + 2] = abi.encode(schema.maxPieceSizeInBytes);
        keys[extraSize + 3] = "ipniPiece";
        values[extraSize + 3] = abi.encode(schema.ipniPiece);
        keys[extraSize + 4] = "ipniIpfs";
        values[extraSize + 4] = abi.encode(schema.ipniIpfs);
        keys[extraSize + 5] = "storagePricePerTibPerDay";
        values[extraSize + 5] = abi.encode(schema.storagePricePerTibPerDay);
        keys[extraSize + 6] = "minProvingPeriodInEpochs";
        values[extraSize + 6] = abi.encode(schema.minProvingPeriodInEpochs);
        keys[extraSize + 7] = "location";
        values[extraSize + 7] = bytes(schema.location);
        keys[extraSize + 8] = "paymentTokenAddress";
        values[extraSize + 8] = abi.encode(schema.paymentTokenAddress);
    }

    function toCapabilities(Schema memory schema) internal pure returns (string[] memory keys, bytes[] memory values) {
        return toCapabilities(schema, 0);
    }

    function getPDPService(ServiceProviderRegistry registry, uint256 providerId)
        internal
        view
        returns (Schema memory schema, string[] memory keys, bool isActive)
    {
        (keys, isActive) = registry.getProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        (, bytes[] memory values) =
            registry.getProductCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, keys);
        schema = fromCapabilities(keys, values);
    }
}
