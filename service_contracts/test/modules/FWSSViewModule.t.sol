// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {AbiCheats} from "@erc8167/lib/AbiCheats.sol";
import {ProxyStorage} from "@erc8167/lib/ProxyStorage.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {FWSSStorage} from "../../src/storage/FWSSStorage.sol";
import {ExtsloadModule} from "../../src/modules/ExtsloadModule.sol";
import {FWSSViewModule} from "../../src/modules/FWSSViewModule.sol";
import {FWSSConfigModule} from "../../src/modules/FWSSConfigModule.sol";
import {IFWSSConfig} from "../../src/interfaces/IFWSSConfig.sol";
import {Errors} from "../../src/Errors.sol";
import {FilecoinWarmStorageService} from "../../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../../src/FilecoinWarmStorageServiceStateView.sol";
import {MockERC20} from "../mocks/SharedMocks.sol";

/// @dev Populates the legacy layout through the same declarations used by all FWSS modules.
contract FWSSViewStorageInitializer is FWSSStorage {
    function initialize() external {
        maxProvingPeriod = 100;
        challengeWindowSize = 20;
        _filBeamControllerAddress = address(0xFA);
        for (uint256 id = 1; id <= 3; ++id) {
            dataSetInfo[id] = DataSetInfo({
                pdpRailId: id,
                cacheMissRailId: id + 10,
                cdnRailId: id + 20,
                payer: address(0xCA),
                payee: address(0xCB),
                serviceProvider: address(0xCC),
                commissionBps: 17,
                clientDataSetId: id + 30,
                pdpEndEpoch: id == 3 ? 900 : 0,
                providerId: 7,
                pendingOneTimePayments: 123,
                lifecycleReserveBalance: 456
            });
            _clientDataSets[address(0xCA)].push(id);
            _railToDataSet[id] = id;
            dataSetAuthorizer[id] = address(0xAD);
        }
        _clientNonces[address(0xCA)][9] = (uint256(123) << 128) | 1;
        approvedProviderIds.push(7);
        approvedProviderIds.push(42);
        approvedProviders[7] = true;
        approvedProviders[42] = true;
        dataSetMetadataKeys[1].push("short");
        dataSetMetadataKeys[1].push("empty");
        dataSetMetadataKeys[1].push("long");
        dataSetMetadata[1]["short"] = "abc";
        dataSetMetadata[1]["empty"] = "";
        dataSetMetadata[1]["long"] =
        "This is a metadata value longer than one storage word to exercise long string encoding.";
        _provingActivationEpoch[1] = 100;
        _provingActivationEpoch[3] = 100;
        provingDeadlines[1] = 200;
        _provenPeriods[1][0] = (1 << 0) | (1 << 2) | (uint256(1) << 255);
        _provenPeriods[1][1] = 1;
        _provenThisPeriod[3] = true;
        _nextUpgrade = PlannedUpgrade({nextImplementation: address(0xAC), afterEpoch: 999});
    }
}

contract FWSSViewModuleTest is Test {
    FWSSViewModule candidate;
    MockERC20 token;
    FilecoinWarmStorageServiceStateView legacy;

    function setUp() public {
        token = new MockERC20();
        FWSSViewModule implementation = new FWSSViewModule();
        FWSSViewStorageInitializer initializer = new FWSSViewStorageInitializer();
        MyERC1967Proxy proxy =
            new MyERC1967Proxy(address(initializer), abi.encodeCall(FWSSViewStorageInitializer.initialize, ()));
        candidate = FWSSViewModule(address(proxy));
        bytes4[] memory selectors = AbiCheats.getSelectors(vm, "out/FWSSViewModule.sol/FWSSViewModule.json");
        for (uint256 i = 0; i < selectors.length; i++) {
            _route(selectors[i], address(implementation));
        }
        ExtsloadModule rawReads = new ExtsloadModule();
        bytes4[] memory rawSelectors = AbiCheats.getSelectors(vm, "out/ExtsloadModule.sol/ExtsloadModule.json");
        for (uint256 i; i < rawSelectors.length; ++i) {
            _route(rawSelectors[i], address(rawReads));
        }
        FWSSConfigModule config = new FWSSConfigModule(address(0xB4), address(0xB5), token);
        _route(IFWSSConfig.usdfcTokenAddress.selector, address(config));
        address dispatcher = deployCode("lib/erc8167/out/Proxy.evm/Proxy.json");
        vm.store(address(proxy), ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(dispatcher))));
        legacy = new FilecoinWarmStorageServiceStateView(FilecoinWarmStorageService(address(candidate)));
    }

    function _route(bytes4 selector, address delegate) private {
        vm.store(address(candidate), ProxyStorage.delegateStorageKey(selector), bytes32(uint256(uint160(delegate))));
    }

    function same(bytes memory callData) internal view {
        (bool a, bytes memory x) = address(candidate).staticcall(callData);
        (bool b, bytes memory y) = address(legacy).staticcall(callData);
        assertTrue(a, "module read failed");
        assertTrue(b, "legacy read failed");
        assertEq(x, y, "return data parity");
    }

    function testDataSetBoundaries() public view {
        for (uint256 id; id <= 4; ++id) {
            same(abi.encodeWithSignature("getDataSet(uint256)", id));
            same(abi.encodeWithSignature("getDataSetStatus(uint256)", id));
        }
        assertEq(uint256(candidate.getDataSetStatus(1)), uint256(FilecoinWarmStorageService.DataSetStatus.Active));
        assertEq(uint256(candidate.getDataSetStatus(2)), uint256(FilecoinWarmStorageService.DataSetStatus.Inactive));
        assertEq(uint256(candidate.getDataSetStatus(3)), uint256(FilecoinWarmStorageService.DataSetStatus.Active));
        assertEq(uint256(candidate.getDataSetStatus(4)), uint256(FilecoinWarmStorageService.DataSetStatus.Inactive));
        FilecoinWarmStorageService.DataSetInfoView memory missing = candidate.getDataSet(4);
        assertEq(missing.dataSetId, 4);
        assertEq(missing.pdpRailId, 0);
        assertEq(missing.payer, address(0));
    }

    function testPaginationBoundaries() public view {
        uint256[6] memory bounds = [uint256(0), 1, 2, 3, 4, type(uint256).max];
        address[2] memory clients = [address(0xCA), address(0)];
        for (uint256 i; i < bounds.length; ++i) {
            for (uint256 j; j < bounds.length; ++j) {
                for (uint256 k; k < clients.length; ++k) {
                    same(
                        abi.encodeWithSignature(
                            "clientDataSets(address,uint256,uint256)", clients[k], bounds[i], bounds[j]
                        )
                    );
                    same(
                        abi.encodeWithSignature(
                            "getClientDataSets(address,uint256,uint256)", clients[k], bounds[i], bounds[j]
                        )
                    );
                }
                same(abi.encodeWithSignature("getApprovedProviders(uint256,uint256)", bounds[i], bounds[j]));
            }
        }
        uint256[] memory remaining = candidate.clientDataSets(address(0xCA), 1, 0);
        assertEq(remaining.length, 2);
        assertEq(remaining[0], 2);
        assertEq(remaining[1], 3);
    }

    function testMetadataBoundaries() public view {
        same(abi.encodeWithSignature("getAllDataSetMetadata(uint256)", 1));
        same(abi.encodeWithSignature("getAllDataSetMetadata(uint256)", 2));
        same(abi.encodeWithSignature("getDataSetMetadata(uint256,string)", 1, "short"));
        same(abi.encodeWithSignature("getDataSetMetadata(uint256,string)", 1, "empty"));
        same(abi.encodeWithSignature("getDataSetMetadata(uint256,string)", 1, "long"));
        same(abi.encodeWithSignature("getDataSetMetadata(uint256,string)", 1, "missing"));
        (bool exists, string memory value) = candidate.getDataSetMetadata(1, "empty");
        assertTrue(exists);
        assertEq(value, "");
        (exists, value) = candidate.getDataSetMetadata(1, "missing");
        assertFalse(exists);
        assertEq(value, "");
    }

    function testProvingBoundaries() public {
        uint256[9] memory epochs = [uint256(99), 100, 101, 199, 200, 201, 300, 301, 1000];
        for (uint256 i; i < epochs.length; ++i) {
            vm.roll(epochs[i]);
            same(abi.encodeWithSignature("getPDPConfig()"));
            for (uint256 id; id <= 3; ++id) {
                if (id == 0 || id == 2) {
                    vm.expectRevert(abi.encodeWithSelector(Errors.ProvingPeriodNotInitialized.selector, id));
                    candidate.nextPDPChallengeWindowStart(id);
                    vm.expectRevert(abi.encodeWithSelector(Errors.ProvingPeriodNotInitialized.selector, id));
                    legacy.nextPDPChallengeWindowStart(id);
                } else {
                    same(abi.encodeWithSignature("nextPDPChallengeWindowStart(uint256)", id));
                }
                same(abi.encodeWithSignature("hasBeenProvenRecently(uint256)", id));
            }
        }
        uint256[6] memory periods = [uint256(0), 1, 2, 254, 255, 256];
        for (uint256 i; i < periods.length; ++i) {
            same(abi.encodeWithSignature("provenPeriods(uint256,uint256)", 1, periods[i]));
            assertEq(candidate.provenPeriods(1, periods[i]), i != 1 && i != 3);
        }
        vm.roll(200);
        assertEq(candidate.nextPDPChallengeWindowStart(1), 280);
        vm.roll(201);
        assertEq(candidate.nextPDPChallengeWindowStart(1), 280);
        vm.roll(301);
        assertEq(candidate.nextPDPChallengeWindowStart(1), 380);
    }

    function testPriceCatalogueFollowsConfigRoute() public {
        assertEq(address(candidate.getPriceList().token), address(token));
        MockERC20 replacementToken = new MockERC20();
        FWSSConfigModule replacement = new FWSSConfigModule(address(0xB4), address(0xB5), replacementToken);
        _route(IFWSSConfig.usdfcTokenAddress.selector, address(replacement));
        assertEq(address(candidate.getPriceList().token), address(replacementToken));
        assertEq(address(legacy.getPriceList().token), address(replacementToken));
        same(abi.encodeWithSignature("getPriceList()"));
    }

    function testAllStateReadsWorkWithoutExtsloadRoutes() public {
        bytes[] memory calls = new bytes[](30);
        calls[0] = abi.encodeWithSignature("clientDataSets(address)", address(0xCA));
        calls[1] = abi.encodeWithSignature("clientDataSets(address,uint256,uint256)", address(0xCA), 0, 0);
        calls[2] = abi.encodeWithSignature("clientNonces(address,uint256)", address(0xCA), 9);
        calls[3] = abi.encodeWithSignature("filBeamControllerAddress()");
        calls[4] = abi.encodeWithSignature("getAllDataSetMetadata(uint256)", 1);
        calls[5] = abi.encodeWithSignature("getApprovedProviders(uint256,uint256)", 0, 0);
        calls[6] = abi.encodeWithSignature("getApprovedProvidersLength()");
        calls[7] = abi.encodeWithSignature("getClientDataSets(address)", address(0xCA));
        calls[8] = abi.encodeWithSignature("getClientDataSets(address,uint256,uint256)", address(0xCA), 0, 0);
        calls[9] = abi.encodeWithSignature("getClientDataSetsLength(address)", address(0xCA));
        calls[10] = abi.encodeWithSignature("getCurrentPricingRates()");
        calls[11] = abi.encodeWithSignature("getDataSet(uint256)", 1);
        calls[12] = abi.encodeWithSignature("getDataSetAuthorizer(uint256)", 1);
        calls[13] = abi.encodeWithSignature("getDataSetMetadata(uint256,string)", 1, "short");
        calls[14] = abi.encodeWithSignature("getDataSetPayerAndRailId(uint256)", 1);
        calls[15] = abi.encodeWithSignature("getDataSetSizeInBytes(uint256)", 1);
        calls[16] = abi.encodeWithSignature("getDataSetStatus(uint256)", 1);
        calls[17] = abi.encodeWithSignature("getPDPConfig()");
        calls[18] = abi.encodeWithSignature("getPriceList()");
        calls[19] = abi.encodeWithSignature("hasBeenProvenRecently(uint256)", 1);
        calls[20] = abi.encodeWithSignature("isProviderApproved(uint256)", 7);
        calls[21] = abi.encodeWithSignature("nextPDPChallengeWindowStart(uint256)", 1);
        calls[22] = abi.encodeWithSignature("provenPeriods(uint256,uint256)", 1, 0);
        calls[23] = abi.encodeWithSignature("provenThisPeriod(uint256)", 1);
        calls[24] = abi.encodeWithSignature("provingActivationEpoch(uint256)", 1);
        calls[25] = abi.encodeWithSignature("provingDeadline(uint256)", 1);
        calls[26] = abi.encodeWithSignature("railToDataSet(uint256)", 1);
        calls[27] = abi.encodeWithSignature("serviceCommissionBps()");
        calls[28] = abi.encodeWithSignature("service()");
        calls[29] = abi.encodeWithSignature("nextUpgrade()");
        assertEq(AbiCheats.getSelectors(vm, "out/FWSSViewModule.sol/FWSSViewModule.json").length, calls.length);
        bytes[] memory expected = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory result) = address(legacy).staticcall(calls[i]);
            assertTrue(success, "legacy baseline read failed");
            expected[i] = result;
        }
        _route(bytes4(keccak256("extsload(bytes32)")), address(0));
        _route(bytes4(keccak256("extsloadStruct(bytes32,uint256)")), address(0));
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory result) = address(candidate).staticcall(calls[i]);
            assertTrue(success, "view read requires an Extsload route");
            assertEq(result, expected[i], "direct storage read changed the result");
        }
        assertEq(address(candidate.service()), address(candidate));
        (address nextImplementation, uint96 afterEpoch) = candidate.nextUpgrade();
        assertEq(nextImplementation, address(0xAC));
        assertEq(afterEpoch, 999);
    }
}
