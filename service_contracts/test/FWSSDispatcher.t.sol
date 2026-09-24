// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC8167} from "@erc8167/interfaces/IERC8167.sol";
import {AbiCheats} from "@erc8167/lib/AbiCheats.sol";
import {ProxyStorage} from "@erc8167/lib/ProxyStorage.sol";
import {Migration, SetDelegateOperation, SetDelegateOperationLibrary} from "@erc8167/lib/Migration.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {MigrateModule} from "../src/modules/MigrateModule.sol";
import {ProviderManagementModule} from "../src/modules/ProviderManagementModule.sol";
import {LibAccessControl} from "../src/lib/LibAccessControl.sol";
import {NEXT_UPGRADE_SLOT} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {MockERC20} from "./mocks/SharedMocks.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";

contract CallContextFixture {
    function record(bytes calldata payload) external payable returns (address, uint256, bytes memory) {
        assembly { sstore(90, 0x1234) }
        return (msg.sender, msg.value, payload);
    }

    function value() external view returns (uint256 result) {
        assembly { result := sload(90) }
    }

    function fail() external pure {
        revert Failure(0x1234);
    }

    error Failure(uint256 value);
}

contract SelectorsFixture {
    function selectors() external pure returns (bytes4[] memory result) {
        result = new bytes4[](6);
        result[0] = IERC8167.implementation.selector;
        result[1] = IERC8167.selectors.selector;
        result[2] = MigrateModule.announceMigration.selector;
        result[3] = MigrateModule.migrate.selector;
        result[4] = ProviderManagementModule.addApprovedProvider.selector;
        result[5] = ProviderManagementModule.removeApprovedProvider.selector;
    }
}

contract RevertingMigrationFixture {
    error MigrationFailed();

    fallback() external {
        ProxyStorage.get().delegates[IERC8167.implementation.selector] = address(0xDEAD);
        revert MigrationFailed();
    }
}

contract FWSSDispatcherTest is Test {
    bytes32 private constant DELEGATES_SLOT = 0xf27774d37a8b3bf2306f60b561e4e8ec22cfb23796f1f777608c0e466ef52600;
    bytes32 private constant OWNER_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal dispatcher;
    address internal introspection;
    MigrateModule internal migrateModule;
    ProviderManagementModule internal providerModule;

    function setUp() public {
        dispatcher = deployCode("lib/erc8167/out/Proxy.evm/Proxy.json");
        introspection = deployCode("lib/erc8167/out/Implementation.evm/Implementation.json");
        migrateModule = new MigrateModule();
        providerModule = new ProviderManagementModule();
    }

    function _route(address proxy, bytes4 selector, address target) internal {
        vm.store(proxy, keccak256(abi.encode(selector, DELEGATES_SLOT)), bytes32(uint256(uint160(target))));
    }

    function _owner(address proxy) internal {
        vm.store(proxy, OWNER_SLOT, bytes32(uint256(uint160(address(this)))));
    }

    function _rawProxy() internal returns (address proxy) {
        proxy = deployCode("lib/erc8167/out/Proxy.evm/Proxy.json");
        _owner(proxy);
    }

    function _plan(address proxy) internal view returns (address target, uint96 epoch) {
        uint256 packed = uint256(vm.load(proxy, NEXT_UPGRADE_SLOT));
        target = address(uint160(packed));
        epoch = uint96(packed >> 160);
    }

    function _migration(address proxy) internal {
        _route(proxy, MigrateModule.announceMigration.selector, address(migrateModule));
        _route(proxy, MigrateModule.migrate.selector, address(migrateModule));
    }

    function testRawDispatcherPreservesFullCallContextAndStorage() public {
        address proxy = _rawProxy();
        CallContextFixture fixture = new CallContextFixture();
        _route(proxy, CallContextFixture.record.selector, address(fixture));
        _route(proxy, CallContextFixture.value.selector, address(fixture));
        bytes memory payload = new bytes(300);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = bytes1(uint8(i));
        }
        vm.deal(address(this), 1 ether);

        (address sender, uint256 amount, bytes memory returned) = CallContextFixture(proxy).record{value: 12}(payload);
        assertEq(sender, address(this));
        assertEq(amount, 12);
        assertEq(returned, payload);
        assertEq(CallContextFixture(proxy).value(), 0x1234);
        assertEq(CallContextFixture(address(fixture)).value(), 0);
    }

    function testRawDispatcherMatchesUpstreamArtifactAndSizeLimit() public view {
        bytes memory upstream = vm.getDeployedCode("lib/erc8167/out/Proxy.evm/Proxy.json");
        assertEq(dispatcher.code, upstream);
        assertLe(dispatcher.code.length, 24_576);
    }

    function testRawDispatcherBubblesExactRevertBytes() public {
        address proxy = _rawProxy();
        _route(proxy, CallContextFixture.fail.selector, address(new CallContextFixture()));
        vm.expectRevert(abi.encodeWithSelector(CallContextFixture.Failure.selector, 0x1234));
        CallContextFixture(proxy).fail();
    }

    function testRawDispatcherUnknownShortAndEmptyCalldata() public {
        address proxy = _rawProxy();
        bytes[] memory calls = new bytes[](3);
        calls[0] = hex"deadbeef";
        calls[1] = hex"de";
        calls[2] = hex"";
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = 0xdeadbeef;
        selectors[1] = 0xde000000;
        selectors[2] = 0x00000000;
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory result) = proxy.call(calls[i]);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(IERC8167.FunctionNotFound.selector, selectors[i]));
        }
    }

    function testMigrationOwnerDelayReplacementConsumptionAndReplay() public {
        address proxy = _rawProxy();
        _migration(proxy);
        address first = _createMigration(bytes4(0));
        address second = _createMigration(bytes4(0));
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(LibAccessControl.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        MigrateModule(proxy).announceMigration(address(first), 0);
        MigrateModule(proxy).announceMigration(address(first), 0);
        (address target, uint96 epoch) = _plan(proxy);
        assertEq(target, address(first));
        assertEq(epoch, block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(MigrateModule.MigrationNotReady.selector, epoch));
        MigrateModule(proxy).migrate(address(first));
        vm.expectRevert(abi.encodeWithSelector(MigrateModule.MigrationNotAnnounced.selector, address(second)));
        MigrateModule(proxy).migrate(address(second));
        MigrateModule(proxy).announceMigration(address(second), 2);
        vm.roll(block.number + 2);
        MigrateModule(proxy).migrate(address(second));
        (target, epoch) = _plan(proxy);
        assertEq(target, address(0));
        assertEq(epoch, 0);
        assertEq(IERC8167(proxy).implementation(IERC8167.implementation.selector), introspection);
        vm.expectRevert(abi.encodeWithSelector(MigrateModule.MigrationNotAnnounced.selector, address(second)));
        MigrateModule(proxy).migrate(address(second));
    }

    function testMigrationRejectsInvalidTargetAndUnauthorizedExecution() public {
        address proxy = _rawProxy();
        _migration(proxy);
        vm.expectRevert(abi.encodeWithSelector(MigrateModule.InvalidMigration.selector, address(0x1234)));
        MigrateModule(proxy).announceMigration(address(0x1234), 1);
        address fixture = _createMigration(bytes4(0));
        MigrateModule(proxy).announceMigration(address(fixture), 1);
        vm.roll(block.number + 1);
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(LibAccessControl.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        MigrateModule(proxy).migrate(address(fixture));
        (address target,) = _plan(proxy);
        assertEq(target, address(fixture));
    }

    function testMigrationRevertRollsBackPlanAndRouteWrites() public {
        address proxy = _rawProxy();
        _migration(proxy);
        RevertingMigrationFixture fixture = new RevertingMigrationFixture();
        MigrateModule(proxy).announceMigration(address(fixture), 1);
        vm.roll(block.number + 1);
        vm.expectRevert(RevertingMigrationFixture.MigrationFailed.selector);
        MigrateModule(proxy).migrate(address(fixture));
        (address target, uint96 epoch) = _plan(proxy);
        assertEq(target, address(fixture));
        assertEq(epoch, block.number);
        assertEq(vm.load(proxy, keccak256(abi.encode(IERC8167.implementation.selector, DELEGATES_SLOT))), bytes32(0));
    }

    function testProviderModuleDoesNotExposeOwnerFunctions() public {
        address proxy = _rawProxy();
        _route(proxy, ProviderManagementModule.addApprovedProvider.selector, address(providerModule));
        ProviderManagementModule(proxy).addApprovedProvider(42);
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(LibAccessControl.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        ProviderManagementModule(proxy).addApprovedProvider(43);
        assertEq(vm.load(proxy, OWNER_SLOT), bytes32(uint256(uint160(address(this)))));
    }

    function testMigrationRoutesMatchCompiledModuleAbis() public {
        address proxy = _rawProxy();
        _migration(proxy);
        address migration = _createMigration(bytes4(0));
        MigrateModule(proxy).announceMigration(migration, 0);
        vm.roll(block.number + 1);
        MigrateModule(proxy).migrate(migration);

        bytes4[] memory migrationSelectors = AbiCheats.getSelectors(vm, "out/MigrateModule.sol/MigrateModule.json");
        bytes4[] memory providerSelectors =
            AbiCheats.getSelectors(vm, "out/ProviderManagementModule.sol/ProviderManagementModule.json");
        bytes4 viewSelector = bytes4(keccak256("viewContractAddress()"));
        uint256 routedSelectors = 2; // Upstream implementation() and the selectors() fixture.
        for (uint256 i; i < migrationSelectors.length; ++i) {
            assertEq(IERC8167(proxy).implementation(migrationSelectors[i]), address(migrateModule));
            ++routedSelectors;
        }
        for (uint256 i; i < providerSelectors.length; ++i) {
            // Shared storage currently exports this getter from every business facet.
            if (providerSelectors[i] == viewSelector) continue;
            assertEq(IERC8167(proxy).implementation(providerSelectors[i]), address(providerModule));
            ++routedSelectors;
        }
        assertEq(IERC8167(proxy).implementation(viewSelector), address(0));
        assertEq(IERC8167(proxy).selectors().length, routedSelectors);
    }

    function _createMigration(bytes4 omittedSelector) internal returns (address) {
        SelectorsFixture selectorsModule = new SelectorsFixture();
        SetDelegateOperation[] memory operations = new SetDelegateOperation[](6);
        operations[0] = SetDelegateOperation({selector: IERC8167.implementation.selector, delegate: introspection});
        operations[1] =
            SetDelegateOperation({selector: IERC8167.selectors.selector, delegate: address(selectorsModule)});
        operations[2] = SetDelegateOperation({
            selector: MigrateModule.announceMigration.selector, delegate: address(migrateModule)
        });
        operations[3] =
            SetDelegateOperation({selector: MigrateModule.migrate.selector, delegate: address(migrateModule)});
        operations[4] = SetDelegateOperation({
            selector: ProviderManagementModule.addApprovedProvider.selector, delegate: address(providerModule)
        });
        operations[5] = SetDelegateOperation({
            selector: ProviderManagementModule.removeApprovedProvider.selector, delegate: address(providerModule)
        });

        SetDelegateOperationLibrary.validate(operations);
        for (uint256 i; i < operations.length; ++i) {
            if (operations[i].selector == omittedSelector) operations[i].delegate = address(0);
        }
        return Migration.createMigration(operations);
    }

    function _newMonolith(MockERC20 token) internal returns (FilecoinWarmStorageService) {
        return new FilecoinWarmStorageService(
            address(0x11),
            address(0x12),
            token,
            address(0x13),
            ServiceProviderRegistry(address(0x14)),
            SessionKeyRegistry(address(0x15)),
            4
        );
    }

    function _realLegacy()
        internal
        returns (FilecoinWarmStorageService service, FilecoinWarmStorageServiceStateView viewContract, MockERC20 token)
    {
        token = new MockERC20();
        FilecoinWarmStorageService implementation = _newMonolith(token);
        service = FilecoinWarmStorageService(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(FilecoinWarmStorageService.initialize, (uint64(2880), uint256(60), address(0x16)))
                )
            )
        );
        viewContract = new FilecoinWarmStorageServiceStateView(service);
        service.setViewContract(address(viewContract));
        service.configureProvingPeriod(3000, 61);
    }

    function _intermediate(FilecoinWarmStorageService service, MockERC20 token)
        internal
        returns (FilecoinWarmStorageService implementation)
    {
        implementation = _newMonolith(token);
        assertGt(address(implementation).code.length, 3000);
        service.announceUpgradePlan(address(implementation), 0);
        (, uint96 epoch) = _plan(address(service));
        vm.roll(epoch);
        service.upgradeToAndCall(address(implementation), "");
        assertEq(address(uint160(uint256(vm.load(address(service), IMPLEMENTATION_SLOT)))), address(implementation));
    }

    function _assertDispatcherRoutes(address proxy) internal view {
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), dispatcher);
        assertEq(IERC8167(proxy).implementation(MigrateModule.migrate.selector), address(migrateModule));
        assertEq(
            IERC8167(proxy).implementation(ProviderManagementModule.addApprovedProvider.selector),
            address(providerModule)
        );
        bytes4[] memory exported = IERC8167(proxy).selectors();
        assertEq(exported.length, 6);
        for (uint256 i; i < exported.length; ++i) {
            assertTrue(IERC8167(proxy).implementation(exported[i]) != address(0));
            assertTrue(exported[i] != bytes4(keccak256("owner()")));
            assertTrue(exported[i] != bytes4(keccak256("transferOwnership(address)")));
        }
    }

    function testRealMonolithUpgradeThenAtomicDispatcherTransition() public {
        (FilecoinWarmStorageService service, FilecoinWarmStorageServiceStateView viewContract, MockERC20 token) =
            _realLegacy();
        address proxy = address(service);
        bytes32 ownerBefore = vm.load(proxy, OWNER_SLOT);
        bytes32 periodBefore = vm.load(proxy, bytes32(uint256(0)));
        bytes32 windowBefore = vm.load(proxy, bytes32(uint256(1)));
        bytes32 viewBefore = vm.load(proxy, bytes32(uint256(17)));
        _intermediate(service, token);
        assertEq(vm.load(proxy, OWNER_SLOT), ownerBefore);
        assertEq(vm.load(proxy, bytes32(uint256(0))), periodBefore);
        assertEq(vm.load(proxy, bytes32(uint256(1))), windowBefore);
        assertEq(vm.load(proxy, bytes32(uint256(17))), viewBefore);
        assertEq(service.owner(), address(this));
        assertEq(service.viewContractAddress(), address(viewContract));
        (uint64 provingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        assertEq(provingPeriod, 3000);
        assertEq(challengeWindow, 61);

        address migration = _createMigration(bytes4(0));
        service.announceDispatcherUpgrade(dispatcher, migration, 0);
        (address announced, uint96 afterEpoch) = viewContract.nextUpgrade();
        assertEq(announced, dispatcher);
        assertEq(afterEpoch, block.number + 1);
        vm.roll(afterEpoch);
        service.upgradeToDispatcher(dispatcher, migration);

        _assertDispatcherRoutes(proxy);
        assertEq(vm.load(proxy, OWNER_SLOT), ownerBefore);
        assertEq(vm.load(proxy, bytes32(uint256(0))), periodBefore);
        assertEq(vm.load(proxy, bytes32(uint256(1))), windowBefore);
        assertEq(vm.load(proxy, bytes32(uint256(17))), viewBefore);
        (address pending, uint96 readyAt) = _plan(proxy);
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
        ProviderManagementModule(proxy).addApprovedProvider(42);
        assertEq(uint256(vm.load(proxy, keccak256(abi.encode(uint256(42), uint256(15))))), 1);
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(LibAccessControl.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        ProviderManagementModule(proxy).addApprovedProvider(43);
    }

    function testNormalAnnouncementRejectsSmallRawDispatcherButIntermediatePasses() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        assertLe(dispatcher.code.length, 3000);
        vm.expectRevert();
        service.announceUpgradePlan(dispatcher, 0);
        _intermediate(service, token);
    }

    function testDispatcherAnnouncementValidatesTargetsAndOwner() public {
        (FilecoinWarmStorageService service,,) = _realLegacy();
        address migration = _createMigration(bytes4(0));
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(LibAccessControl.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        service.announceDispatcherUpgrade(dispatcher, migration, 1);
        vm.expectRevert(
            abi.encodeWithSelector(FilecoinWarmStorageService.InvalidDispatcherTarget.selector, address(0x1234))
        );
        service.announceDispatcherUpgrade(address(0x1234), migration, 1);
        vm.expectRevert(
            abi.encodeWithSelector(FilecoinWarmStorageService.InvalidDispatcherTarget.selector, address(0x1234))
        );
        service.announceDispatcherUpgrade(dispatcher, address(0x1234), 1);
        vm.expectRevert(abi.encodeWithSelector(FilecoinWarmStorageService.InvalidDispatcherTarget.selector, address(0)));
        service.announceDispatcherUpgrade(dispatcher, address(0), 1);
        (address target, uint96 epoch) = _plan(address(service));
        assertEq(target, address(0));
        assertEq(epoch, 0);
    }

    function testDispatcherTransitionChecksDelayTargetsAndOwner() public {
        (FilecoinWarmStorageService service,,) = _realLegacy();
        address migration = _createMigration(bytes4(0));
        address wrongMigration = _createMigration(bytes4(0));
        service.announceDispatcherUpgrade(dispatcher, migration, 2);
        vm.expectRevert();
        service.upgradeToDispatcher(dispatcher, migration);
        vm.roll(block.number + 2);
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(LibAccessControl.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        service.upgradeToDispatcher(dispatcher, migration);
        vm.expectRevert(FilecoinWarmStorageService.DispatcherMigrationMismatch.selector);
        service.upgradeToDispatcher(dispatcher, wrongMigration);
        vm.expectRevert();
        service.upgradeToDispatcher(address(0x1234), migration);
        (address target,) = _plan(address(service));
        assertEq(target, dispatcher);
        service.upgradeToDispatcher(dispatcher, migration);
        _assertDispatcherRoutes(address(service));
    }

    function testDirectImplementationCannotUpgradeToDispatcher() public {
        MockERC20 token = new MockERC20();
        FilecoinWarmStorageService implementation = _newMonolith(token);
        address migration = _createMigration(bytes4(0));
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        implementation.upgradeToDispatcher(dispatcher, migration);
    }

    function testRevertingMigrationRollsBackPlanAndRoutes() public {
        (FilecoinWarmStorageService service,,) = _realLegacy();
        address proxy = address(service);
        address original = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        RevertingMigrationFixture migration = new RevertingMigrationFixture();
        service.announceDispatcherUpgrade(dispatcher, address(migration), 0);
        vm.roll(block.number + 1);
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(RevertingMigrationFixture.MigrationFailed.selector);
            service.upgradeToDispatcher(dispatcher, address(migration));
            (address target, uint96 epoch) = _plan(address(service));
            assertEq(target, dispatcher);
            assertEq(epoch, block.number);
            assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), original);
            assertEq(
                vm.load(proxy, keccak256(abi.encode(IERC8167.implementation.selector, DELEGATES_SLOT))), bytes32(0)
            );
        }
    }

    function testMissingCriticalRouteRollsBackPlanAndRoutes() public {
        (FilecoinWarmStorageService service,,) = _realLegacy();
        address proxy = address(service);
        address original = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        address migration = _createMigration(IERC8167.selectors.selector);
        service.announceDispatcherUpgrade(dispatcher, migration, 0);
        vm.roll(block.number + 1);
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    FilecoinWarmStorageService.MissingDispatcherDelegate.selector, IERC8167.selectors.selector
                )
            );
            service.upgradeToDispatcher(dispatcher, migration);
            (address target, uint96 epoch) = _plan(address(service));
            assertEq(target, dispatcher);
            assertEq(epoch, block.number);
            assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), original);
            assertEq(
                vm.load(proxy, keccak256(abi.encode(IERC8167.implementation.selector, DELEGATES_SLOT))), bytes32(0)
            );
        }
    }

    function testMissingAnnouncementRouteRevertsWholeTransition() public {
        (FilecoinWarmStorageService service,,) = _realLegacy();
        address proxy = address(service);
        address original = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        address migration = _createMigration(MigrateModule.announceMigration.selector);
        service.announceDispatcherUpgrade(dispatcher, migration, 0);
        vm.roll(block.number + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FilecoinWarmStorageService.MissingDispatcherDelegate.selector, MigrateModule.announceMigration.selector
            )
        );
        service.upgradeToDispatcher(dispatcher, migration);
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), original);
        (address target,) = _plan(address(service));
        assertEq(target, dispatcher);
    }

    function testNormalAnnouncementReplacesDispatcherPlan() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address migration = _createMigration(bytes4(0));
        FilecoinWarmStorageService next = _newMonolith(token);
        service.announceDispatcherUpgrade(dispatcher, migration, 0);
        service.announceUpgradePlan(address(next), 0);
        vm.roll(block.number + 1);
        vm.expectRevert(FilecoinWarmStorageService.DispatcherMigrationMismatch.selector);
        service.upgradeToDispatcher(dispatcher, migration);
        service.upgradeToAndCall(address(next), "");
        assertEq(address(uint160(uint256(vm.load(address(service), IMPLEMENTATION_SLOT)))), address(next));
    }

    function testDispatcherAnnouncementReplacesNormalPlanAndGuardsUUPS() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        FilecoinWarmStorageService next = _newMonolith(token);
        address migration = _createMigration(bytes4(0));
        service.announceUpgradePlan(address(next), 0);
        service.announceDispatcherUpgrade(address(next), migration, 0);
        vm.roll(block.number + 1);
        vm.expectRevert(FilecoinWarmStorageService.DispatcherUpgradePending.selector);
        service.upgradeToAndCall(address(next), "");
        service.announceDispatcherUpgrade(dispatcher, migration, 0);
        (, uint96 readyAt) = _plan(address(service));
        vm.roll(readyAt);
        vm.expectRevert(FilecoinWarmStorageService.DispatcherUpgradePending.selector);
        service.upgradeToAndCall(dispatcher, "");
        service.upgradeToDispatcher(dispatcher, migration);
        _assertDispatcherRoutes(address(service));
    }

    function testDispatcherReplacementBindsNewMigrationAndResetsDelay() public {
        (FilecoinWarmStorageService service,,) = _realLegacy();
        address firstMigration = _createMigration(bytes4(0));
        address secondMigration = _createMigration(bytes4(0));
        service.announceDispatcherUpgrade(dispatcher, firstMigration, 1);
        vm.roll(block.number + 1);
        service.announceDispatcherUpgrade(dispatcher, secondMigration, 3);
        (address target, uint96 readyAt) = _plan(address(service));
        assertEq(target, dispatcher);
        assertEq(readyAt, block.number + 3);
        vm.expectRevert(FilecoinWarmStorageService.DispatcherMigrationMismatch.selector);
        service.upgradeToDispatcher(dispatcher, firstMigration);
        vm.expectRevert();
        service.upgradeToDispatcher(dispatcher, secondMigration);
        vm.roll(readyAt - 1);
        vm.expectRevert();
        service.upgradeToDispatcher(dispatcher, secondMigration);
        vm.roll(readyAt);
        service.upgradeToDispatcher(dispatcher, secondMigration);
        _assertDispatcherRoutes(address(service));
    }

    function testTransferredOwnerControlsDispatcherTransitionAndProviderModule() public {
        (FilecoinWarmStorageService service,,) = _realLegacy();
        address migration = _createMigration(bytes4(0));
        service.transferOwnership(address(0xB0B));
        vm.prank(address(0xB0B));
        service.announceDispatcherUpgrade(dispatcher, migration, 0);
        vm.roll(block.number + 1);
        vm.prank(address(0xB0B));
        service.upgradeToDispatcher(dispatcher, migration);
        vm.expectRevert(abi.encodeWithSelector(LibAccessControl.OwnableUnauthorizedAccount.selector, address(this)));
        ProviderManagementModule(address(service)).addApprovedProvider(43);
        vm.prank(address(0xB0B));
        ProviderManagementModule(address(service)).addApprovedProvider(43);
    }
}
