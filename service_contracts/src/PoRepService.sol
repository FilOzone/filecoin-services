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
import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibRLP} from "@solady/utils/LibRLP.sol";
import {LibClone} from "@solady/utils/LibClone.sol";
import {IPoRepService, PoRepDeal} from "./PoRepDeal.sol";

error Unauthorized(address caller);

contract PoRepPayee {
    using FVMActor for address;
    using FVMMiner for uint64;

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

contract PoRepService is IPoRepService, IValidator {
    using FVMAddress for address;
    using FVMSectorContentChanged for uint256;
    using CalldataUtils for CalldataSlice;
    using LibClone for bytes32;
    using LibRLP for address;

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
        receiver = RECEIVER_INITCODE_HASH.predictDeterministicAddress(bytes32(uint256(provider)), address(this));
    }

    uint64 private nonce;

    function authenticateDeal(uint64 nonce) internal view {
        require(msg.sender == address(this).computeAddress(nonce));
    }

    function createReceiver(uint64 provider) public returns (address receiver) {
        receiver = getReceiverAddress(provider);
        if (receiver.code.length == 0) {
            ++nonce;
            setMiner(provider);
            new PoRepPayee{salt: bytes32(uint256(provider))}();
        }
    }

    function createDeal(
        address client,
        uint64 provider,
        IERC20 token,
        uint256 tokensPerBytePerEpoch,
        uint64 dealEndEpoch,
        uint256 insuranceBps
    ) external returns (address deal) {
        address receiver = createReceiver(provider);
        ++nonce;
        deal = address(this).computeAddress(nonce);
        uint256 railId = PAYMENTS.createRail(token, client, receiver, address(this), insuranceBps, deal);
        new PoRepDeal(
            address(this), client, provider, PAYMENTS, railId, token, tokensPerBytePerEpoch, dealEndEpoch, nonce
        );
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
            // require(header.minimumCommitmentEpoch > 0);
            FVMSectorContentChanged.initSectorReturn(ret.sectors[i], header.numPieces);
            for (uint256 j = 0; j < header.numPieces; j++) {
                iter = iter.readPiece(piece);
                bytes32 cidHash = piece.digest.keccak();
                uint64 nonce = piece.payload.toUint64();
                address deal = address(this).computeAddress(nonce);
                PoRepDeal(deal).pieceAdded(
                    minerActor, cidHash, header.sector, uint64(header.minimumCommitmentEpoch), piece.paddedSize
                );
                //PAYMENTS.modifyRailPayment(railId, 0, payment);
                //PAYMENTS.modifyRailLockup(railId, 0, remaining);
                FVMSectorContentChanged.accept(ret.sectors[i], j);
            }
        }
        return (0, CBOR_CODEC, FVMSectorContentChanged.encodeReturn(ret));
    }

    function updateLockups(uint64 nonce, uint256 railId, uint256 payment, uint256 remaining) external {
        authenticateDeal(nonce);

        if (payment > 0) {
            PAYMENTS.modifyRailPayment(railId, 0, payment);
        }
        PAYMENTS.modifyRailLockup(railId, 0, remaining);
    }

    function terminate(uint64 nonce, uint256 railId, uint64 provider, address receiver) external {
        authenticateDeal(nonce);
        if (provider > 0) {
            require(getReceiverAddress(provider) == receiver, Unauthorized(receiver));
        }
        PAYMENTS.terminateRail(railId);
        PAYMENTS.settleRail(railId, block.number);
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
        require(terminator == address(this));
    }
}
