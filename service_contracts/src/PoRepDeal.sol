// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";

interface IPoRepService {
    function updateLockups(uint64 nonce, uint256 railId, uint256 payment, uint256 remaining) external;
}

contract PoRepDeal is IValidator {
    address public immutable SERVICE;
    address public immutable CLIENT;
    uint64 public immutable PROVIDER;
    FilecoinPayV1 private immutable PAYMENTS;
    uint256 public immutable RAIL_ID;
    uint256 public immutable FIL_PER_BYTE_PER_EPOCH;
    uint64 private immutable NONCE;

    struct Info {
        uint64 settledEpoch;
        uint64 endEpoch;
        uint32 faultedCount;
        uint96 totalActiveSize;
    }

    Info public info;

    enum PieceStatus {
        UNAUTHORIZED,
        AUTHORIZED,
        ACTIVE
    }

    // TODO move to child contract
    mapping(bytes32 pieceId => PieceStatus) pieces;

    // TODO move to child contract
    struct SectorStatus {
        uint96 activeSize;
    }

    mapping(uint256 sectorId => SectorStatus) public sectors;

    constructor(
        address service,
        address client,
        uint64 provider,
        FilecoinPayV1 payments,
        uint256 railId,
        uint256 filPerBytePerEpoch,
        uint64 dealEndEpoch,
        uint64 nonce
    ) {
        SERVICE = service;
        CLIENT = client;
        PROVIDER = provider;
        PAYMENTS = payments;
        FIL_PER_BYTE_PER_EPOCH = filPerBytePerEpoch;
        RAIL_ID = railId;
        NONCE = nonce;
        info.endEpoch = dealEndEpoch;
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

    function pieceAdded(
        uint64 minerId,
        bytes32 cidHash,
        uint64 sectorId,
        uint64 minimumCommitmentEpoch,
        uint64 paddedSize
    ) external onlyService {
        require(minerId == PROVIDER);

        // this also enforces block.number < info.endEpoch because minimum commitment is 180 days
        require(minimumCommitmentEpoch >= info.endEpoch);

        require(pieces[cidHash] == PieceStatus.AUTHORIZED);
        pieces[cidHash] = PieceStatus.ACTIVE;

        sectors[sectorId].activeSize += paddedSize;

        // TODO only amortize once per SectorContentChanged notification
        uint256 prevSize = info.totalActiveSize;
        uint256 newSize = prevSize + paddedSize;
        uint256 prevRate = prevSize * FIL_PER_BYTE_PER_EPOCH;
        uint256 newRate = newSize * FIL_PER_BYTE_PER_EPOCH;
        amortize((block.number - info.settledEpoch) * prevRate, (info.endEpoch - block.number) * newRate);
        info.settledEpoch = uint64(block.number);
        info.totalActiveSize = uint96(newSize);
    }

    function extend(uint64 epochs) external onlyClient {
        require(block.number < info.endEpoch);
        uint64 newEndEpoch = info.endEpoch + epochs;
        uint256 rate = info.totalActiveSize * FIL_PER_BYTE_PER_EPOCH;
        amortize((block.number - info.settledEpoch) * rate, (newEndEpoch - block.number) * rate);
        info.endEpoch = newEndEpoch;
        info.settledEpoch = uint64(block.number);
    }

    function amortize(uint256 payment, uint256 remaining) internal {
        IPoRepService(SERVICE).updateLockups(NONCE, RAIL_ID, payment, remaining);
    }

    function amortize() external {
        uint256 rate = info.totalActiveSize * FIL_PER_BYTE_PER_EPOCH;
        if (block.number <= info.endEpoch) {
            amortize((block.number - info.settledEpoch) * rate, (info.endEpoch - block.number) * rate);
            info.settledEpoch = uint64(block.number);
        } else {
            amortize((info.endEpoch - info.settledEpoch) * rate, 0);
            info.settledEpoch = info.endEpoch;
        }
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
