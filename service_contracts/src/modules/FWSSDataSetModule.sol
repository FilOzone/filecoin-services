// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IPDPVerifier} from "@pdp/interfaces/IPDPVerifier.sol";
import {Cids} from "@pdp/Cids.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {ServiceProviderRegistry} from "../ServiceProviderRegistry.sol";
import {Errors} from "../Errors.sol";
import {FWSSPieceMetadataRemovals} from "../abstract/FWSSPieceMetadataRemovals.sol";
import {
    PDP_INACTIVITY_WINDOW,
    MAX_CREATE_DATA_SET_EXTRA_DATA_SIZE,
    MAX_SCHEDULE_PIECE_REMOVALS_EXTRA_DATA_SIZE
} from "../FilecoinWarmStorageService.sol";
import {
    ADD_PIECES_BASE_FEE,
    ADD_PIECES_PER_PIECE_FEE,
    CREATE_DATA_SET_FEE,
    LIFECYCLE_RESERVE_TARGET,
    SCHEDULE_PIECE_REMOVALS_FEE,
    SERVICE_COMMISSION_BPS,
    TOKEN_DECIMALS
} from "../lib/PriceListUSDFC.sol";
import {Rails} from "../lib/Rails.sol";
import {FWSSPDPVerifier} from "../lib/FWSSPDPVerifier.sol";
import {IFWSSConfig} from "../interfaces/IFWSSConfig.sol";
import {LibStoragePayments} from "../lib/LibStoragePayments.sol";
import {LibProving} from "../lib/LibProving.sol";
import {LibServiceLifecycleGuards} from "../lib/LibServiceLifecycleGuards.sol";
import {SignatureVerificationLib} from "../lib/SignatureVerificationLib.sol";

/// @title FWSSDataSetModule
/// @notice Manages dataset creation, deletion, pieces and client authorization.
contract FWSSDataSetModule is EIP712Upgradeable, FWSSPieceMetadataRemovals, FWSSPDPVerifier {
    using Rails for FilecoinPayV1;

    // Metadata size and count limits
    uint256 private constant MAX_KEY_LENGTH = 32;
    uint256 private constant MAX_VALUE_LENGTH = 96;
    uint256 private constant MAX_KEYS_PER_DATASET = 10;
    uint256 private constant MAX_KEYS_PER_PIECE = 3;

    // Metadata key constants
    uint256 private constant METADATA_KEY_WITH_CDN_SIZE = 7;
    bytes32 private constant METADATA_KEY_WITH_CDN_HASH = keccak256("withCDN");

    IERC20Metadata private immutable usdfcTokenAddress;
    address private immutable filBeamBeneficiaryAddress;
    ServiceProviderRegistry private immutable serviceProviderRegistry;
    SessionKeyRegistry private immutable sessionKeyRegistry;

    /// @notice Configures the immutable dependencies used by dataset operations.
    /// @dev These retain the implementation-bound configuration of FWSS without adding storage or getters.
    constructor(
        IERC20Metadata _usdfc,
        address _filBeamBeneficiaryAddress,
        ServiceProviderRegistry _serviceProviderRegistry,
        SessionKeyRegistry _sessionKeyRegistry
    ) {
        require(_usdfc != IERC20Metadata(address(0)), Errors.ZeroAddress(Errors.AddressField.USDFC));
        usdfcTokenAddress = _usdfc;

        require(_filBeamBeneficiaryAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilBeamBeneficiary));
        filBeamBeneficiaryAddress = _filBeamBeneficiaryAddress;

        require(
            _serviceProviderRegistry != ServiceProviderRegistry(address(0)),
            Errors.ZeroAddress(Errors.AddressField.ServiceProviderRegistry)
        );
        serviceProviderRegistry = _serviceProviderRegistry;

        require(
            _sessionKeyRegistry != SessionKeyRegistry(address(0)),
            Errors.ZeroAddress(Errors.AddressField.SessionKeyRegistry)
        );
        sessionKeyRegistry = _sessionKeyRegistry;

        // Verify token decimals from the USDFC token contract
        require(TOKEN_DECIMALS == _usdfc.decimals());
    }

    event DataSetServiceProviderChanged(
        uint256 indexed dataSetId, address indexed oldServiceProvider, address indexed newServiceProvider
    );

    event DataSetCreated(
        uint256 indexed dataSetId,
        uint256 indexed providerId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId,
        address payer,
        address serviceProvider,
        address payee,
        string[] metadataKeys,
        string[] metadataValues
    );

    event PieceAdded(
        uint256 indexed dataSetId, uint256 indexed pieceId, Cids.Cid pieceCid, string[] keys, string[] values
    );

    event DataSetAuthorizerSet(uint256 indexed dataSetId, address indexed authorizer);

    // Decode structure for data set creation extra data
    struct DataSetCreateData {
        // The address of the payer who should have signed the message
        address payer;
        // the unique ID for the client's data set
        uint256 clientDataSetId;
        // Array of metadata keys
        string[] metadataKeys;
        // Array of metadata values
        string[] metadataValues;
        // The signature bytes (v, r, s)
        bytes signature;
    }

    // Listener interface methods
    /**
     * @notice Handles data set creation by creating a payment rail
     * @dev Called by the PDPVerifier contract when a new data set is created
     * @param dataSetId The ID of the newly created data set
     * @param serviceProvider The address that creates and owns the data set
     * @param extraData Encoded data containing metadata, payer information, and signature
     */
    function dataSetCreated(uint256 dataSetId, address serviceProvider, bytes calldata extraData)
        external
        onlyPDPVerifier
    {
        // Decode the extra data to get the metadata, payer address, and signature
        uint256 len = extraData.length;
        require(len > 0, Errors.ExtraDataRequired());
        require(
            len <= MAX_CREATE_DATA_SET_EXTRA_DATA_SIZE,
            Errors.ExtraDataTooLarge(len, MAX_CREATE_DATA_SET_EXTRA_DATA_SIZE)
        );
        DataSetCreateData memory createData = decodeDataSetCreateData(extraData);

        // Validate the addresses
        require(createData.payer != address(0), Errors.ZeroAddress(Errors.AddressField.Payer));
        require(serviceProvider != address(0), Errors.ZeroAddress(Errors.AddressField.ServiceProvider));

        uint256 providerId = serviceProviderRegistry.getProviderIdByAddress(serviceProvider);

        require(providerId != 0, Errors.ProviderNotRegistered(serviceProvider));

        address payee = serviceProviderRegistry.getProviderPayee(providerId);

        require(
            clientNonces[createData.payer][createData.clientDataSetId] == 0,
            Errors.ClientDataSetAlreadyRegistered(createData.clientDataSetId)
        );
        clientNonces[createData.payer][createData.clientDataSetId] = dataSetId;
        clientDataSets[createData.payer].push(dataSetId);

        // Verify the client's signature
        verifyCreateDataSetSignature(payee, createData);

        // Initialize the DataSetInfo struct
        DataSetInfo storage info = dataSetInfo[dataSetId];
        info.payer = createData.payer;
        info.payee = payee; // Using payee address from registry
        info.serviceProvider = serviceProvider; // Set the service provider
        info.commissionBps = SERVICE_COMMISSION_BPS;
        info.clientDataSetId = createData.clientDataSetId;
        info.providerId = providerId;

        // Store each metadata key-value entry for this data set
        require(
            createData.metadataKeys.length == createData.metadataValues.length,
            Errors.MetadataKeyAndValueLengthMismatch(createData.metadataKeys.length, createData.metadataValues.length)
        );
        require(
            createData.metadataKeys.length <= MAX_KEYS_PER_DATASET,
            Errors.TooManyMetadataKeys(MAX_KEYS_PER_DATASET, createData.metadataKeys.length)
        );

        for (uint256 i = 0; i < createData.metadataKeys.length; i++) {
            string memory key = createData.metadataKeys[i];
            string memory value = createData.metadataValues[i];

            require(bytes(dataSetMetadata[dataSetId][key]).length == 0, Errors.DuplicateMetadataKey(dataSetId, key));
            require(
                bytes(key).length <= MAX_KEY_LENGTH,
                Errors.MetadataKeyExceedsMaxLength(i, MAX_KEY_LENGTH, bytes(key).length)
            );
            require(
                bytes(value).length <= MAX_VALUE_LENGTH,
                Errors.MetadataValueExceedsMaxLength(i, MAX_VALUE_LENGTH, bytes(value).length)
            );

            // Store the metadata key in the array for this data set
            dataSetMetadataKeys[dataSetId].push(key);

            // Store the metadata value directly
            dataSetMetadata[dataSetId][key] = value;
        }

        // Note: The payer must have pre-approved this contract to spend USDFC tokens before creating the data set

        // Create the payment rails using the FilecoinPayV1 contract
        FilecoinPayV1 payments = FilecoinPayV1(IFWSSConfig(address(this)).paymentsContractAddress());

        // Determine once whether CDN is enabled in metadata and reuse the result
        bool hasCDN = hasCDNMetadataKey(createData.metadataKeys);

        (uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId) = payments.createRails(
            dataSetId, usdfcTokenAddress, createData.payer, payee, hasCDN ? filBeamBeneficiaryAddress : address(0)
        );

        railToDataSet[pdpRailId] = dataSetId;
        info.pdpRailId = pdpRailId;
        info.lifecycleReserveBalance = uint96(LIFECYCLE_RESERVE_TARGET);
        info.pendingOneTimePayments = uint96(CREATE_DATA_SET_FEE);
        if (hasCDN) {
            info.cacheMissRailId = cacheMissRailId;
            info.cdnRailId = cdnRailId;
        }
        // Emit event for tracking
        emit DataSetCreated(
            dataSetId,
            providerId,
            pdpRailId,
            cacheMissRailId,
            cdnRailId,
            createData.payer,
            serviceProvider,
            payee,
            createData.metadataKeys,
            createData.metadataValues
        );
    }

    /**
     * @notice Handles data set deletion after voluntary termination or via the abandonment path.
     * @dev Called by the PDPVerifier contract when a data set is deleted.
     *      When pdpEndEpoch == 0 the rail was never terminated via terminateService; FWSS verifies
     *      30-day inactivity and performs inline teardown so a keeper needs only one transaction.
     * @param dataSetId The ID of the data set being deleted
     */
    function dataSetDeleted(
        uint256 dataSetId,
        uint256, // deletedLeafCount, - not used
        bytes calldata // extraData, - not used
    )
        external
        onlyPDPVerifier
    {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));

        address payer = info.payer;
        FilecoinPayV1 payments = FilecoinPayV1(IFWSSConfig(address(this)).paymentsContractAddress());

        // Cache before either branch clears it — needed to bound the provenPeriods loop below.
        uint256 activation = provingActivationEpoch[dataSetId];

        if (info.pdpEndEpoch == 0) {
            // Abandonment path: rail was never terminated via terminateService.
            // SP forfeits pending op-fees; lifecycle reserve returns to the payer.
            _verifyInactivity(dataSetId);
            // abandonRails also terminates CDN rails and clears the proving activation epoch
            payments.abandonRails(
                provingActivationEpoch, dataSetId, info.pdpRailId, info.cacheMissRailId, info.cdnRailId
            );
        } else {
            // Normal path: terminateService was already called.
            // Verify the payment window has elapsed and the rail is fully settled.
            require(block.number >= info.pdpEndEpoch, Errors.PaymentRailsNotFinalized(dataSetId, info.pdpEndEpoch));
            try payments.getRail(info.pdpRailId) returns (FilecoinPayV1.RailView memory rail) {
                require(
                    rail.settledUpTo >= rail.endEpoch,
                    Errors.RailNotFullySettled(info.pdpRailId, rail.settledUpTo, rail.endEpoch)
                );
            } catch {
                // Rail is finalized (zeroed out), meaning it was already fully settled
            }
            // Terminate CDN rails if configured, giving FilBeam a graceful settle window
            if (info.cdnRailId != 0) {
                LibStoragePayments.terminateCDNRails(dataSetId, info, payments);
            }
            delete provingActivationEpoch[dataSetId];
        }

        // NOTE keep clientNonces[payer][clientDataSetId] to prevent replay

        // Remove from client's dataset list
        uint256[] storage clientDataSetList = clientDataSets[payer];
        for (uint256 i = 0; i < clientDataSetList.length; i++) {
            if (clientDataSetList[i] == dataSetId) {
                // Remove this dataset from the array
                clientDataSetList[i] = clientDataSetList[clientDataSetList.length - 1];
                clientDataSetList.pop();
                break;
            }
        }

        // Clean up proving-related state
        delete provingDeadlines[dataSetId];
        delete provenThisPeriod[dataSetId];
        if (activation != 0) {
            uint256 lastPeriod = LibProving.provingPeriodForEpoch(activation, block.number, maxProvingPeriod);
            uint256 lastSlot = lastPeriod >> 8;
            for (uint256 slot = 0; slot <= lastSlot; slot++) {
                delete provenPeriods[dataSetId][slot];
            }
        }

        // Clean up rail mappings
        delete railToDataSet[info.pdpRailId];

        // Clean up metadata mappings
        string[] storage metadataKeys = dataSetMetadataKeys[dataSetId];
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            delete dataSetMetadata[dataSetId][metadataKeys[i]];
        }
        delete dataSetMetadataKeys[dataSetId];

        _processScheduledPieceMetadataRemovals(dataSetId);

        // Complete cleanup
        delete dataSetAuthorizer[dataSetId];
        delete dataSetInfo[dataSetId];
    }

    /**
     * @notice Verifies the data set has been inactive for INACTIVITY_WINDOW.
     * @dev Layers on PDPVerifier.deleteDataSet's own gate, which restricts non-SP callers within
     *      the window. This check stops the SP themselves from using deleteDataSet to skip
     *      terminateService on an active data set.
     *      Baseline: PDPVerifier's lastProvenEpoch (initialized at creation for current data
     *      sets, updated on each proof). If 0, the data set is legacy and predates that
     *      initialization; fall back to our local provingActivationEpoch.
     *      Never-activated (activation == 0) is accepted unconditionally; PDPVerifier handles the
     *      since-activation gate.
     */
    function _verifyInactivity(uint256 dataSetId) internal view {
        uint256 activation = provingActivationEpoch[dataSetId];
        if (activation == 0) return;

        uint256 lastProvenEpoch =
            IPDPVerifier(IFWSSConfig(address(this)).pdpVerifierAddress()).getDataSetLastProvenEpoch(dataSetId);
        uint256 lastActivity = lastProvenEpoch == 0 ? activation : lastProvenEpoch;
        uint256 requiredEpoch = lastActivity + PDP_INACTIVITY_WINDOW;
        require(block.number > requiredEpoch, Errors.DataSetNotAbandoned(dataSetId, requiredEpoch, block.number));
    }

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

    /**
     * @notice Handles data set service provider changes (currently disabled for GA)
     * @dev Storage provider changes are disabled for GA. This will be re-enabled post-GA
     * with proper client authorization. See: https://github.com/FilOzone/filecoin-services/issues/203
     * Called by the PDPVerifier contract when data set service provider is transferred.
     */
    function storageProviderChanged(
        uint256, // dataSetId
        address, // oldServiceProvider
        address, // newServiceProvider
        bytes calldata // extraData - not used
    )
        external
        view
        onlyPDPVerifier
    {
        revert Errors.StorageProviderChangesNotSupported();
    }

    function requirePaymentNotTerminated(uint256 dataSetId) internal view {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.pdpEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));
    }

    /**
     * @notice Decode extra data for data set creation
     * @param extraData The encoded extra data from PDPVerifier
     * @return decoded The decoded DataSetCreateData struct
     */
    function decodeDataSetCreateData(bytes calldata extraData) internal pure returns (DataSetCreateData memory) {
        (address payer, uint256 clientDataSetId, string[] memory keys, string[] memory values, bytes memory signature) =
            abi.decode(extraData, (address, uint256, string[], string[], bytes));

        return DataSetCreateData({
            payer: payer,
            clientDataSetId: clientDataSetId,
            metadataKeys: keys,
            metadataValues: values,
            signature: signature
        });
    }

    /**
     * @notice Returns true if key `withCDN` exists in `metadataKeys`.
     * @param metadataKeys The array of metadata keys
     * @return True if key exists; false otherwise.
     */
    function hasCDNMetadataKey(string[] memory metadataKeys) internal pure returns (bool) {
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            bytes memory currentKeyBytes = bytes(metadataKeys[i]);
            if (
                currentKeyBytes.length == METADATA_KEY_WITH_CDN_SIZE
                    && keccak256(currentKeyBytes) == METADATA_KEY_WITH_CDN_HASH
            ) {
                return true;
            }
        }

        // Key absence means disabled
        return false;
    }

    /**
     * @notice Verifies a signature for the CreateDataSet operation
     * @param createData The decoded DataSetCreateData used to build the signature
     * @param payee The service provider address
     */
    function verifyCreateDataSetSignature(address payee, DataSetCreateData memory createData) internal view {
        // Compute the EIP-712 digest for the struct hash
        bytes32 digest = _hashTypedDataV4(
            SignatureVerificationLib.createDataSetStructHash(
                createData.clientDataSetId, payee, createData.metadataKeys, createData.metadataValues
            )
        );

        // Delegate to library for verification
        SignatureVerificationLib.verifyCreateDataSetSignature(
            createData.payer, createData.signature, digest, sessionKeyRegistry
        );
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
        SignatureVerificationLib.verifyAddPiecesAuthorization(
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
        SignatureVerificationLib.verifySchedulePieceRemovalsAuthorization(
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
