// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

/// @title Errors
/// @notice Centralized library for custom error definitions across the protocol
library Errors {
    /// @notice Identifies which contract address field was zero when a non-zero address was required
    /// @dev Used as a parameter to the {ZeroAddress} error for descriptive revert reasons
    enum AddressField {
        /// PDPVerifier contract address
        PDPVerifier,
        /// FilecoinPayV1 contract address
        FilecoinPayV1,
        /// USDFC contract address
        USDFC,
        /// FilBeam controller address
        FilBeamController,
        /// Session Key Registry contract address
        SessionKeyRegistry,
        /// Service provider address
        ServiceProvider,
        /// Payer address
        Payer,
        /// ServiceProviderRegistry contract address
        ServiceProviderRegistry,
        /// FilBeam beneficiary address
        FilBeamBeneficiary,
        /// View contract address
        View
    }

    /// @notice Enumerates the types of commission rates used in the protocol
    /// @dev Used as a parameter to {CommissionExceedsMaximum} to specify which commission type exceeded the limit
    enum CommissionType {
        /// The service commission rate
        Service
    }

    /// @notice An expected contract or participant address was the zero address
    /// @dev Used for parameter validation when a non-zero address is required
    /// @param field The specific address field that was zero (see enum {AddressField})
    error ZeroAddress(AddressField field);

    /// @notice Tried to set an address that can only be set once
    /// @dev Used for parameter validation when a non-zero address is required
    /// @param field The specific address field already set (see enum {AddressField})
    error AddressAlreadySet(AddressField field);

    /// @notice Only the PDPVerifier contract can call this function
    /// @param expected The expected PDPVerifier address
    /// @param actual The caller address
    error OnlyPDPVerifierAllowed(address expected, address actual);

    /// @notice Commission basis points exceed the allowed maximum
    /// @param commissionType The type of commission that exceeded the maximum (see {CommissionType})
    /// @param max The allowed maximum commission (basis points)
    /// @param actual The actual commission provided
    error CommissionExceedsMaximum(CommissionType commissionType, uint256 max, uint256 actual);

    /// @notice The maximum proving period must be greater than zero
    error MaxProvingPeriodZero();

    /// @notice The challenge window size must be > 0 and less than the max proving period
    /// @param maxProvingPeriod The maximum allowed proving period
    /// @param challengeWindowSize The provided challenge window size
    error InvalidChallengeWindowSize(uint256 maxProvingPeriod, uint256 challengeWindowSize);

    /// @notice The service name length must be >0 and <= 256
    /// @param length the attempted length
    error InvalidServiceNameLength(uint256 length);

    /// @notice The service description length must be >0 and <= 256
    /// @param length the attempted length
    error InvalidServiceDescriptionLength(uint256 length);

    /// @notice This function can only be called by the contract itself during upgrade
    /// @param expected The expected caller (the contract address)
    /// @param actual The actual caller address
    error OnlySelf(address expected, address actual);

    /// @notice Proving period is not initialized for the specified data set
    /// @param dataSetId The ID of the data set whose proving period was not initialized
    error ProvingPeriodNotInitialized(uint256 dataSetId);

    /// @notice The signature is invalid (recovered signer did not match expected)
    /// @param expected The expected signer address
    /// @param actual The recovered address from the signature
    error InvalidSignature(address expected, address actual);

    /// @notice Extra data is required but was not provided
    error ExtraDataRequired();

    /// @notice Data set is not registered with the payment system
    /// @param dataSetId The ID of the data set
    error DataSetNotRegistered(uint256 dataSetId);

    /// @notice This client dataset ID has already been registered to a dataset
    /// @param clientDataSetId The attempted but existing ID
    error ClientDataSetAlreadyRegistered(uint256 clientDataSetId);

    /// @notice Only one proof of possession allowed per proving period
    /// @param dataSetId The data set ID
    error ProofAlreadySubmitted(uint256 dataSetId);

    /// @notice Challenge count for proof of possession is invalid
    /// @param dataSetId The dataset for which the challenge count was checked
    /// @param minExpected The minimum expected challenge count
    /// @param actual The actual challenge count provided
    error InvalidChallengeCount(uint256 dataSetId, uint256 minExpected, uint256 actual);

    /// @notice Proving has not yet started for the data set
    /// @param dataSetId The data set ID
    error ProvingNotStarted(uint256 dataSetId);

    /// @notice The current proving period has already passed
    /// @param dataSetId The data set ID
    /// @param deadline The deadline block number
    /// @param nowBlock The current block number
    error ProvingPeriodPassed(uint256 dataSetId, uint256 deadline, uint256 nowBlock);

    // @notice The challenge window is not open yet; too early to submit proof
    /// @param dataSetId The data set ID
    /// @param windowStart The start block of the challenge window
    /// @param nowBlock The current block number
    error ChallengeWindowTooEarly(uint256 dataSetId, uint256 windowStart, uint256 nowBlock);

    /// @notice The next challenge epoch is invalid (not within the allowed challenge window)
    /// @param dataSetId The data set ID
    /// @param minAllowed The earliest allowed challenge epoch (window start)
    /// @param maxAllowed The latest allowed challenge epoch (window end)
    /// @param actual The provided challenge epoch
    error InvalidChallengeEpoch(uint256 dataSetId, uint256 minAllowed, uint256 maxAllowed, uint256 actual);

    /// @notice Only one call to nextProvingPeriod is allowed per proving period
    /// @param dataSetId The data set ID
    /// @param periodDeadline The deadline of the previous proving period
    /// @param nowBlock The current block number
    error NextProvingPeriodAlreadyCalled(uint256 dataSetId, uint256 periodDeadline, uint256 nowBlock);

    /// @notice Old service provider address does not match data set payee
    /// @param dataSetId The data set ID
    /// @param expected The expected (current) payee address
    /// @param actual The provided old service provider address
    error OldServiceProviderMismatch(uint256 dataSetId, address expected, address actual);

    /// @notice Data set payment is already terminated
    /// @param dataSetId The data set ID
    error DataSetPaymentAlreadyTerminated(uint256 dataSetId);

    /// @notice CDN payment is already terminated
    /// @param dataSetId The data set ID
    error CDNPaymentAlreadyTerminated(uint256 dataSetId);

    /// @notice Cache-miss payment is already terminated
    /// @param dataSetId The data set ID
    error CacheMissPaymentAlreadyTerminated(uint256 dataSetId);

    /// @notice Invalid top-up amount - both CDN and cache miss amounts are zero
    /// @param dataSetId The data set ID
    error InvalidTopUpAmount(uint256 dataSetId);

    /// @notice The specified data set does not exist or is not valid
    /// @param dataSetId The data set ID that was invalid or unregistered
    error InvalidDataSetId(uint256 dataSetId);

    /// @notice Only payer or payee can terminate data set payment
    /// @param dataSetId The data set ID
    /// @param expectedPayer The payer address
    /// @param expectedPayee The payee address
    /// @param caller The actual caller
    error CallerNotPayerOrPayee(uint256 dataSetId, address expectedPayer, address expectedPayee, address caller);

    /// @notice Only payer can top-up CDN payment rail balance
    /// @param dataSetId The data set ID
    /// @param expectedPayer The payer address
    /// @param caller The actual caller
    error CallerNotPayer(uint256 dataSetId, address expectedPayer, address caller);

    /// @notice Data set is beyond its payment end epoch
    /// @param dataSetId The data set ID
    /// @param pdpEndEpoch The payment end epoch for the data set
    /// @param currentBlock The current block number
    error DataSetPaymentBeyondEndEpoch(uint256 dataSetId, uint256 pdpEndEpoch, uint256 currentBlock);

    /// @notice No PDP payment rail is configured for the given data set
    /// @param dataSetId The data set ID
    error NoPDPPaymentRail(uint256 dataSetId);

    /// @notice Division by zero: denominator was zero
    error DivisionByZero();

    /// @notice Signature has an invalid length
    /// @param actualLength The length of the provided signature (should be 65)
    error InvalidSignatureLength(uint256 expectedLength, uint256 actualLength);

    /// @notice Signature uses an unsupported v value (should be 27 or 28)
    /// @param v The actual v value provided
    error UnsupportedSignatureV(uint8 v);

    /// @notice Payment rail is not associated with any data set
    /// @param railId The rail ID
    error RailNotAssociated(uint256 railId);

    /// @notice The epoch range is invalid (toEpoch must be > fromEpoch)
    /// @param fromEpoch The starting epoch (exclusive)
    /// @param toEpoch The ending epoch (inclusive)
    error InvalidEpochRange(uint256 fromEpoch, uint256 toEpoch);

    /// @notice Only the FilecoinPayV1 contract can call this function
    /// @param expected The expected payments contract address
    /// @param actual The caller's address
    error CallerNotPayments(address expected, address actual);

    /// @notice Only the service contract can terminate the rail
    error ServiceContractMustTerminateRail();

    /// @notice Data set does not exist for the given rail
    /// @param railId The rail ID
    error DataSetNotFoundForRail(uint256 railId);

    /// @notice Provider is not registered in the ServiceProviderRegistry
    /// @param provider The provider address
    error ProviderNotRegistered(address provider);

    /// @notice Provider is already approved
    /// @param providerId The provider ID that is already approved
    error ProviderAlreadyApproved(uint256 providerId);

    /// @notice Provider is not in the approved list
    /// @param providerId The provider ID that is not approved
    error ProviderNotInApprovedList(uint256 providerId);

    /// @notice Metadata key and value length mismatch
    /// @dev Thrown when metadataKeys and metadataValues arrays do not have the same length
    /// @param keysLength The length of the provided metadata keys
    /// @param valuesLength The length of the provided metadata values
    error MetadataKeyAndValueLengthMismatch(uint256 keysLength, uint256 valuesLength);

    /// @notice Metadata keys provided exceed the maximum allowed length
    /// @dev Thrown when the number of metadata keys exceeds the allowed maximum
    /// @param maxAllowed The maximum allowed length
    /// @param keysLength The length of the provided metadata keys
    error TooManyMetadataKeys(uint256 maxAllowed, uint256 keysLength);

    /// @notice Metadata key is already registered for the data set
    /// @dev Thrown when a duplicate metadata key is provided for the same data set
    /// @dev This error is used to prevent overwriting existing metadata keys
    /// @param dataSetId The ID of the data set where the duplicate key was found
    /// @param key The duplicate metadata key
    error DuplicateMetadataKey(uint256 dataSetId, string key);

    /// @notice Metadata key exceeds the maximum allowed length
    /// @dev Thrown when a metadata key is longer than the allowed maximum length
    /// @param index The index of the metadata key in the array
    /// @param maxAllowed The maximum allowed length for metadata keys
    /// @param length The length of the provided metadata key
    error MetadataKeyExceedsMaxLength(uint256 index, uint256 maxAllowed, uint256 length);

    /// @notice Metadata value exceeds the maximum allowed length
    /// @dev Thrown when a metadata value is longer than the allowed maximum length
    /// @param index The index of the metadata value in the array
    /// @param maxAllowed The maximum allowed length for metadata values
    /// @param length The length of the provided metadata value
    error MetadataValueExceedsMaxLength(uint256 index, uint256 maxAllowed, uint256 length);

    /// @notice Metadata arrays do not match the number of pieces
    /// @dev Thrown when the number of metadata arrays does not equal the number of pieces being added
    /// @param metadataArrayCount The number of metadata arrays provided
    /// @param pieceCount The number of pieces being added
    error MetadataArrayCountMismatch(uint256 metadataArrayCount, uint256 pieceCount);

    /// @notice FilBeam service is not configured for the given data set
    /// @param dataSetId The data set ID
    error FilBeamServiceNotConfigured(uint256 dataSetId);

    /// @notice Only the FilBeam controller address can call this function
    /// @param expected The expected FilBeam controller address
    /// @param actual The caller address
    error OnlyFilBeamControllerAllowed(address expected, address actual);

    /// @notice Payment rails have not finalized yet, so the data set can't be deleted
    /// @param dataSetId The data set ID
    /// @param pdpEndEpoch The end epoch when the PDP payment rail will finalize
    error PaymentRailsNotFinalized(uint256 dataSetId, uint256 pdpEndEpoch);
}
