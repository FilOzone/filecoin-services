// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IPDPVerifier} from "@pdp/interfaces/IPDPVerifier.sol";
import {Cids} from "@pdp/Cids.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {Errors} from "../Errors.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";
import {
    MAX_KEY_LENGTH,
    MAX_KEYS_PER_PIECE,
    MAX_SCHEDULE_PIECE_REMOVALS_EXTRA_DATA_SIZE,
    MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE,
    MAX_VALUE_LENGTH
} from "../FilecoinWarmStorageService.sol";
import {
    ADD_PIECES_BASE_FEE,
    ADD_PIECES_PER_PIECE_FEE,
    SCHEDULE_PIECE_REMOVALS_FEE,
    TERMINATE_FEE
} from "../lib/PriceListUSDFC.sol";
import {LibRails} from "../lib/LibRails.sol";
import {FWSSEIP712} from "../lib/FWSSEIP712.sol";
import {FWSSPDPVerifier} from "../lib/FWSSPDPVerifier.sol";
import {IFWSSConfig} from "../interfaces/IFWSSConfig.sol";
import {LibStoragePayments} from "../lib/LibStoragePayments.sol";
import {LibServiceLifecycleGuards} from "../lib/LibServiceLifecycleGuards.sol";
import {LibSignatureVerification} from "../lib/LibSignatureVerification.sol";

/// @title FWSSAuthorizationModule
/// @notice Manages payer-authorized data set operations: adding and removing pieces, terminating service, and
/// attaching the data set authorizer.
contract FWSSAuthorizationModule is FWSSStorage, FWSSEIP712, FWSSPDPVerifier {
    using LibRails for FilecoinPayV1;

    SessionKeyRegistry public immutable sessionKeyRegistry;

    /// @notice Configures the session key registry used to verify payer signatures.
    constructor(SessionKeyRegistry _sessionKeyRegistry) {
        require(
            _sessionKeyRegistry != SessionKeyRegistry(address(0)),
            Errors.ZeroAddress(Errors.AddressField.SessionKeyRegistry)
        );
        sessionKeyRegistry = _sessionKeyRegistry;
    }

    event PieceAdded(
        uint256 indexed dataSetId, uint256 indexed pieceId, Cids.Cid pieceCid, string[] keys, string[] values
    );

    event DataSetAuthorizerSet(uint256 indexed dataSetId, address indexed authorizer);

    /// @notice Emitted when a service is terminated.
    /// @param approver The address that authorized termination: the payer, one of the payer's
    ///   session keys (SessionKeyRegistry), or the service provider. Cross-reference with
    ///   `DataSetCreated` to classify: `approver == serviceProvider` is provider-initiated;
    ///   otherwise the payer (or their session key) authorized it. Mutual termination — payer
    ///   signed off-chain while the provider submitted the tx — is indistinguishable from
    ///   payer-initiated using this event alone; inspect the call trace to detect it.
    event ServiceTerminated(
        address indexed approver,
        uint256 indexed dataSetId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId
    );

    /**
     * @notice Handles pieces being added to a data set and emits associated metadata
     * @dev Called by the PDPVerifier contract when pieces are added to a data set.
     * @param dataSetId The ID of the data set
     * @param firstAdded The ID of the first piece added (from PDPVerifier, used for piece ID assignment)
     * @param pieceData Array of piece data objects
     * @param extraData Encoded (nonce, metadata keys, metadata values, signature). The metadata outer arrays may
     *                  both be empty to indicate that no piece in the batch has metadata.
     */
    function piecesAdded(uint256 dataSetId, uint256 firstAdded, Cids.Cid[] memory pieceData, bytes calldata extraData)
        external
        onlyPDPVerifier
    {
        requirePaymentNotTerminated(dataSetId);
        // Verify the data set exists in our mapping
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));

        // Get the payer address for this data set
        address payer = info.payer;
        uint256 len = extraData.length;
        require(len > 0, Errors.ExtraDataRequired());
        // Decode the extra data
        (uint256 nonce, string[][] memory metadataKeys, string[][] memory metadataValues, bytes memory signature) =
            abi.decode(extraData, (uint256, string[][], string[][], bytes));

        // Validate nonce hasn't been used (replay protection)
        require(clientNonces[payer][nonce] == 0, Errors.ClientDataSetAlreadyRegistered(nonce));
        // Mark nonce as used, storing cumulative piece count (next piece ID) in upper bits
        clientNonces[payer][nonce] = ((firstAdded + pieceData.length) << 128) | dataSetId;

        // Empty outer arrays compactly represent a batch with no metadata. Otherwise, require
        // one metadata array per piece.
        bool metadataOmitted = metadataKeys.length == 0 && metadataValues.length == 0;
        if (!metadataOmitted) {
            require(
                metadataKeys.length == pieceData.length,
                Errors.MetadataArrayCountMismatch(metadataKeys.length, pieceData.length)
            );
            require(
                metadataValues.length == pieceData.length,
                Errors.MetadataArrayCountMismatch(metadataValues.length, pieceData.length)
            );
        }

        // Verify the signature
        verifyAddPiecesSignature(
            dataSetId, payer, info.clientDataSetId, pieceData, nonce, metadataKeys, metadataValues, signature
        );

        uint96 pending =
            info.pendingOneTimePayments + uint96(ADD_PIECES_BASE_FEE + pieceData.length * ADD_PIECES_PER_PIECE_FEE);
        uint96 reserveBalance = info.lifecycleReserveBalance;

        // Validate lockup for the new data set size (fail-fast if client has insufficient funds)
        uint256 currentLeafCount =
            IPDPVerifier(IFWSSConfig(address(this)).pdpVerifierAddress()).getDataSetLeafCount(dataSetId);
        LibStoragePayments.updatePaymentRates(
            dataSetId,
            info,
            currentLeafCount,
            pending,
            reserveBalance,
            false,
            FilecoinPayV1(IFWSSConfig(address(this)).paymentsContractAddress())
        );

        if (metadataOmitted) {
            string[] memory emptyMetadata = new string[](0);
            for (uint256 i = 0; i < pieceData.length; i++) {
                emit PieceAdded(dataSetId, firstAdded + i, pieceData[i], emptyMetadata, emptyMetadata);
            }
            return;
        }

        // Validate and emit metadata for each new piece. Metadata is indexed off-chain from this event.
        for (uint256 i = 0; i < pieceData.length; i++) {
            uint256 pieceId = firstAdded + i;
            string[] memory pieceKeys = metadataKeys[i];
            string[] memory pieceValues = metadataValues[i];

            // Check that number of metadata keys and values are equal for this piece
            require(
                pieceKeys.length == pieceValues.length,
                Errors.MetadataKeyAndValueLengthMismatch(pieceKeys.length, pieceValues.length)
            );

            require(
                pieceKeys.length <= MAX_KEYS_PER_PIECE, Errors.TooManyMetadataKeys(MAX_KEYS_PER_PIECE, pieceKeys.length)
            );

            for (uint256 k = 0; k < pieceKeys.length; k++) {
                string memory key = pieceKeys[k];
                string memory value = pieceValues[k];

                require(
                    bytes(key).length <= MAX_KEY_LENGTH,
                    Errors.MetadataKeyExceedsMaxLength(k, MAX_KEY_LENGTH, bytes(key).length)
                );
                bytes32 keyHash = keccak256(bytes(key));
                for (uint256 j = 0; j < k; j++) {
                    require(keyHash != keccak256(bytes(pieceKeys[j])), Errors.DuplicateMetadataKey(dataSetId, key));
                }
                require(
                    bytes(value).length <= MAX_VALUE_LENGTH,
                    Errors.MetadataValueExceedsMaxLength(k, MAX_VALUE_LENGTH, bytes(value).length)
                );
            }
            emit PieceAdded(dataSetId, pieceId, pieceData[i], pieceKeys, pieceValues);
        }
    }

    function piecesScheduledRemove(uint256 dataSetId, uint256[] memory pieceIds, bytes calldata extraData)
        external
        onlyPDPVerifier
    {
        LibServiceLifecycleGuards.requirePaymentNotBeyondEndEpoch(dataSetId, dataSetInfo[dataSetId].pdpEndEpoch);
        // Verify the data set exists in our mapping
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));

        // Get the payer address for this data set
        address payer = info.payer;

        // Decode the signature from extraData
        uint256 len = extraData.length;
        require(len > 0, Errors.ExtraDataRequired());
        require(
            len <= MAX_SCHEDULE_PIECE_REMOVALS_EXTRA_DATA_SIZE,
            Errors.ExtraDataTooLarge(len, MAX_SCHEDULE_PIECE_REMOVALS_EXTRA_DATA_SIZE)
        );
        bytes memory signature = abi.decode(extraData, (bytes));

        // Verify the signature
        verifySchedulePieceRemovalsSignature(dataSetId, payer, info.clientDataSetId, pieceIds, signature);

        uint96 newPending = info.pendingOneTimePayments + uint96(SCHEDULE_PIECE_REMOVALS_FEE);
        info.lifecycleReserveBalance = FilecoinPayV1(IFWSSConfig(address(this)).paymentsContractAddress())
            .replenishReserveIfNeeded(info.pdpRailId, info.pdpEndEpoch, info.lifecycleReserveBalance, newPending);
        info.pendingOneTimePayments = newPending;

        // Queue piece IDs for metadata cleanup at nextProvingPeriod
        uint256[] storage scheduled = scheduledPieceMetadataRemovals[dataSetId];
        for (uint256 i = 0; i < pieceIds.length; i++) {
            scheduled.push(pieceIds[i]);
        }
    }

    function terminateService(uint256 dataSetId, bytes calldata extraData) external {
        _terminateService(dataSetId, extraData);
    }

    /// @custom:deprecated Use terminateService(uint256,bytes) instead
    function terminateService(uint256 dataSetId) external {
        _terminateService(dataSetId, "");
    }

    function _terminateService(uint256 dataSetId, bytes memory extraData) private {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.pdpEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));

        address approver;
        bool immediateTermination = false;
        if (extraData.length > 0) {
            require(
                msg.sender == info.serviceProvider,
                Errors.CallerNotServiceProvider(dataSetId, info.serviceProvider, msg.sender)
            );
            require(
                extraData.length <= MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE,
                Errors.ExtraDataTooLarge(extraData.length, MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE)
            );
            bytes memory signature = abi.decode(extraData, (bytes));
            approver = verifyTerminateServiceSignature(info.payer, dataSetId, signature);
            immediateTermination = true;
            info.pendingOneTimePayments += uint96(TERMINATE_FEE);
        } else {
            require(
                msg.sender == info.payer || msg.sender == info.serviceProvider,
                Errors.CallerNotPayerOrPayee(dataSetId, info.payer, info.serviceProvider, msg.sender)
            );
            approver = msg.sender;
        }

        FilecoinPayV1 payments = FilecoinPayV1(IFWSSConfig(address(this)).paymentsContractAddress());

        uint96 pending = info.pendingOneTimePayments;
        if (pending > 0) {
            uint256 leafCount =
                IPDPVerifier(IFWSSConfig(address(this)).pdpVerifierAddress()).getDataSetLeafCount(dataSetId);
            LibStoragePayments.updatePaymentRates(
                dataSetId, info, leafCount, pending, info.lifecycleReserveBalance, immediateTermination, payments
            );
        }

        payments.terminateRail(info.pdpRailId);

        emit ServiceTerminated(approver, dataSetId, info.pdpRailId, info.cacheMissRailId, info.cdnRailId);
    }

    function requirePaymentNotTerminated(uint256 dataSetId) internal view {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.pdpEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));
    }

    /**
     * @notice Verifies a signature for the AddPieces operation
     * @param dataSetId The data set being operated on
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The ID of the data set
     * @param pieceDataArray Array of piece CID structures
     * @param nonce Client-chosen nonce for replay protection
     * @param allKeys 2D array where allKeys[i] contains metadata keys for piece i
     * @param allValues 2D array where allValues[i] contains metadata values for piece i
     * @param signature The signature bytes (v, r, s)
     */
    function verifyAddPiecesSignature(
        uint256 dataSetId,
        address payer,
        uint256 clientDataSetId,
        Cids.Cid[] memory pieceDataArray,
        uint256 nonce,
        string[][] memory allKeys,
        string[][] memory allValues,
        bytes memory signature
    ) internal {
        LibSignatureVerification.verifyAddPiecesAuthorization(
            payer,
            dataSetId,
            dataSetAuthorizer[dataSetId],
            clientDataSetId,
            pieceDataArray,
            nonce,
            allKeys,
            allValues,
            signature,
            _domainSeparatorV4(),
            sessionKeyRegistry
        );
    }

    /**
     * @notice Verifies a signature for the SchedulePieceRemovals operation
     * @param dataSetId The data set being operated on
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The ID of the data set
     * @param pieceIds Array of piece IDs to be removed
     * @param signature The signature bytes (v, r, s)
     */
    function verifySchedulePieceRemovalsSignature(
        uint256 dataSetId,
        address payer,
        uint256 clientDataSetId,
        uint256[] memory pieceIds,
        bytes memory signature
    ) internal {
        LibSignatureVerification.verifySchedulePieceRemovalsAuthorization(
            payer,
            dataSetId,
            dataSetAuthorizer[dataSetId],
            clientDataSetId,
            pieceIds,
            signature,
            _domainSeparatorV4(),
            sessionKeyRegistry
        );
    }

    function verifyTerminateServiceSignature(address payer, uint256 dataSetId, bytes memory signature)
        internal
        returns (address signer)
    {
        return LibSignatureVerification.verifyTerminateServiceAuthorization(
            payer, dataSetId, dataSetAuthorizer[dataSetId], signature, _domainSeparatorV4(), sessionKeyRegistry
        );
    }

    /**
     * @notice Attach, rotate, or clear the optional authorizer for a data set.
     */
    function setDataSetAuthorizer(uint256 dataSetId, address authorizer) external {
        require(dataSetInfo[dataSetId].payer == msg.sender, Errors.OnlyDataSetPayer(dataSetId, msg.sender));
        require(authorizer == address(0) || authorizer.code.length > 0, Errors.InvalidDataSetAuthorizer(authorizer));
        dataSetAuthorizer[dataSetId] = authorizer;
        emit DataSetAuthorizerSet(dataSetId, authorizer);
    }
}
