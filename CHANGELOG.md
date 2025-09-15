# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)

## [Unreleased]

### Added
- **Payments**: Added ERC-3009 support with new deposit authorization functions ([#223](https://github.com/FilOzone/filecoin-services/pull/223))
  - `depositWithAuthorization()` for ERC-3009 compliant deposits
  - `depositWithAuthorizationAndApproveOperator()` for combined deposit and operator approval
  - `depositWithAuthorizationAndIncreaseOperatorApproval()` for combined deposit and operator allowance increase

### Changed
- **BREAKING**: Updated Payments contract ABI with breaking changes ([#223](https://github.com/FilOzone/filecoin-services/pull/223))
  - **BREAKING**: `DepositRecorded` event removes `usedPermit` parameter - event listeners must be updated
  - **BREAKING**: `railCancel` function state mutability changed from `nonpayable` to `payable` - callers may need to handle potential token transfers
  - **BREAKING**: `PermitRecipientMustBeMsgSender` error replaced with `SignerMustBeMsgSender` error - error handling code must be updated


## [0.1.0] - 2025-01-24

### Changed
- **BREAKING**: Renamed PandoraService to FilecoinWarmStorageService throughout the codebase
  - Contract name changed from `PandoraService` to `FilecoinWarmStorageService`
  - EIP-712 domain name updated to "FilecoinWarmStorageService"
  - All file names, deployment scripts, and documentation updated accordingly
  - This change requires regenerating all EIP-712 signatures for client applications
- **BREAKING**: Renamed core terminology throughout the codebase for better clarity, matching PDPVerifier version 2.0.0.
  - **Core Terminology Changes:**
    - `proofSet` → `dataSet` (all functions, events, variables, mappings; "proof set" becomes "data set")
    - `root` → `piece` (all references to stored data units)
    - `rootId` → `pieceId`
    - `owner` → `serviceProvider` (in ApprovedProviderInfo struct)
  - **Function Renames:**
    - `proofSetCreated()` → `dataSetCreated()`
    - `proofSetDeleted()` → `dataSetDeleted()`
    - `rootsAdded()` → `piecesAdded()`
    - `rootsScheduledRemove()` → `piecesScheduledRemove()`
    - `ownerChanged()` → `serviceProviderChanged()`
    - `getProofSetIdByRail()` → `getDataSetIdByRail()`
    - `getProofSetInfo()` → `getDataSetInfo()`
    - `isProofSetChargeable()` → `isDataSetChargeable()`
    - `updateProofSetExpectedMaxSize()` → `updateDataSetExpectedMaxSize()`
    - `pauseProofSetPayments()` → `pauseDataSetPayments()`
    - `resumeProofSetPayments()` → `resumeDataSetPayments()`
  - **Event Renames:**
    - `ProofSetCreated` → `DataSetCreated`
    - `ProofSetDeleted` → `DataSetDeleted`
    - `ProofSetOwnershipChanged` → `DataSetServiceProviderChanged`
    - `ProofSetRailCreated` → `DataSetRailCreated`
    - `RootMetadataAdded` → `PieceMetadataAdded`
  - **State Variable and Mapping Renames:**
    - `proofSetInfo` → `dataSetInfo`
    - `proofSetIdByRail` → `dataSetIdByRail`
    - `proofSetRail` → `dataSetRail`
    - `proofSetExpectedMaxSize` → `dataSetExpectedMaxSize`
    - `proofSetZeroCostsEpoch` → `dataSetZeroCostsEpoch`
    - `proofSetRootMetadata` → `dataSetPieceMetadata`
    - `railToProofSet` → `railToDataSet`
    - `clientProofSets` → `clientDataSets`
    - `PROOFSET_CREATION_FEE` → `DATA_SET_CREATION_FEE`
  - **Struct Updates:**
    - `ProofSetInfo` → `DataSetInfo` (with field `proofSetId` → `dataSetId`, `rootMetadata` → `pieceMetadata`)
    - `ProofSetCreateData` → `DataSetCreateData`
    - `ApprovedProviderInfo.owner` → `ApprovedProviderInfo.serviceProvider`
  - **EIP-712 Type Hash Updates:**
    - `CREATE_PROOFSET_TYPEHASH` → `CREATE_DATA_SET_TYPEHASH`
      - Type string: `"CreateProofSet(uint256 clientDataSetId,bool withCDN,address payee)"` → `"CreateDataSet(uint256 clientDataSetId,bool withCDN,address payee)"`
    - `CID_TYPEHASH` → `PIECE_CID_TYPEHASH`
      - Type string: `"Cid(bytes data)"` → `"PieceCid(bytes data)"`
    - `ROOTDATA_TYPEHASH` → `PIECE_DATA_TYPEHASH`
      - Type string: `"RootData(Cid root,uint256 rawSize)Cid(bytes data)"` → `"PieceData(PieceCid piece,uint256 rawSize)PieceCid(bytes data)"`
    - `ADD_ROOTS_TYPEHASH` → `ADD_PIECES_TYPEHASH`
      - Type string: `"AddRoots(uint256 clientDataSetId,uint256 firstAdded,RootData[] rootData)..."` → `"AddPieces(uint256 clientDataSetId,uint256 firstAdded,PieceData[] pieceData)..."`
    - `SCHEDULE_REMOVALS_TYPEHASH` → `SCHEDULE_PIECE_REMOVALS_TYPEHASH`
      - Type string: `"ScheduleRemovals(uint256 clientDataSetId,uint256[] rootIds)"` → `"SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)"`
    - `DELETE_PROOFSET_TYPEHASH` → `DELETE_DATA_SET_TYPEHASH`
      - Type string: `"DeleteProofSet(uint256 clientDataSetId)"` → `"DeleteDataSet(uint256 clientDataSetId)"`
  - **Signature Verification Method Renames:**
    - `verifyCreateProofSetSignature()` → `verifyCreateDataSetSignature()`
    - `verifyAddRootsSignature()` → `verifyAddPiecesSignature()`
    - `verifyScheduleRemovalsSignature()` → `verifySchedulePieceRemovalsSignature()`
    - `verifyDeleteProofSetSignature()` → `verifyDeleteDataSetSignature()`
  - **Type Updates:**
    - `PDPVerifier.RootData` → `IPDPTypes.PieceData` throughout
    - Added import: `import {IPDPTypes} from "@pdp/interfaces/IPDPTypes.sol";`
  - **Documentation and Script Updates:**
    - `create_proofset_with_payments.sh` → `create_data_set_with_payments.sh`
    - Updated README files to reflect new terminology

### Technical Updates
- Updated FilecoinWarmStorageService `VERSION` constant to "0.1.0"
- Added `ContractUpgraded` event and `migrate()` function for future upgrade support
- Added import for `ERC1967Utils` from OpenZeppelin
- Updated submodule `service_contracts/lib/pdp` to version 2.0.0

### Migration Notes
This release contains breaking changes that rename core concepts throughout the codebase. Developers will need to update:
- All function calls from `proofSet*` to `dataSet*` and `root*` to `piece*`
- Event listeners for the renamed events
- Struct field references (especially `owner` → `serviceProvider`)
- EIP-712 signature generation code to use new type strings
- Type imports from `PDPVerifier.RootData` to `IPDPTypes.PieceData`

The underlying functionality remains unchanged; this release only updates terminology for consistency.

[Unreleased]: https://github.com/filozone/filecoin-services/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/filozone/filecoin-services/releases/tag/v0.1.0