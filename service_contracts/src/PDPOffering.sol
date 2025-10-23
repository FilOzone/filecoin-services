// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice PDP-specific service data
library PDPOffering {
    struct Schema {
        string serviceURL; // HTTP API endpoint
        uint256 minPieceSizeInBytes; // Minimum piece size accepted in bytes
        uint256 maxPieceSizeInBytes; // Maximum piece size accepted in bytes
        bool ipniPiece; // Supports IPNI piece CID indexing
        bool ipniIpfs; // Supports IPNI IPFS CID indexing
        uint256 storagePricePerTibPerMonth; // Storage price per TiB per month (in token's smallest unit)
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
            if (hash == keccak256("storagePricePerTibPerMonth")) {
                schema.storagePricePerTibPerMonth = abi.decode(values[i], (uint256));
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

    function toCapabilities(Schema memory schema) internal pure returns (string[] memory keys, bytes[] memory values) {
        keys = new string[](9);
        values = new bytes[](9);
        keys[0] = "serviceURL";
        values[0] = bytes(schema.serviceURL);
        keys[1] = "minPieceSizeInBytes";
        values[1] = abi.encode(schema.minPieceSizeInBytes);
        keys[2] = "maxPieceSizeInBytes";
        values[2] = abi.encode(schema.maxPieceSizeInBytes);
        keys[3] = "ipniPiece";
        values[3] = abi.encode(schema.ipniPiece);
        keys[4] = "ipniIpfs";
        values[4] = abi.encode(schema.ipniIpfs);
        keys[5] = "storagePricePerTibPerMonth";
        values[5] = abi.encode(schema.storagePricePerTibPerMonth);
        keys[6] = "minProvingPeriodInEpochs";
        values[6] = abi.encode(schema.minProvingPeriodInEpochs);
        keys[7] = "location";
        values[7] = bytes(schema.location);
        keys[8] = "paymentTokenAddress";
        values[8] = abi.encode(schema.paymentTokenAddress);
    }
}
