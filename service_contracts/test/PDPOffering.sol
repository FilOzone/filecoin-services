// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BigEndian} from "../src/lib/BigEndian.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
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
                schema.minPieceSizeInBytes = BigEndian.decode(values[i]);
            } else if (hash == keccak256("maxPieceSizeInBytes")) {
                schema.maxPieceSizeInBytes = BigEndian.decode(values[i]);
            } else if (hash == keccak256("ipniPiece")) {
                schema.ipniPiece = BigEndian.decode(values[i]) > 0;
            } else if (hash == keccak256("ipniIpfs")) {
                schema.ipniIpfs = BigEndian.decode(values[i]) > 0;
            } else if (hash == keccak256("storagePricePerTibPerDay")) {
                schema.storagePricePerTibPerDay = BigEndian.decode(values[i]);
            } else if (hash == keccak256("minProvingPeriodInEpochs")) {
                schema.minProvingPeriodInEpochs = BigEndian.decode(values[i]);
            } else if (hash == keccak256("location")) {
                schema.location = string(values[i]);
            } else if (hash == keccak256("paymentTokenAddress")) {
                schema.paymentTokenAddress = IERC20(address(uint160(BigEndian.decode(values[i]))));
            }
        }
        return schema;
    }

    function toCapabilities(Schema memory schema, uint256 extraSize)
        internal
        pure
        returns (string[] memory keys, bytes[] memory values)
    {
        uint256 normalSize = 7 + (schema.ipniPiece ? 1 : 0) + (schema.ipniIpfs ? 1 : 0);
        keys = new string[](normalSize + extraSize);
        values = new bytes[](normalSize + extraSize);
        keys[extraSize] = "serviceURL";
        values[extraSize] = bytes(schema.serviceURL);
        keys[extraSize + 1] = "minPieceSizeInBytes";
        values[extraSize + 1] = BigEndian.encode(schema.minPieceSizeInBytes);
        keys[extraSize + 2] = "maxPieceSizeInBytes";
        values[extraSize + 2] = BigEndian.encode(schema.maxPieceSizeInBytes);
        keys[extraSize + 3] = "storagePricePerTibPerDay";
        values[extraSize + 3] = BigEndian.encode(schema.storagePricePerTibPerDay);
        keys[extraSize + 4] = "minProvingPeriodInEpochs";
        values[extraSize + 4] = BigEndian.encode(schema.minProvingPeriodInEpochs);
        keys[extraSize + 5] = "location";
        values[extraSize + 5] = bytes(schema.location);
        keys[extraSize + 6] = "paymentTokenAddress";
        values[extraSize + 6] = abi.encodePacked(schema.paymentTokenAddress);
        if (schema.ipniPiece) {
            keys[extraSize + 7] = "ipniPiece";
            values[extraSize + 7] = BigEndian.encode(1);
        }
        if (schema.ipniIpfs) {
            keys[keys.length - 1] = "ipniIpfs";
            values[keys.length - 1] = BigEndian.encode(1);
        }
    }

    function toCapabilities(Schema memory schema) internal pure returns (string[] memory keys, bytes[] memory values) {
        return toCapabilities(schema, 0);
    }

    function getPDPService(ServiceProviderRegistry registry, uint256 providerId)
        internal
        view
        returns (Schema memory schema, string[] memory keys, bool isActive)
    {
        ServiceProviderRegistryStorage.ProviderWithProduct memory providerWithProduct =
            registry.getProviderWithProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        keys = providerWithProduct.product.capabilityKeys;
        isActive = providerWithProduct.product.isActive;
        schema = fromCapabilities(keys, providerWithProduct.productCapabilityValues);
    }
}
