// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

IERC20 constant NATIVE_TOKEN = IERC20(address(0));

contract PoRepDeal is IValidator {
    address public immutable SERVICE;
    address public immutable CLIENT;
    uint64 public immutable PROVIDER;
    FilecoinPayV1 private immutable PAYMENTS;
    uint256 public immutable RAIL_ID;
    uint256 public immutable FIL_PER_BYTE_PER_EPOCH;

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
        address receiver,
        FilecoinPayV1 payments,
        uint256 filPerByte
    ) {
        SERVICE = service;
        CLIENT = client;
        PROVIDER = provider;
        PAYMENTS = payments;
        FIL_PER_BYTE_PER_EPOCH = filPerByte;
        RAIL_ID = PAYMENTS.createRail(NATIVE_TOKEN, client, receiver, address(this), 0, address(0));
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

    function pieceAdded(uint64 minerId, bytes32 cidHash, uint64 sectorId, uint64 paddedSize) external onlyService {
        require(minerId == PROVIDER);

        require(pieces[cidHash] == PieceStatus.AUTHORIZED);
        pieces[cidHash] = PieceStatus.ACTIVE;

        sectors[sectorId].activeSize += paddedSize;
        totalActiveSize += paddedSize;

        PAYMENTS.modifyRailPayment(RAIL_ID, paddedSize * FIL_PER_BYTE_PER_EPOCH, 0);
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

    function railTerminated(uint256, /*railId*/ address, /*terminator*/ uint256 /*endEpoch*/ ) external view {
        require(msg.sender == address(PAYMENTS));
        // TODO cleanup
    }
}
