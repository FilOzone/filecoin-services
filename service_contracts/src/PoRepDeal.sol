// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {FVMSector, SectorStatus} from "@fvm-solidity/FVMSector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPoRepService {
    function updateLockups(uint64 nonce, uint256 railId, uint256 payment, uint256 remaining) external;
    function terminate(uint64 nonce, uint256 railId, uint64 provider, address sender) external;
}

contract PoRepDeal {
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

    error Unauthorized();
    error PieceAlreadyAuthorized(bytes32 pieceDigest);
    error WrongProvider(uint64 minerId);
    error CommitmentTooShort(uint64 minimumCommitmentEpoch, uint64 endEpoch);
    error PieceNotAuthorized(bytes32 pieceDigest);
    error DealExpired();
    error DealFaulted();
    error DealNotExpired();
    error SectorNotInDeal(uint64 sectorId);
    error SectorAlreadyFailed(uint64 sectorId);
    error SectorNotFailed(uint64 sectorId);
    error SectorNotFaulty(uint64 sectorId);
    error SectorNotActive(uint64 sectorId);

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
        require(msg.sender == CLIENT, Unauthorized());
    }

    function _onlyService() internal view {
        require(msg.sender == SERVICE, Unauthorized());
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
    function addPieces(bytes32[] calldata pieceDigests) external onlyClient {
        for (uint256 i = 0; i < pieceDigests.length; i++) {
            bytes32 pieceDigest = pieceDigests[i];
            require(pieces[pieceDigest] == PieceStatus.UNAUTHORIZED, PieceAlreadyAuthorized(pieceDigest));
            pieces[pieceDigest] = PieceStatus.AUTHORIZED;
        }
    }

    function pieceAdded(
        uint64 minerId,
        bytes32 pieceDigest,
        uint64 sectorId,
        uint64 minimumCommitmentEpoch,
        uint64 paddedSize
    ) external onlyService {
        require(minerId == PROVIDER, WrongProvider(minerId));

        // this also enforces block.number < info.endEpoch because minimum commitment is 180 days
        require(minimumCommitmentEpoch >= info.endEpoch, CommitmentTooShort(minimumCommitmentEpoch, info.endEpoch));

        require(pieces[pieceDigest] == PieceStatus.AUTHORIZED, PieceNotAuthorized(pieceDigest));
        pieces[pieceDigest] = PieceStatus.ACTIVE;

        sectors[sectorId].dealSize += paddedSize;

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
        require(block.number < info.endEpoch, DealExpired());
        require(info.faultedSectorCount == 0, DealFaulted());
        uint64 newEndEpoch = info.endEpoch + epochs;
        uint256 rate = info.totalActiveSize * TOKENS_PER_BYTE_PER_EPOCH;
        amortize((block.number - info.settledEpoch) * rate, (newEndEpoch - block.number) * rate);
        info.endEpoch = newEndEpoch;
        info.settledEpoch = uint64(block.number);
    }

    function amortize(uint256 payment, uint256 remaining) internal {
        IPoRepService(SERVICE).updateLockups(NONCE, RAIL_ID, payment, remaining);
    }

    function amortize() public {
        if (info.faultedSectorCount == 0) {
            amortizeHealthy();
            return;
        }
        info.settledEpoch = uint64(block.number);
    }

    function amortizeHealthy() internal {
        uint256 rate = info.totalActiveSize * TOKENS_PER_BYTE_PER_EPOCH;
        if (block.number < info.endEpoch) {
            // live
            amortize((block.number - info.settledEpoch) * rate, (info.endEpoch - block.number) * rate);
        } else {
            // expired
            amortize((info.endEpoch - info.settledEpoch) * rate, 0);
        }
        info.settledEpoch = uint64(block.number);
    }

    function getInsuranceFunds() internal view returns (uint256 funds) {
        (funds,,,) = PAYMENTS.accounts(TOKEN, address(this));
    }

    function payoutBounty(address recipient, uint256 bounty) internal {
        if (bounty > 0) {
            PAYMENTS.withdrawTo(TOKEN, recipient, bounty);
        }
    }

    function onBadSector(uint256 sectorId, address recipient) internal {
        sectors[sectorId].failed = 1;
        if (info.faultedSectorCount == 0) {
            amortizeHealthy();
            info.faultedSectorCount = 1;
            payoutBounty(recipient, getInsuranceFunds() / 2);
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

    // Pass NO_DEADLINE and NO_PARTITION once the sector has been compacted via CompactPartitions.
    function sectorExpired(uint64 sectorId, int64 deadline, int64 partition, address recipient) external {
        require(block.number < info.endEpoch, DealExpired());
        require(sectors[sectorId].dealSize > 0, SectorNotInDeal(sectorId));
        require(FVMSector.validateSectorStatus(PROVIDER, sectorId, SectorStatus.Dead, deadline, partition));

        // this is unrecoverable, so terminate
        info.endEpoch = uint64(block.number);
        amortize();
        terminate(recipient, 0, address(0));
    }

    function sectorFaulty(uint64 sectorId, int64 deadline, int64 partition, address recipient) external {
        require(block.number < info.endEpoch, DealExpired());
        require(sectors[sectorId].dealSize > 0, SectorNotInDeal(sectorId));
        require(sectors[sectorId].failed == 0, SectorAlreadyFailed(sectorId));
        require(
            FVMSector.validateSectorStatus(PROVIDER, sectorId, SectorStatus.Faulty, deadline, partition),
            SectorNotFaulty(sectorId)
        );

        onBadSector(sectorId, recipient);
    }

    // SPs should call this after DeclareFaultsRecovered and a successful Window PoSt
    function sectorRecovered(uint64 sectorId, int64 deadline, int64 partition) external {
        require(sectors[sectorId].failed == 1, SectorNotFailed(sectorId));
        require(sectors[sectorId].dealSize > 0, SectorNotInDeal(sectorId));
        require(
            FVMSector.validateSectorStatus(PROVIDER, sectorId, SectorStatus.Active, deadline, partition),
            SectorNotActive(sectorId)
        );

        onSectorRecovered(sectorId);
    }

    function terminate(address recipient, uint64 provider, address receiver) internal {
        // if termination is caused by a dead sector, the keeper gets the insurance
        // otherwise, the insurance is paid to the order of the PROVIDER
        IPoRepService(SERVICE).terminate(NONCE, RAIL_ID, provider, receiver);
        payoutBounty(recipient, getInsuranceFunds());
    }

    // After healthy deal termination, the remainder of the insurance funds can be collected by the receiver in exchange for rail cleanup
    function sweep(address recipient) external {
        require(block.number > info.endEpoch, DealNotExpired());
        amortize();
        terminate(recipient, PROVIDER, msg.sender);
    }
}
