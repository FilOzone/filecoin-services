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
import {FVMActor} from "@fvm-solidity/FVMActor.sol";
import {FVMMiner} from "@fvm-solidity/FVMMiner.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {PoRepDeal} from "./PoRepDeal.sol";

contract PoRepPayee {
    using FVMActor for address;
    using FVMMiner for uint64;

    error Unauthorized(address caller);

    uint64 public immutable MINER;

    constructor() {
        MINER = PoRepService(msg.sender).getMiner();
    }

    function owner() public view returns (uint64) {
        return MINER.getOwnerActorId();
    }

    function sudo(address payable, bytes calldata) external payable returns (bytes memory) {
        require(msg.sender.getActorId() == owner(), Unauthorized(msg.sender));
        assembly ("memory-safe") {
            let insize := calldataload(68)
            calldatacopy(0, 100, insize)
            let success := call(gas(), calldataload(4), callvalue(), 0, insize, 0, 0)
            mstore(0, 32)
            mstore(32, returndatasize())
            returndatacopy(64, 0, returndatasize())
            if success { return(0, add(64, returndatasize())) }
            revert(0, add(64, returndatasize()))
        }
    }
}

contract PoRepService {
    using FVMAddress for address;
    using FVMSectorContentChanged for uint256;
    using CalldataUtils for CalldataSlice;

    error ForbiddenMethod(uint64 method);

    FilecoinPayV1 private immutable PAYMENTS;

    constructor(FilecoinPayV1 payments) {
        PAYMENTS = payments;
    }

    function getMiner() external view returns (uint64 payee) {
        assembly ("memory-safe") {
            payee := tload(0)
        }
    }

    function setMiner(uint64 payee) internal {
        assembly ("memory-safe") {
            tstore(0, payee)
        }
    }

    bytes32 constant RECEIVER_INITCODE_HASH = keccak256(type(PoRepPayee).creationCode);

    function getReceiverAddress(uint64 provider) public view returns (address receiver) {
        receiver = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            uint8(0xff), address(this), bytes32(uint256(uint64(provider))), RECEIVER_INITCODE_HASH
                        )
                    )
                )
            )
        );
    }

    function createReceiver(uint64 provider) public returns (address receiver) {
        receiver = getReceiverAddress(provider);
        if (receiver.code.length == 0) {
            setMiner(provider);
            new PoRepPayee{salt: bytes32(uint256(provider))}();
        }
    }

    function createDeal(address client, uint64 provider, uint256 filPerBytePerEpoch) external returns (address deal) {
        address receiver = createReceiver(provider);

        deal = address(new PoRepDeal(address(this), client, provider, receiver, PAYMENTS, filPerBytePerEpoch));
    }

    function handle_filecoin_method(uint64 method, uint64, bytes calldata)
        public
        returns (uint32 exitCode, uint64 returnDataCodec, bytes memory returnData)
    {
        require(method == SECTOR_CONTENT_CHANGED, ForbiddenMethod(method));
        uint64 minerActor = msg.sender.safeActorId();

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
                address deal = piece.payload.toAddress();
                PoRepDeal(deal).pieceAdded(minerActor, cidHash, header.sector, piece.paddedSize);
                FVMSectorContentChanged.accept(ret.sectors[i], j);
            }
        }
        return (0, CBOR_CODEC, FVMSectorContentChanged.encodeReturn(ret));
    }
}
