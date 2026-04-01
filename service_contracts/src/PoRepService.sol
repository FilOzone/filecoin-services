// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

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

contract PoRepService is IValidator {
    using FVMAddress for address;
    using FVMSectorContentChanged for uint256;
    using FVMSectorContentChanged for CalldataSlice;

    error ForbiddenMethod(uint64 method);

    FilecoinPayV1 private immutable PAYMENTS;

    constructor(FilecoinPayV1 payments) {
        PAYMENTS = payments;
    }

    /**
     * Filecoin Actor **
     */
    function handle_filecoin_method(uint64 method, uint64, /*codec*/ bytes calldata)
        public
        view
        returns (uint32 exitCode, uint64 returnDataCodec, bytes memory returnData)
    {
        require(method == SECTOR_CONTENT_CHANGED, ForbiddenMethod(method));
        uint64 minerActor = msg.sender.safeActorId();
        // TODO check miner is miner

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
                // Materialise and validate: CID prefix was already stripped, so digest is 36 bytes
                bytes memory digest = piece.digest.loadSlice();
                require(digest.length == 36);
                // Decode and validate the allocation ID
                uint64 allocationId = abi.decode(piece.payload.loadSlice(), (uint64));
                require(allocationId > 0);
                FVMSectorContentChanged.accept(ret.sectors[i], j);
            }
        }
        return (0, CBOR_CODEC, FVMSectorContentChanged.encodeReturn(ret));
    }

    /**
     * IValidator **
     */
    function validatePayment(
        uint256,
        /*railId*/
        uint256 proposedAmount,
        // the epoch up to and including which the rail has already been settled
        uint256,
        /*fromEpoch*/
        // the epoch up to and including which validation is requested; payment will be validated for (toEpoch - fromEpoch) epochs
        uint256 toEpoch,
        uint256 /*rate*/
    ) external pure returns (ValidationResult memory result) {
        // TODO check terminated
        result.modifiedAmount = proposedAmount;
        result.settleUpto = toEpoch;
    }

    function railTerminated(uint256, /*railId*/ address, /*terminator*/ uint256 /*endEpoch*/ ) external view {
        require(msg.sender == address(PAYMENTS));
        // TODO cleanup
    }
}
