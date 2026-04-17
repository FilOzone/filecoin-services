// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";

contract PoRepDeal is IValidator {
    address public immutable SERVICE;
    address public immutable CLIENT;
    uint64 public immutable PROVIDER;
    FilecoinPayV1 private immutable PAYMENTS;
    uint256 public immutable RAIL_ID;
    uint256 public immutable FIL_PER_BYTE_PER_EPOCH;
    uint64 private immutable NONCE;

    uint256 faultedCount;

    enum PieceStatus {
        UNAUTHORIZED,
        AUTHORIZED,
        ACTIVE
    }

    // TODO move to child contract
    mapping(bytes32 pieceId => PieceStatus) pieces;

    // TODO move to child contract
    struct SectorStatus {
        uint256 activeSize;
    }

    mapping(uint256 sectorId => SectorStatus) public sectors;
    uint256 public totalActiveSize;

    constructor(
        address service,
        address client,
        uint64 provider,
        FilecoinPayV1 payments,
        uint256 railId,
        uint256 filPerBytePerEpoch,
        uint64 nonce
    ) {
        SERVICE = service;
        CLIENT = client;
        PROVIDER = provider;
        PAYMENTS = payments;
        FIL_PER_BYTE_PER_EPOCH = filPerBytePerEpoch;
        RAIL_ID = railId;
        NONCE = nonce;
    }

    function _onlyClient() internal view {
        require(msg.sender == CLIENT);
    }

    function _onlyService() internal view {
        require(msg.sender == SERVICE);
    }

    modifier onlyClient() {
        _onlyClient();
        _;
    }

    modifier onlyService() {
        _onlyService();
        _;
    }

    // TODO allow provider to addPieces with client authorization
    function addPieces(bytes32[] calldata cidHashes) external onlyClient {
        for (uint256 i = 0; i < cidHashes.length; i++) {
            bytes32 cidHash = cidHashes[i];
            require(pieces[cidHash] == PieceStatus.UNAUTHORIZED);
            pieces[cidHash] = PieceStatus.AUTHORIZED;
        }
    }

    function pieceAdded(uint64 minerId, bytes32 cidHash, uint64 sectorId, uint64 paddedSize)
        external
        onlyService
        returns (uint256 railId, uint256 newRate)
    {
        require(minerId == PROVIDER);

        require(pieces[cidHash] == PieceStatus.AUTHORIZED);
        pieces[cidHash] = PieceStatus.ACTIVE;

        sectors[sectorId].activeSize += paddedSize;
        totalActiveSize += paddedSize;

        return (RAIL_ID, paddedSize * FIL_PER_BYTE_PER_EPOCH);
    }

    /**
     * IValidator
     */
    function validatePayment(
        uint256, // railId
        uint256 proposedAmount, // the epoch up to and including which the rail has already been settled
        uint256, // fromEpoch
        uint256 toEpoch,
        uint256 // rate
    ) external pure returns (ValidationResult memory result) {
        result.modifiedAmount = proposedAmount;
        result.settleUpto = toEpoch;
    }

    function railTerminated(uint256, address terminator, uint256 /*endEpoch*/ ) external view {
        require(msg.sender == address(PAYMENTS));
        require(terminator == SERVICE);
        // TODO cleanup
    }
}
