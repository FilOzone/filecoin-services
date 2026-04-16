// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {CalldataUtils, CalldataSlice} from "@fvm-solidity/CalldataUtils.sol";
import {FVMAddress} from "@fvm-solidity/FVMAddress.sol";
import {CBOR_CODEC} from "@fvm-solidity/FVMCodec.sol";
import {SECTOR_CONTENT_CHANGED} from "@fvm-solidity/FVMMethod.sol";
import {
    CalldataSlice,
    FVMSectorContentChanged,
    PieceChangeIter,
    SectorChangesHeader,
    SectorContentChangedReturn,
    SectorReturn
} from "@fvm-solidity/FVMSectorContentChanged.sol";
import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

IERC20 constant NATIVE_TOKEN = IERC20(address(0));

contract PoRepDeal is IValidator {
    using FVMAddress for address;
    using FVMSectorContentChanged for uint256;
    using CalldataUtils for CalldataSlice;

    error ForbiddenMethod(uint64 method);

    address public immutable SERVICE;
    address public immutable CLIENT;
    uint64 public immutable PROVIDER;
    FilecoinPayV1 private immutable PAYMENTS;
    uint256 RAIL_ID;

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

    constructor(address service, address client, uint64 provider, address receiver, FilecoinPayV1 payments) {
        SERVICE = service;
        CLIENT = client;
        PROVIDER = provider;
        PAYMENTS = payments;
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

    function pieceAdded(bytes32 cidHash, uint64 sectorId, uint64 paddedSize) internal {
        // TODO expiry
        require(pieces[cidHash] == PieceStatus.AUTHORIZED);
        pieces[cidHash] = PieceStatus.ACTIVE;
        sectors[sectorId].activeSize += paddedSize;
        totalActiveSize += paddedSize;
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

    function handle_filecoin_method(uint64 method, uint64, bytes calldata)
        public
        returns (uint32 exitCode, uint64 returnDataCodec, bytes memory returnData)
    {
        require(method == SECTOR_CONTENT_CHANGED, ForbiddenMethod(method));
        uint64 minerActor = msg.sender.safeActorId();
        require(minerActor == PROVIDER);

        uint256 numSectors;
        uint256 iter;
        (numSectors, iter) = FVMSectorContentChanged.readParamsHeader();

        SectorContentChangedReturn memory ret;
        ret.sectors = new SectorReturn[](numSectors);
        SectorChangesHeader memory header;
        PieceChangeIter memory piece;
        for (uint256 i = 0; i < numSectors; i++) {
            iter = iter.readSectorHeader(header);
            FVMSectorContentChanged.initSectorReturn(ret.sectors[i], header.numPieces);
            for (uint256 j = 0; j < header.numPieces; j++) {
                iter = iter.readPiece(piece);
                bytes32 cidHash = piece.digest.keccak();
                pieceAdded(cidHash, header.sector, piece.paddedSize);
                // Decode and validate the allocation ID
                address deal = abi.decode(piece.payload.load(), (address));
                // TODO deal
                FVMSectorContentChanged.accept(ret.sectors[i], j);
            }
        }
        return (0, CBOR_CODEC, FVMSectorContentChanged.encodeReturn(ret));
    }
}
