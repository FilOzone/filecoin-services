// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors} from "../../src/Errors.sol";
import {Extsload} from "../../src/Extsload.sol";
import {IFilecoinWarmStorageService} from "../../src/interfaces/IFilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateLibrary} from "../../src/lib/FilecoinWarmStorageServiceStateLibrary.sol";
import {FWSSViewModule} from "../../src/modules/FWSSViewModule.sol";
import {FWSSStorage} from "../../src/storage/FWSSStorage.sol";

/// @dev Populates FWSS storage before its code is replaced with ViewModuleHarness.
contract FWSSStorageWriter is FWSSStorage {
    function setProvingConfig(uint64 period, uint256 window) external {
        maxProvingPeriod = period;
        challengeWindowSize = window;
    }

    function setProving(uint256 dataSetId, uint256 activation, uint256 deadline, uint256 provenPeriod) external {
        provingActivationEpoch[dataSetId] = activation;
        provingDeadlines[dataSetId] = deadline;
        provenThisPeriod[dataSetId] = true;
        provenPeriods[dataSetId][provenPeriod >> 8] |= 1 << (provenPeriod & 255);
    }

    function setDataSet(uint256 dataSetId, DataSetInfo calldata info) external {
        dataSetInfo[dataSetId] = info;
        clientDataSets[info.payer].push(dataSetId);
        railToDataSet[info.pdpRailId] = dataSetId;
        clientNonces[info.payer][info.clientDataSetId] = dataSetId;
        dataSetAuthorizer[dataSetId] = info.payee;
    }

    function setMetadata(uint256 dataSetId, string calldata key, string calldata value) external {
        dataSetMetadataKeys[dataSetId].push(key);
        dataSetMetadata[dataSetId][key] = value;
    }

    function approveProvider(uint256 providerId) external {
        approvedProviders[providerId] = true;
        approvedProviderIds.push(providerId);
    }

    function setControllerAndUpgrade(address controller, address next, uint96 afterEpoch) external {
        filBeamControllerAddress = controller;
        nextUpgrade = PlannedUpgrade({nextImplementation: next, afterEpoch: afterEpoch});
    }
}

/// @dev Lets the state library read the same storage through extsload.
contract ViewModuleHarness is FWSSViewModule, Extsload {
    constructor(IERC20 usdfc) FWSSViewModule(usdfc) {}
}

contract FWSSViewModuleTest is Test {
    IERC20 constant USDFC = IERC20(address(0xD0C));
    address constant PAYER = address(0xA11CE);
    string constant LONG_VALUE = "a metadata value that is longer than thirty-one bytes and spans storage slots";

    FWSSViewModule internal viewModule;
    IFilecoinWarmStorageService internal service;

    function setUp() public {
        FWSSStorageWriter writer = new FWSSStorageWriter();
        writer.setProvingConfig(2880, 60);
        writer.setProving(1, 100, 3000, 0);
        for (uint256 id = 1; id <= 3; id++) {
            writer.setDataSet(
                id,
                FWSSStorage.DataSetInfo({
                    pdpRailId: 10 + id,
                    cacheMissRailId: 20 + id,
                    cdnRailId: 30 + id,
                    payer: PAYER,
                    payee: address(uint160(0xB0B + id)),
                    serviceProvider: address(uint160(0xC0C + id)),
                    commissionBps: 100 * id,
                    clientDataSetId: 40 + id,
                    pdpEndEpoch: 50 + id,
                    providerId: 60 + id,
                    pendingOneTimePayments: uint96(70 + id),
                    lifecycleReserveBalance: uint96(80 + id)
                })
            );
        }
        writer.setMetadata(1, "short", "value");
        writer.setMetadata(1, "a metadata key that is also longer than thirty-one bytes", LONG_VALUE);
        writer.setMetadata(1, "empty", "");
        writer.approveProvider(7);
        writer.approveProvider(42);
        writer.setControllerAndUpgrade(address(0xF11B), address(0x1E57), 1234);

        vm.etch(address(writer), address(new ViewModuleHarness(USDFC)).code);
        viewModule = FWSSViewModule(address(writer));
        service = IFilecoinWarmStorageService(address(writer));
        vm.roll(3000);
    }

    function testDataSetReadsMatchStateLibrary() public view {
        for (uint256 id = 0; id <= 4; id++) {
            assertEq(
                abi.encode(viewModule.getDataSet(id)),
                abi.encode(FilecoinWarmStorageServiceStateLibrary.getDataSet(service, id))
            );
            (address payer, uint256 railId) = viewModule.getDataSetPayerAndRailId(id);
            (address expectedPayer, uint256 expectedRailId) =
                FilecoinWarmStorageServiceStateLibrary.getDataSetPayerAndRailId(service, id);
            assertEq(payer, expectedPayer);
            assertEq(railId, expectedRailId);
            assertEq(
                uint8(viewModule.getDataSetStatus(id)),
                uint8(FilecoinWarmStorageServiceStateLibrary.getDataSetStatus(service, id))
            );
            assertEq(
                viewModule.getDataSetAuthorizer(id),
                FilecoinWarmStorageServiceStateLibrary.getDataSetAuthorizer(service, id)
            );
            assertEq(
                viewModule.railToDataSet(10 + id),
                FilecoinWarmStorageServiceStateLibrary.railToDataSet(service, 10 + id)
            );
            assertEq(
                viewModule.clientNonces(PAYER, 40 + id),
                FilecoinWarmStorageServiceStateLibrary.clientNonces(service, PAYER, 40 + id)
            );
        }
        assertEq(viewModule.getDataSet(2).commissionBps, 200);
        assertEq(viewModule.getDataSet(3).lifecycleReserveBalance, 83);
    }

    function testClientReadsMatchStateLibrary() public view {
        assertEq(viewModule.getClientDataSetsLength(PAYER), 3);
        assertEq(
            viewModule.clientDataSets(PAYER), FilecoinWarmStorageServiceStateLibrary.clientDataSets(service, PAYER)
        );
        assertEq(
            abi.encode(viewModule.getClientDataSets(PAYER)),
            abi.encode(FilecoinWarmStorageServiceStateLibrary.getClientDataSets(service, PAYER))
        );
        for (uint256 offset = 0; offset <= 4; offset++) {
            for (uint256 limit = 0; limit <= 4; limit++) {
                assertEq(
                    viewModule.clientDataSets(PAYER, offset, limit),
                    FilecoinWarmStorageServiceStateLibrary.clientDataSets(service, PAYER, offset, limit)
                );
                assertEq(
                    abi.encode(viewModule.getClientDataSets(PAYER, offset, limit)),
                    abi.encode(FilecoinWarmStorageServiceStateLibrary.getClientDataSets(service, PAYER, offset, limit))
                );
            }
        }
    }

    function testMetadataReadsMatchStateLibrary() public view {
        (string[] memory keys, string[] memory values) = viewModule.getAllDataSetMetadata(1);
        (string[] memory expectedKeys, string[] memory expectedValues) =
            FilecoinWarmStorageServiceStateLibrary.getAllDataSetMetadata(service, 1);
        assertEq(keys, expectedKeys);
        assertEq(values, expectedValues);
        assertEq(values[1], LONG_VALUE);

        for (uint256 i = 0; i < keys.length; i++) {
            (bool exists, string memory value) = viewModule.getDataSetMetadata(1, keys[i]);
            assertTrue(exists);
            assertEq(value, values[i]);
        }
        (bool missing,) = viewModule.getDataSetMetadata(1, "missing");
        assertFalse(missing);
    }

    function testProvingReadsMatchStateLibrary() public view {
        (uint64 period, uint256 window, uint256 challenges, uint256 initStart) = viewModule.getPDPConfig();
        (uint64 expectedPeriod, uint256 expectedWindow, uint256 expectedChallenges, uint256 expectedInitStart) =
            FilecoinWarmStorageServiceStateLibrary.getPDPConfig(service);
        assertEq(period, expectedPeriod);
        assertEq(window, expectedWindow);
        assertEq(challenges, expectedChallenges);
        assertEq(initStart, expectedInitStart);
        assertEq(
            viewModule.nextPDPChallengeWindowStart(1),
            FilecoinWarmStorageServiceStateLibrary.nextPDPChallengeWindowStart(service, 1)
        );
        assertEq(viewModule.provingActivationEpoch(1), 100);
        assertEq(viewModule.provingDeadline(1), FilecoinWarmStorageServiceStateLibrary.provingDeadline(service, 1));
        assertEq(viewModule.provenThisPeriod(1), FilecoinWarmStorageServiceStateLibrary.provenThisPeriod(service, 1));
        assertEq(
            viewModule.hasBeenProvenRecently(1),
            FilecoinWarmStorageServiceStateLibrary.hasBeenProvenRecently(service, 1)
        );
        assertTrue(viewModule.provenPeriods(1, 0));
        assertFalse(viewModule.provenPeriods(1, 1));
    }

    function testProviderAndConfigReadsMatchStateLibrary() public view {
        assertTrue(viewModule.isProviderApproved(42));
        assertFalse(viewModule.isProviderApproved(43));
        assertEq(viewModule.getApprovedProvidersLength(), 2);
        assertEq(
            viewModule.getApprovedProviders(0, 0),
            FilecoinWarmStorageServiceStateLibrary.getApprovedProviders(service, 0, 0)
        );
        assertEq(
            viewModule.getApprovedProviders(1, 5),
            FilecoinWarmStorageServiceStateLibrary.getApprovedProviders(service, 1, 5)
        );
        assertEq(viewModule.filBeamControllerAddress(), address(0xF11B));
        (address next, uint96 afterEpoch) = viewModule.nextUpgrade();
        assertEq(next, address(0x1E57));
        assertEq(afterEpoch, 1234);
        assertEq(
            viewModule.serviceCommissionBps(), FilecoinWarmStorageServiceStateLibrary.serviceCommissionBps(service)
        );
        (uint256 storagePrice, uint256 datasetFee) = viewModule.getCurrentPricingRates();
        (uint256 expectedStoragePrice, uint256 expectedDatasetFee) =
            FilecoinWarmStorageServiceStateLibrary.getCurrentPricingRates(service);
        assertEq(storagePrice, expectedStoragePrice);
        assertEq(datasetFee, expectedDatasetFee);
        assertEq(
            viewModule.getDataSetSizeInBytes(1 << 20),
            FilecoinWarmStorageServiceStateLibrary.getDataSetSizeInBytes(1 << 20)
        );
        assertEq(address(viewModule.getPriceList().token), address(USDFC));
    }

    function testConstructorRejectsZeroUsdfc() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.USDFC));
        new FWSSViewModule(IERC20(address(0)));
    }
}
