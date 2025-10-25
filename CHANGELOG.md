# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)

## [Unreleased]

### Added
- Dataset lifecycle tracking with `DataSetStatusChanged` event ([#169](https://github.com/FilOzone/filecoin-services/issues/169))
- Convenience functions `isDataSetActive()` and `getDataSetStatusDetails()` for status checking
- Comprehensive documentation: dataset lifecycle guide and integration guide
- Subgraph status history tracking with `DataSetStatusHistory` entity

### Changed
- **BREAKING**: Simplified `DataSetStatus` enum from 3 states to 2 states ([#169](https://github.com/FilOzone/filecoin-services/issues/169))
  - **Old values**: `NotFound (0)`, `Active (1)`, `Terminating (2)`
  - **New values**: `Inactive (0)`, `Active (1)`
  - **Migration**: 
    - `NotFound` → `Inactive` (non-existent datasets)
    - `Terminating` → `Active` (terminated datasets with pieces are still Active)
    - Use `pdpEndEpoch` to check if a dataset is terminated
  - **Details**: `Inactive` represents non-existent datasets or datasets with no pieces yet. `Active` represents all datasets with pieces, including terminated ones.
  - Use `getDataSetStatusDetails()` to check termination status separately from Active/Inactive status
- Subgraph schema updated with status enum and history tracking
- **Calibnet**: Reduced DEFAULT_CHALLENGE_WINDOW_SIZE from 30 epochs to 20 epochs for faster testing iteration

## [0.3.0] - 2025-10-08 - M3.1 Calibration Network Deployment

## Core Contracts

1. Payments Contract: [0x6dB198201F900c17e86D267d7Df82567FB03df5E](https://calibration.filfox.info/en/address/0x6dB198201F900c17e86D267d7Df82567FB03df5E)
  - From [Filecoin-Pay v0.6.0](https://github.com/FilOzone/filecoin-pay/releases/tag/v0.6.0)
2. PDPVerifier Implementation: [0x4EC9a8ae6e6A419056b6C332509deEA371b182EF](https://calibration.filfox.info/en/address/0x4EC9a8ae6e6A419056b6C332509deEA371b182EF)
  - From [PDP v2.2.1](https://github.com/FilOzone/pdp/releases/tag/v2.2.1)
3. PDPVerifier Proxy: [0x579dD9E561D4Cd1776CF3e52E598616E77D5FBcb](https://calibration.filfox.info/en/address/0x579dD9E561D4Cd1776CF3e52E598616E77D5FBcb)
  - From [PDP v2.2.1](https://github.com/FilOzone/pdp/releases/tag/v2.2.1)
4. SessionKeyRegistry: [0x97Dd879F5a97A8c761B94746d7F5cfF50AAd4452](https://calibration.filfox.info/en/address/0x97Dd879F5a97A8c761B94746d7F5cfF50AAd4452)
5. ServiceProviderRegistry Implementation: [0x5672fE3B5366819B4Bd2F538A2CAEA11f0b2Aff5](https://calibration.filfox.info/en/address/0x5672fE3B5366819B4Bd2F538A2CAEA11f0b2Aff5)
6. ServiceProviderRegistry Proxy: [0x1096ba1e7BB912136DA8524A22bF71091dc4FDd9](https://calibration.filfox.info/en/address/0x1096ba1e7BB912136DA8524A22bF71091dc4FDd9)
7. FilecoinWarmStorageService Implementation: [0x6B78a026309bc2659c5891559D412FA1BA6529A5](https://calibration.filfox.info/en/address/0x6B78a026309bc2659c5891559D412FA1BA6529A5)
8. FilecoinWarmStorageService Proxy: [0x468342072e0dc86AFFBe15519bc5B1A1aa86e4dc](https://calibration.filfox.info/en/address/0x468342072e0dc86AFFBe15519bc5B1A1aa86e4dc)
9. FilecoinWarmStorageServiceStateView: [0xE4587AAdB97d7B8197aa08E432bAD0D9Cfe3a17F](https://calibration.filfox.info/en/address/0xE4587AAdB97d7B8197aa08E432bAD0D9Cfe3a17F)

Configuration:
- USDFC Token: [0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0](https://calibration.filfox.info/en/address/0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0)
- FILBEAM_BENEFICIARY_ADDRESS: [0x1D60d2F5960Af6341e842C539985FA297E10d6eA](https://calibration.filfox.info/en/address/0x1D60d2F5960Af6341e842C539985FA297E10d6eA)
- FILBEAM_CONTROLLER_ADDRESS: [0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A](https://calibration.filfox.info/en/address/0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A)
- CHALLENGE_FINALITY: 10 epochs 
- MAX_PROVING_PERIOD: 240 epochs
- CHALLENGE_WINDOW_SIZE: 30 epochs
- Service Name: "Filecoin Warm Storage Service - Calibration M3.1"
- Service Description: "Calibration FWSS contracts for M3.1"

### Changed
- **ServiceProviderRegistry full redeploy** - Required due to state compatibility issues with FilecoinWarmStorageService
  - Previous FWSS release (0.2.0) used an old ServiceProviderRegistry; upgrading existing ServiceProviderRegistry would cause state mismatch with FWSS
- **ServiceProviderRegistry VERSION updated to 0.3.0** to properly reflect inclusion of providerId struct fix from PR #247
- **FilecoinWarmStorageService VERSION string updated to 0.3.0**.
- **Changed PDPVerifier to v2.2.1** ([PDP v2.2.1 release notes](https://github.com/FilOzone/pdp/releases/tag/v2.2.1))
  - Restored `createDataSet()` function for enhanced flexibility in dataset initialization, enabling empty "bucket" creation, smoother Curio and synapse-sdk integration ([#219](https://github.com/FilOzone/pdp/pull/219))

## [0.2.0] - 2025-10-07 - M3 Calibration Network Deployment

## Core Contracts

### Calibration Network:
1. Payments Contract: [0x6dB198201F900c17e86D267d7Df82567FB03df5E](https://calibration.filfox.info/en/address/0x6dB198201F900c17e86D267d7Df82567FB03df5E)
  - From [Filecoin-Pay v0.6.0](https://github.com/FilOzone/filecoin-pay/releases/tag/v0.6.0)
2. PDPVerifier Implementation: [0xCa92b746a7af215e0AaC7D0F956d74B522b295b6](https://calibration.filfox.info/en/address/0xCa92b746a7af215e0AaC7D0F956d74B522b295b6)
  - From [PDP v2.2.0](https://github.com/FilOzone/pdp/releases/tag/v2.2.0)
3. PDPVerifier Proxy: [0x9ecb84bB617a6Fd9911553bE12502a1B091CdfD8](https://calibration.filfox.info/en/address/0x9ecb84bB617a6Fd9911553bE12502a1B091CdfD8)
  - From [PDP v2.2.0](https://github.com/FilOzone/pdp/releases/tag/v2.2.0)
4. SessionKeyRegistry: [0x97Dd879F5a97A8c761B94746d7F5cfF50AAd4452](https://calibration.filfox.info/en/address/0x97Dd879F5a97A8c761B94746d7F5cfF50AAd4452)
5. ServiceProviderRegistry Implementation: [0xEdc9A41371d69a736bEfBa7678007BDBA61425E5](https://calibration.filfox.info/en/address/0xEdc9A41371d69a736bEfBa7678007BDBA61425E5)
6. ServiceProviderRegistry Proxy: [0xA8a7e2130C27e4f39D1aEBb3D538D5937bCf8ddb](https://calibration.filfox.info/en/address/0xA8a7e2130C27e4f39D1aEBb3D538D5937bCf8ddb)
7. FilecoinWarmStorageService Implementation: [0x2d76e3A41fa4614D1840CEB73aa07c5d0af6a023](https://calibration.filfox.info/en/address/0x2d76e3A41fa4614D1840CEB73aa07c5d0af6a023)
8. FilecoinWarmStorageService Proxy: [0x9ef4cAb0aD0D19b8Df28791Df80b29bC784bE91b](https://calibration.filfox.info/en/address/0x9ef4cAb0aD0D19b8Df28791Df80b29bC784bE91b)
9. FilecoinWarmStorageServiceStateView: [0x7175a72479e2B0050ed310f1a49a517C03573547](https://calibration.filfox.info/en/address/0x7175a72479e2B0050ed310f1a49a517C03573547)

Configuration:
- USDFC Token: [0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0](https://calibration.filfox.info/en/address/0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0)
- FILBEAM_BENEFICIARY_ADDRESS: [0x1D60d2F5960Af6341e842C539985FA297E10d6eA](https://calibration.filfox.info/en/address/0x1D60d2F5960Af6341e842C539985FA297E10d6eA)
- FILBEAM_CONTROLLER_ADDRESS: [0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A](https://calibration.filfox.info/en/address/0x5f7E5E2A756430EdeE781FF6e6F7954254Ef629A)
- CHALLENGE_FINALITY: 10 epochs 
- MAX_PROVING_PERIOD: 240 epochs
- CHALLENGE_WINDOW_SIZE: 30 epochs
- Service Name: "Filecoin Warm Storage Service - Calibration M3"
- Service Description: "Calibration FWSS contracts for M3"

### Added
- feat: announcePlannedUpgrade ([#260](https://github.com/FilOzone/filecoin-services/pull/260))
- feat: Allow deletion of terminated dataset, Add getDataSetStatus ([#255](https://github.com/FilOzone/filecoin-services/pull/255))
- feat(ServiceProviderRegistry): add getProvidersByIds batch lookup function ([251](https://github.com/FilOzone/filecoin-services/pull/251))
- perf(ServiceProviderRegistry): getProviderPayee helper for dataSetCreated ([#249](https://github.com/FilOzone/filecoin-services/pull/249))
- Added ERC-3009 support with new deposit authorization functions ([#225](https://github.com/FilOzone/filecoin-services/pull/225))
  - `depositWithAuthorization()` for ERC-3009 compliant deposits
  - `depositWithAuthorizationAndApproveOperator()` for combined deposit and operator approval
  - `depositWithAuthorizationAndIncreaseOperatorApproval()` for combined deposit and operator allowance increase
- feat: service registry: add providerId to ServiceInfo ([#209](https://github.com/FilOzone/filecoin-services/pull/209))
- feat: owner beneficairy seperation without transfer ([#191](https://github.com/FilOzone/filecoin-services/pull/191))
- feat: Add dataset termination and deletion status tracking for SDK usability ([#146](https://github.com/FilOzone/filecoin-services/pull/146))
- Switch from PieceCIDv2 to v2 ([#123](https://github.com/FilOzone/filecoin-services/pull/123))
- perf(provenPeriods): bitmap ([#258](https://github.com/FilOzone/filecoin-services/pull/258))

### Changed
- Modify CDN payment rails and add methods for usage-based payments ([#237](https://github.com/FilOzone/filecoin-services/pull/237))
- **BREAKING**: Updated Payments contract ABI with breaking changes ([#223](https://github.com/FilOzone/filecoin-services/pull/223))
  - `DepositRecorded` event removes `usedPermit` parameter - event listeners must be updated
  - `railCancel` function state mutability changed from `nonpayable` to `payable` - callers may need to handle potential token transfers
  - `PermitRecipientMustBeMsgSender` error replaced with `SignerMustBeMsgSender` error - error handling code must be updated
- feat: remove provierId from ServiceProviderInfo struct ([#247](https://github.com/FilOzone/filecoin-services/pull/247))
  - Adds a `ServiceProviderInfoView` struct with `providerId` field for external consumption.
- **Breaking**: feat!: FilCDN now is FilBeam ([#236](https://github.com/FilOzone/filecoin-services/pull/236))
- **Breaking**: feat!: update service parameters ([#239](https://github.com/FilOzone/filecoin-services/pull/239))
  - The price changes was [temporiarily reverted for this release](https://github.com/FilOzone/filecoin-services/pull/261) until a upcoming feature is landed that warranted this change.
- feat: remove dataset creation fee ([#245](https://github.com/FilOzone/filecoin-services/pull/245))
- feat: update getClientDataSets to return dataSetId ([#242](https://github.com/FilOzone/filecoin-services/pull/242))
- fix: update FilCDN Controller & Beneficiary addresses ([#230](https://github.com/FilOzone/filecoin-services/pull/230))
- feat(subgraph): updates based on KV metadata and service provider registry ([#189](https://github.com/FilOzone/filecoin-services/pull/189))
- Add emit pieceCid in PieceAdded event ([#207](https://github.com/FilOzone/filecoin-services/pull/207))
- fix: Clear withCDN flag when terminating service ([#208](https://github.com/FilOzone/filecoin-services/pull/208))
- fix: remove serviceName and serviceDescription properties ([#199](https://github.com/FilOzone/filecoin-services/pull/199))
- feat: rename datset termination and emit events for dataset termination and add extradata ([#129](https://github.com/FilOzone/filecoin-services/pull/129))
- feat: remove service provider registry as we're moving it to it's own contract ([#135](https://github.com/FilOzone/filecoin-services/pull/135))

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

[Unreleased]: https://github.com/filozone/filecoin-services/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/filozone/filecoin-services/releases/tag/v0.2.0
[0.1.0]: https://github.com/filozone/filecoin-services/releases/tag/v0.1.0
