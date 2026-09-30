// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {IERC8167} from "@erc8167/interfaces/IERC8167.sol";
import {Migrate} from "@erc8167/interfaces/Migrate.sol";
import {ProxyStorage} from "@erc8167/lib/ProxyStorage.sol";
import {Migration, SetDelegateOperation, SetDelegateOperationLibrary} from "@erc8167/lib/Migration.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {FWSSMigrateModule} from "../src/modules/FWSSMigrateModule.sol";
import {OwnershipModule} from "../src/modules/OwnershipModule.sol";
import {FWSSProviderManagementModule} from "../src/modules/FWSSProviderManagementModule.sol";
import {FWSSViewContractModule} from "../src/modules/FWSSViewContractModule.sol";
import {FWSSOwnable} from "../src/lib/FWSSOwnable.sol";
import {LibUpgradeRoutes} from "../src/lib/LibUpgradeRoutes.sol";
import {NEXT_UPGRADE_SLOT} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {MockERC20} from "./mocks/SharedMocks.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {JosukeFacetSet} from "./helpers/JosukeFacetSet.sol";

contract CallContextFixture {
    function record(bytes calldata payload) external payable returns (address, uint256, bytes memory) {
        assembly { sstore(90, 0x1234) }
        return (msg.sender, msg.value, payload);
    }

    function value() external view returns (uint256 result) {
        assembly { result := sload(90) }
    }
}

contract RevertingMigrationFixture {
    error MigrationFailed();

    fallback() external {
        ProxyStorage.get().delegates[IERC8167.implementation.selector] = address(0xDEAD);
        revert MigrationFailed();
    }
}

/// @dev Replaces the ERC-1967 implementation instead of changing routes.
contract DispatcherSwapMigrationFixture {
    fallback() external {
        StorageSlot.getAddressSlot(ERC1967Utils.IMPLEMENTATION_SLOT).value = address(0xBEEF);
    }
}

/// @dev Runs in the proxy's storage context and calls back into the proxy, as a hostile migration would.
contract ReentrantMigrationFixture {
    bytes4 private immutable SELECTOR;
    address private immutable SELF;

    constructor(bytes4 selector) {
        SELECTOR = selector;
        SELF = address(this);
    }

    fallback() external {
        bytes memory data = SELECTOR == Migrate.migrate.selector
            ? abi.encodeWithSelector(SELECTOR, SELF)
            : abi.encodeWithSelector(SELECTOR);
        (bool ok, bytes memory result) = address(this).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

contract FWSSDispatcherTest is JosukeFacetSet {
    bytes32 private constant DELEGATES_SLOT = 0xf27774d37a8b3bf2306f60b561e4e8ec22cfb23796f1f777608c0e466ef52600;
    bytes32 private constant OWNER_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    string private constant V1_4_0_MAINNET = "test/fixtures/fwss-v1.4.0-mainnet.json";

    address internal dispatcher;
    MockERC20 internal usdfc;
    FWSSMigrateModule internal migrateModule;
    uint256 private legacyProxies;

    // Routes installed by the latest _createMigration.
    bytes4[] internal exportedSelectors;
    mapping(bytes4 selector => address delegate) internal routedTo;

    function setUp() public {
        dispatcher = deployCode("lib/erc8167/out/Proxy.evm/Proxy.json");
        usdfc = new MockERC20();
        migrateModule = new FWSSMigrateModule();
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
        _route(proxy, FWSSMigrateModule.announceMigration.selector, address(migrateModule));
        _route(proxy, FWSSMigrateModule.migrate.selector, address(migrateModule));
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

    function testMigrationOwnerDelayReplacementConsumptionAndReplay() public {
        address proxy = _rawProxy();
        _migration(proxy);
        address first = _createMigration(bytes4(0));
        address second = _createMigration(bytes4(0));
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        FWSSMigrateModule(proxy).announceMigration(address(first), 0);
        FWSSMigrateModule(proxy).announceMigration(address(first), 0);
        (address target, uint96 epoch) = _plan(proxy);
        assertEq(target, address(first));
        assertEq(epoch, block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(FWSSMigrateModule.MigrationNotReady.selector, epoch));
        FWSSMigrateModule(proxy).migrate(address(first));
        vm.expectRevert(abi.encodeWithSelector(FWSSMigrateModule.MigrationNotAnnounced.selector, address(second)));
        FWSSMigrateModule(proxy).migrate(address(second));
        FWSSMigrateModule(proxy).announceMigration(address(second), 2);
        vm.roll(block.number + 2);
        FWSSMigrateModule(proxy).migrate(address(second));
        (target, epoch) = _plan(proxy);
        assertEq(target, address(0));
        assertEq(epoch, 0);
        assertEq(
            IERC8167(proxy).implementation(IERC8167.implementation.selector), routedTo[IERC8167.implementation.selector]
        );
        vm.expectRevert(abi.encodeWithSelector(FWSSMigrateModule.MigrationNotAnnounced.selector, address(second)));
        FWSSMigrateModule(proxy).migrate(address(second));
    }

    function testMigrationRejectsInvalidTargetAndUnauthorizedExecution() public {
        address proxy = _rawProxy();
        _migration(proxy);
        vm.expectRevert(abi.encodeWithSelector(FWSSMigrateModule.InvalidMigration.selector, address(0x1234)));
        FWSSMigrateModule(proxy).announceMigration(address(0x1234), 1);
        address fixture = _createMigration(bytes4(0));
        FWSSMigrateModule(proxy).announceMigration(address(fixture), 1);
        vm.roll(block.number + 1);
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        FWSSMigrateModule(proxy).migrate(address(fixture));
        (address target,) = _plan(proxy);
        assertEq(target, address(fixture));
    }

    function testMigrationRevertRollsBackPlanAndRouteWrites() public {
        address proxy = _rawProxy();
        _migration(proxy);
        RevertingMigrationFixture fixture = new RevertingMigrationFixture();
        FWSSMigrateModule(proxy).announceMigration(address(fixture), 1);
        vm.roll(block.number + 1);
        vm.expectRevert(RevertingMigrationFixture.MigrationFailed.selector);
        FWSSMigrateModule(proxy).migrate(address(fixture));
        (address target, uint96 epoch) = _plan(proxy);
        assertEq(target, address(fixture));
        assertEq(epoch, block.number);
        assertEq(vm.load(proxy, keccak256(abi.encode(IERC8167.implementation.selector, DELEGATES_SLOT))), bytes32(0));
    }

    function testMigrationThatDropsUpgradeRouteReverts() public {
        bytes4[4] memory critical = [
            IERC8167.implementation.selector,
            IERC8167.selectors.selector,
            FWSSMigrateModule.announceMigration.selector,
            FWSSMigrateModule.migrate.selector
        ];
        for (uint256 i; i < critical.length; ++i) {
            address proxy = _rawProxy();
            _migration(proxy);
            address migration = _createMigration(critical[i]);
            FWSSMigrateModule(proxy).announceMigration(migration, 0);
            (, uint96 readyAt) = _plan(proxy);
            vm.roll(readyAt);

            vm.expectRevert(abi.encodeWithSelector(LibUpgradeRoutes.MissingUpgradeRoute.selector, critical[i]));
            FWSSMigrateModule(proxy).migrate(migration);
            (address target, uint96 epoch) = _plan(proxy);
            assertEq(target, migration);
            assertEq(epoch, readyAt);
            assertEq(
                vm.load(proxy, keccak256(abi.encode(FWSSMigrateModule.migrate.selector, DELEGATES_SLOT))),
                bytes32(uint256(uint160(address(migrateModule))))
            );
        }
    }

    function testMigrationCannotRouteUpgradesToTheDispatcher() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address proxy = address(service);
        _transition(service, token);

        SetDelegateOperation[] memory routes = new SetDelegateOperation[](1);
        routes[0] = SetDelegateOperation({selector: FWSSMigrateModule.migrate.selector, delegate: dispatcher});
        address migration = Migration.createMigration(routes);
        FWSSMigrateModule(proxy).announceMigration(migration, 0);
        vm.roll(block.number + 1);

        vm.expectRevert(
            abi.encodeWithSelector(LibUpgradeRoutes.MissingUpgradeRoute.selector, FWSSMigrateModule.migrate.selector)
        );
        FWSSMigrateModule(proxy).migrate(migration);
    }

    function testMigrationCannotReplaceTheDispatcher() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address proxy = address(service);
        _transition(service, token);

        DispatcherSwapMigrationFixture migration = new DispatcherSwapMigrationFixture();
        FWSSMigrateModule(proxy).announceMigration(address(migration), 0);
        (, uint96 readyAt) = _plan(proxy);
        vm.roll(readyAt);

        vm.expectRevert(abi.encodeWithSelector(FWSSMigrateModule.DispatcherChanged.selector, address(0xBEEF)));
        FWSSMigrateModule(proxy).migrate(address(migration));
        assertEq(_implementation(proxy), dispatcher);
        (address target, uint96 epoch) = _plan(proxy);
        assertEq(target, address(migration));
        assertEq(epoch, readyAt);
    }

    function testMigrationCannotReenterMigrate() public {
        address proxy = _rawProxy();
        _migration(proxy);
        ReentrantMigrationFixture migration = new ReentrantMigrationFixture(Migrate.migrate.selector);
        FWSSMigrateModule(proxy).announceMigration(address(migration), 0);
        (, uint96 readyAt) = _plan(proxy);
        vm.roll(readyAt);

        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, proxy));
        FWSSMigrateModule(proxy).migrate(address(migration));
        (address target, uint96 epoch) = _plan(proxy);
        assertEq(target, address(migration));
        assertEq(epoch, readyAt);
    }

    function testMigrationInstallsJosukeFacetSet() public {
        address proxy = _rawProxy();
        _migration(proxy);
        address migration = _createMigration(bytes4(0));
        FWSSMigrateModule(proxy).announceMigration(migration, 0);
        vm.roll(block.number + 1);
        FWSSMigrateModule(proxy).migrate(migration);

        _assertFacetRoutes(proxy);
    }

    function _createMigration(bytes4 omittedSelector) internal returns (address) {
        SetDelegateOperation[] memory routes = _deployFacetRoutes(_resolveFacets(MAINNET_INDEX));
        SetDelegateOperationLibrary.validate(routes);

        delete exportedSelectors;
        for (uint256 i; i < routes.length; ++i) {
            exportedSelectors.push(routes[i].selector);
            routedTo[routes[i].selector] = routes[i].delegate;
            if (routes[i].selector == omittedSelector) routes[i].delegate = address(0);
        }

        return Migration.createMigration(routes);
    }

    function _newMonolith(MockERC20 token) internal returns (FilecoinWarmStorageService) {
        return _newImplementation(token, address(0), address(0));
    }

    function _newIntermediate(MockERC20 token, address migration) internal returns (FilecoinWarmStorageService) {
        return _newImplementation(token, dispatcher, migration);
    }

    function _newImplementation(MockERC20 token, address dispatcher_, address migration)
        internal
        returns (FilecoinWarmStorageService)
    {
        return new FilecoinWarmStorageService(
            address(0x11),
            address(0x12),
            token,
            address(0x13),
            ServiceProviderRegistry(address(0x14)),
            SessionKeyRegistry(address(0x15)),
            4,
            dispatcher_,
            migration
        );
    }

    /// @dev A proxy running the deployed mainnet v1.4.0 proxy and implementation bytecode, not a rebuild.
    function _realLegacy()
        internal
        returns (FilecoinWarmStorageService service, FilecoinWarmStorageServiceStateView viewContract, MockERC20 token)
    {
        token = usdfc;
        string memory fixture = vm.readFile(V1_4_0_MAINNET);

        // Its UUPS onlyProxy check compares the implementation slot with its own mainnet address.
        address implementation = vm.parseJsonAddress(fixture, ".implementation.address");
        vm.etch(implementation, vm.parseJsonBytes(fixture, ".implementation.code"));

        address proxy = address(uint160(uint256(keccak256(abi.encode(V1_4_0_MAINNET, ++legacyProxies)))));
        vm.etch(proxy, vm.parseJsonBytes(fixture, ".proxy.code"));
        vm.store(proxy, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));

        service = FilecoinWarmStorageService(proxy);
        service.initialize(2880, 60, address(0x16));
        viewContract = new FilecoinWarmStorageServiceStateView(service);
        service.setViewContract(address(viewContract));
        service.configureProvingPeriod(3000, 61);
    }

    /// @dev Announces the intermediate through the ordinary delayed plan and returns the ready epoch.
    function _announce(FilecoinWarmStorageService service, address intermediate) internal returns (uint96 epoch) {
        service.announceUpgradePlan(intermediate, 0);
        (, epoch) = _plan(address(service));
    }

    function _transitionData() internal pure returns (bytes memory) {
        return abi.encodeCall(FilecoinWarmStorageService.completeDispatcherTransition, ());
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _transition(FilecoinWarmStorageService service, MockERC20 token)
        internal
        returns (FilecoinWarmStorageService intermediate)
    {
        intermediate = _newIntermediate(token, _createMigration(bytes4(0)));
        vm.roll(_announce(service, address(intermediate)));
        service.upgradeToAndCall(address(intermediate), _transitionData());
    }

    /// @dev Asserts that a failed transition left the legacy implementation, its plan and empty routes.
    function _assertUntouched(address proxy, address original, address intermediate, uint96 epoch) internal view {
        assertEq(_implementation(proxy), original);
        (address target, uint96 readyAt) = _plan(proxy);
        assertEq(target, intermediate);
        assertEq(readyAt, epoch);
        assertEq(vm.load(proxy, keccak256(abi.encode(IERC8167.implementation.selector, DELEGATES_SLOT))), bytes32(0));
    }

    function _assertDispatcherRoutes(address proxy) internal view {
        assertEq(_implementation(proxy), dispatcher);
        _assertFacetRoutes(proxy);
    }

    function _assertFacetRoutes(address proxy) internal view {
        for (uint256 i; i < exportedSelectors.length; ++i) {
            assertEq(IERC8167(proxy).implementation(exportedSelectors[i]), routedTo[exportedSelectors[i]]);
        }

        // Equal lengths plus unique, expected members make selectors() the installed set.
        bytes4[] memory exported = IERC8167(proxy).selectors();
        assertEq(exported.length, exportedSelectors.length);
        for (uint256 i; i < exported.length; ++i) {
            assertEq(_count(exported, exported[i]), 1, "selectors() repeats a selector");
            assertEq(_count(exportedSelectors, exported[i]), 1, "selectors() lists an uninstalled selector");
            assertEq(IERC8167(proxy).implementation(exported[i]), routedTo[exported[i]]);
        }
    }

    function _count(bytes4[] memory selectors, bytes4 selector) internal pure returns (uint256 count) {
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i] == selector) ++count;
        }
    }

    function testRealMonolithAtomicDispatcherTransition() public {
        (FilecoinWarmStorageService service, FilecoinWarmStorageServiceStateView viewContract, MockERC20 token) =
            _realLegacy();
        address proxy = address(service);
        bytes32 ownerBefore = vm.load(proxy, OWNER_SLOT);
        bytes32 periodBefore = vm.load(proxy, bytes32(uint256(0)));
        bytes32 windowBefore = vm.load(proxy, bytes32(uint256(1)));
        bytes32 viewBefore = vm.load(proxy, bytes32(uint256(17)));
        FWSSProviderManagementModule(proxy).addApprovedProvider(7);

        address migration = _createMigration(bytes4(0));
        FilecoinWarmStorageService intermediate = _newIntermediate(token, migration);
        assertGt(address(intermediate).code.length, 3000);
        uint96 epoch = _announce(service, address(intermediate));
        (address announced, uint96 afterEpoch) = viewContract.nextUpgrade();
        assertEq(announced, address(intermediate));
        assertEq(afterEpoch, epoch);
        vm.roll(epoch);

        vm.recordLogs();
        service.upgradeToAndCall(address(intermediate), _transitionData());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertDispatcherRoutes(proxy);
        assertEq(vm.load(proxy, OWNER_SLOT), ownerBefore);
        assertEq(vm.load(proxy, bytes32(uint256(0))), periodBefore);
        assertEq(vm.load(proxy, bytes32(uint256(1))), windowBefore);
        assertEq(vm.load(proxy, bytes32(uint256(17))), viewBefore);
        (address pending, uint96 readyAt) = _plan(proxy);
        assertEq(pending, address(0));
        assertEq(readyAt, 0);

        // Upgraded(intermediate), DiamondDelegateCall(migration), the migration's own logs, Upgraded(dispatcher).
        assertEq(logs[0].topics[0], IERC1967.Upgraded.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(intermediate)))));
        assertEq(logs[1].topics[0], Migrate.DiamondDelegateCall.selector);
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(migration))));
        assertEq(logs[logs.length - 1].topics[0], IERC1967.Upgraded.selector);
        assertEq(logs[logs.length - 1].topics[1], bytes32(uint256(uint160(dispatcher))));

        assertEq(OwnershipModule(proxy).owner(), address(this));
        assertEq(FWSSViewContractModule(proxy).viewContractAddress(), address(viewContract));
        FWSSProviderManagementModule(proxy).addApprovedProvider(42);
        assertEq(uint256(vm.load(proxy, keccak256(abi.encode(uint256(42), uint256(15))))), 1);

        // The existing StateView reads storage through ExtsloadModule.
        (uint64 provingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        assertEq(provingPeriod, 3000);
        assertEq(challengeWindow, 61);
        assertTrue(viewContract.isProviderApproved(7));
        assertTrue(viewContract.isProviderApproved(42));
        (address next,) = viewContract.nextUpgrade();
        assertEq(next, address(0));

        // The former immutable getters belong to the business modules that use them; none are routed yet.
        vm.expectRevert(abi.encodeWithSelector(IERC8167.FunctionNotFound.selector, service.usdfcTokenAddress.selector));
        viewContract.getPriceList();

        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        FWSSProviderManagementModule(proxy).addApprovedProvider(43);

        // The intermediate's own entry points are gone with the monolith.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC8167.FunctionNotFound.selector, FilecoinWarmStorageService.completeDispatcherTransition.selector
            )
        );
        service.completeDispatcherTransition();
    }

    function testLegacyRejectsRawDispatcherAsUpgradeTarget() public {
        (FilecoinWarmStorageService service,,) = _realLegacy();
        vm.expectRevert();
        service.announceUpgradePlan(dispatcher, 0);
    }

    function testConstructorValidatesDispatcherTransition() public {
        MockERC20 token = new MockERC20();
        address migration = _createMigration(bytes4(0));
        address fake = address(0xF00D);
        vm.etch(fake, new bytes(88));

        vm.expectRevert(FilecoinWarmStorageService.InvalidDispatcherTransition.selector);
        _newImplementation(token, fake, migration);
        vm.expectRevert(FilecoinWarmStorageService.InvalidDispatcherTransition.selector);
        _newImplementation(token, dispatcher, address(0x1234));
        vm.expectRevert(FilecoinWarmStorageService.InvalidDispatcherTransition.selector);
        _newImplementation(token, dispatcher, address(0));
        vm.expectRevert(FilecoinWarmStorageService.InvalidDispatcherTransition.selector);
        _newImplementation(token, address(0), migration);

        _newImplementation(token, address(0), address(0));
        FilecoinWarmStorageService intermediate = _newImplementation(token, dispatcher, migration);
        assertEq(intermediate.dispatcherAddress(), dispatcher);
        assertEq(intermediate.dispatcherMigrationAddress(), migration);
    }

    function testTransitionRequiresDelayAndOwner() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        FilecoinWarmStorageService intermediate = _newIntermediate(token, _createMigration(bytes4(0)));
        service.announceUpgradePlan(address(intermediate), 2);
        (, uint96 epoch) = _plan(proxy);

        vm.roll(epoch - 1);
        vm.expectRevert();
        service.upgradeToAndCall(address(intermediate), _transitionData());
        vm.roll(epoch);
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        service.upgradeToAndCall(address(intermediate), _transitionData());
        _assertUntouched(proxy, original, address(intermediate), epoch);

        service.upgradeToAndCall(address(intermediate), _transitionData());
        _assertDispatcherRoutes(proxy);
    }

    function testMonolithWithoutDispatcherCannotComplete() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        FilecoinWarmStorageService next = _newMonolith(token);
        uint96 epoch = _announce(service, address(next));
        vm.roll(epoch);

        vm.expectRevert(FilecoinWarmStorageService.InvalidDispatcherTransition.selector);
        service.upgradeToAndCall(address(next), _transitionData());
        _assertUntouched(proxy, original, address(next), epoch);
    }

    function testCompletionRequiresProxyContext() public {
        FilecoinWarmStorageService intermediate = _newIntermediate(new MockERC20(), _createMigration(bytes4(0)));
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        intermediate.completeDispatcherTransition();
    }

    function testEmptyUpgradeDataLeavesIntermediateThatOwnerCanComplete() public {
        (FilecoinWarmStorageService service, FilecoinWarmStorageServiceStateView viewContract, MockERC20 token) =
            _realLegacy();
        address proxy = address(service);
        FilecoinWarmStorageService intermediate = _newIntermediate(token, _createMigration(bytes4(0)));
        vm.roll(_announce(service, address(intermediate)));
        service.upgradeToAndCall(address(intermediate), "");
        assertEq(_implementation(proxy), address(intermediate));
        (uint64 provingPeriod,,,) = viewContract.getPDPConfig();
        assertEq(provingPeriod, 3000);

        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        service.completeDispatcherTransition();

        // A plan announced while the intermediate is live must not survive as a migration.
        FilecoinWarmStorageService next = _newMonolith(token);
        service.announceUpgradePlan(address(next), 0);

        service.completeDispatcherTransition();
        _assertDispatcherRoutes(proxy);
        (address pending, uint96 readyAt) = _plan(proxy);
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(FWSSMigrateModule.MigrationNotAnnounced.selector, address(next)));
        FWSSMigrateModule(proxy).migrate(address(next));
    }

    function testRevertingMigrationRollsBackBothUpgrades() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        FilecoinWarmStorageService intermediate = _newIntermediate(token, address(new RevertingMigrationFixture()));
        uint96 epoch = _announce(service, address(intermediate));
        vm.roll(epoch);

        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(RevertingMigrationFixture.MigrationFailed.selector);
            service.upgradeToAndCall(address(intermediate), _transitionData());
            _assertUntouched(proxy, original, address(intermediate), epoch);
        }
    }

    function testChangedMigrationCodeRollsBackBothUpgrades() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        address migration = _createMigration(bytes4(0));
        FilecoinWarmStorageService intermediate = _newIntermediate(token, migration);
        uint96 epoch = _announce(service, address(intermediate));
        vm.roll(epoch);

        vm.etch(migration, address(new RevertingMigrationFixture()).code);
        vm.expectRevert(FilecoinWarmStorageService.InvalidDispatcherTransition.selector);
        service.upgradeToAndCall(address(intermediate), _transitionData());
        _assertUntouched(proxy, original, address(intermediate), epoch);
    }

    function testLegacyMigrateDataCannotLeaveIntermediateInstalled() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        FilecoinWarmStorageService intermediate = _newIntermediate(token, _createMigration(bytes4(0)));
        uint96 epoch = _announce(service, address(intermediate));
        vm.roll(epoch);

        vm.expectRevert(FilecoinWarmStorageService.InvalidDispatcherTransition.selector);
        service.upgradeToAndCall(
            address(intermediate), abi.encodeCall(FilecoinWarmStorageService.migrate, (address(0)))
        );
        _assertUntouched(proxy, original, address(intermediate), epoch);
    }

    function testMigrationCannotReenterTransition() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        ReentrantMigrationFixture migration =
            new ReentrantMigrationFixture(FilecoinWarmStorageService.completeDispatcherTransition.selector);
        FilecoinWarmStorageService intermediate = _newIntermediate(token, address(migration));
        uint96 epoch = _announce(service, address(intermediate));
        vm.roll(epoch);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, proxy));
        service.upgradeToAndCall(address(intermediate), _transitionData());
        _assertUntouched(proxy, original, address(intermediate), epoch);
    }

    function testMissingUpgradeRouteRollsBackBothUpgrades() public {
        bytes4[4] memory critical = [
            IERC8167.implementation.selector,
            IERC8167.selectors.selector,
            FWSSMigrateModule.announceMigration.selector,
            FWSSMigrateModule.migrate.selector
        ];
        for (uint256 i; i < critical.length; ++i) {
            (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
            address proxy = address(service);
            address original = _implementation(proxy);
            FilecoinWarmStorageService intermediate = _newIntermediate(token, _createMigration(critical[i]));
            uint96 epoch = _announce(service, address(intermediate));
            vm.roll(epoch);

            vm.expectRevert(abi.encodeWithSelector(LibUpgradeRoutes.MissingUpgradeRoute.selector, critical[i]));
            service.upgradeToAndCall(address(intermediate), _transitionData());
            _assertUntouched(proxy, original, address(intermediate), epoch);
        }
    }

    function testOwnershipModuleTransfersControlAfterTransition() public {
        (FilecoinWarmStorageService service,, MockERC20 token) = _realLegacy();
        address proxy = address(service);
        _transition(service, token);

        OwnershipModule(proxy).transferOwnership(address(0xB0B));
        assertEq(OwnershipModule(proxy).owner(), address(0xB0B));

        address migration = _createMigration(bytes4(0));
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, address(this)));
        FWSSMigrateModule(proxy).announceMigration(migration, 0);

        vm.prank(address(0xB0B));
        FWSSMigrateModule(proxy).announceMigration(migration, 0);
        (address target,) = _plan(proxy);
        assertEq(target, migration);
    }
}
