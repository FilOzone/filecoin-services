// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {FVMSector, SectorStatus, NO_DEADLINE, NO_PARTITION} from "@fvm-solidity/FVMSector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPoRepService {
    function updateLockups(uint64 nonce, uint256 railId, uint256 payment, uint256 remaining) external;
}

contract PoRepDeal is IValidator {
    address public immutable SERVICE;
    address public immutable CLIENT;
    uint64 public immutable PROVIDER;
    FilecoinPayV1 private immutable PAYMENTS;
    uint256 public immutable RAIL_ID;
    IERC20 public immutable TOKEN;
    uint256 public immutable TOKENS_PER_BYTE_PER_EPOCH;
    uint64 private immutable NONCE;

    struct Info {
        uint64 settledEpoch;
        uint64 endEpoch;
        uint32 faultedSectorCount;
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
    struct SectorInfo {
        uint96 dealSize;
        uint8 failed;
    }

    mapping(uint256 sectorId => SectorInfo) public sectors;

    constructor(
        address service,
        address client,
        uint64 provider,
        FilecoinPayV1 payments,
        uint256 railId,
        IERC20 token,
        uint256 tokensPerBytePerEpoch,
        uint64 dealEndEpoch,
        uint64 nonce
    ) {
        SERVICE = service;
        CLIENT = client;
        PROVIDER = provider;
        PAYMENTS = payments;
        TOKEN = token;
        TOKENS_PER_BYTE_PER_EPOCH = tokensPerBytePerEpoch;
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

        sectors[sectorId].dealSize += paddedSize;

        // FIXME check if already terminated
        // TODO only amortize once per SectorContentChanged notification
        uint256 prevSize = info.totalActiveSize;
        uint256 newSize = prevSize + paddedSize;
        uint256 prevRate = info.faultedSectorCount > 0 ? 0 : prevSize * TOKENS_PER_BYTE_PER_EPOCH;
        uint256 newRate = newSize * TOKENS_PER_BYTE_PER_EPOCH;
        amortize((block.number - info.settledEpoch) * prevRate, (info.endEpoch - block.number) * newRate);
        info.settledEpoch = uint64(block.number);
        info.totalActiveSize = uint96(newSize);
    }

    function extend(uint64 epochs) external onlyClient {
        require(block.number < info.endEpoch);
        require(info.faultedSectorCount == 0);
        // FIXME prevent if terminated
        uint64 newEndEpoch = info.endEpoch + epochs;
        uint256 rate = info.totalActiveSize * TOKENS_PER_BYTE_PER_EPOCH;
        amortize((block.number - info.settledEpoch) * rate, (newEndEpoch - block.number) * rate);
        info.endEpoch = newEndEpoch;
        info.settledEpoch = uint64(block.number);
    }

    function amortize(uint256 payment, uint256 remaining) internal {
        IPoRepService(SERVICE).updateLockups(NONCE, RAIL_ID, payment, remaining);
    }

    function amortize() external {
        if (info.faultedSectorCount > 0) {
            info.settledEpoch = uint64(block.number);
            return;
        }
        amortizeHealthy();
    }

    function amortizeHealthy() internal {
        uint256 rate = info.totalActiveSize * TOKENS_PER_BYTE_PER_EPOCH;
        if (block.number <= info.endEpoch) {
            amortize((block.number - info.settledEpoch) * rate, (info.endEpoch - block.number) * rate);
            info.settledEpoch = uint64(block.number);
        } else {
            amortize((info.endEpoch - info.settledEpoch) * rate, 0);
            info.settledEpoch = info.endEpoch;
        }
    }

    function payoutBounty(address recipient, uint256 bounty) internal {
        PAYMENTS.withdrawTo(TOKEN, recipient, bounty);
    }

    function onBadSector(uint256 sectorId, address recipient, uint256 bounty) internal {
        sectors[sectorId].failed = 1;
        if (info.faultedSectorCount == 0) {
            amortizeHealthy();
            info.faultedSectorCount = 1;
            payoutBounty(recipient, bounty);
        } else {
            info.faultedSectorCount++;
        }
    }

    function onSectorRecovered(uint256 sectorId) internal {
        sectors[sectorId].failed = 0;

        if (--info.faultedSectorCount == 0) {
            info.settledEpoch = uint64(block.number);
        }
    }

    function sectorExpired(uint64 sectorId, address recipient, uint256 bounty) external {
        require(block.number < info.endEpoch);
        require(sectors[sectorId].dealSize > 0);
        require(sectors[sectorId].failed == 0);
        require(FVMSector.validateSectorStatus(PROVIDER, sectorId, SectorStatus.Dead, NO_DEADLINE, NO_PARTITION));

        // FIXME this is unrecoverable so should terminate instead
        onBadSector(sectorId, recipient, bounty);
    }

    function sectorFaulty(uint64 sectorId, int64 deadline, int64 partition, address recipient, uint256 bounty)
        external
    {
        require(block.number < info.endEpoch);
        require(sectors[sectorId].dealSize > 0);
        require(sectors[sectorId].failed == 0);
        require(FVMSector.validateSectorStatus(PROVIDER, sectorId, SectorStatus.Faulty, deadline, partition));

        onBadSector(sectorId, recipient, bounty);
    }

    // SPs should call this after DeclareFaultsRecovered
    function sectorRecovered(uint64 sectorId, int64 deadline, int64 partition) external {
        require(sectors[sectorId].failed == 1);
        require(sectors[sectorId].dealSize > 0);
        require(FVMSector.validateSectorStatus(PROVIDER, sectorId, SectorStatus.Active, deadline, partition));

        onSectorRecovered(sectorId);
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
