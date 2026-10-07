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
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FWSSDispatcherTransition} from "../src/FWSSDispatcherTransition.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {FWSSMigrateModule} from "../src/modules/FWSSMigrateModule.sol";
import {OwnershipModule} from "../src/modules/OwnershipModule.sol";
import {FWSSProviderManagementModule} from "../src/modules/FWSSProviderManagementModule.sol";
import {FWSSViewContractModule} from "../src/modules/FWSSViewContractModule.sol";
import {ERC8167Transition} from "../src/ERC8167Transition.sol";
import {FWSSOwnable} from "../src/lib/FWSSOwnable.sol";
import {Errors} from "../src/Errors.sol";
import {LibUpgradeRoutes} from "../src/lib/LibUpgradeRoutes.sol";
import {NEXT_UPGRADE_SLOT} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {MockERC20} from "./mocks/SharedMocks.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
    address internal legacyImplementation;
    // Synthetic dispatcher-only proxies have no existing rails.
    address internal facetPaymentsContractAddress = address(0xF11E);
    address internal facetPDPVerifierAddress = address(0xF11F);
    IERC20Metadata internal facetToken;
    address internal facetBeneficiary = address(0xF120);
    address internal facetProviderRegistry = address(0xF121);
    address internal facetSessionKeyRegistry = address(0xF122);
    FWSSMigrateModule internal migrateModule;
    uint256 private legacyProxies;

    // Routes installed by the latest _createMigration.
    bytes4[] internal exportedSelectors;
    mapping(bytes4 selector => address delegate) internal routedTo;

    function setUp() public {
        dispatcher = deployCode("lib/erc8167/out/Proxy.evm/Proxy.json");
        migrateModule = new FWSSMigrateModule();
        facetToken = new MockERC20();
    }

    function _facetConstructorArgs(string memory sourceId) internal view override returns (bytes memory) {
        if (keccak256(bytes(sourceId)) == keccak256("src/modules/FWSSConfigModule.sol:FWSSConfigModule")) {
            return abi.encode(facetPaymentsContractAddress, facetPDPVerifierAddress);
        }
        if (keccak256(bytes(sourceId)) == keccak256("src/modules/FWSSDataSetModule.sol:FWSSDataSetModule")) {
            return abi.encode(facetToken, facetBeneficiary, facetProviderRegistry, facetSessionKeyRegistry);
        }
        if (keccak256(bytes(sourceId)) == keccak256("src/modules/FWSSPaymentModule.sol:FWSSPaymentModule")) {
            return abi.encode(facetToken, facetSessionKeyRegistry);
        }
        return super._facetConstructorArgs(sourceId);
    }

    function testConfigConstructorArgsRejectZeroAddress() public {
        facetPaymentsContractAddress = address(0);
        string[] memory patterns = new string[](1);
        patterns[0] = "src/modules/FWSSConfigModule.sol:FWSSConfigModule";
        Facet[] memory facets = _resolvePatterns(patterns);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.FilecoinPayV1));
        _deployFacetRoutes(facets);
    }

    function testConfigConstructorArgsRejectZeroVerifier() public {
        facetPDPVerifierAddress = address(0);
        string[] memory patterns = new string[](1);
        patterns[0] = "src/modules/FWSSConfigModule.sol:FWSSConfigModule";
        Facet[] memory facets = _resolvePatterns(patterns);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.PDPVerifier));
        _deployFacetRoutes(facets);
    }

    function testConfigGettersThroughDispatcher() public {
        string[] memory patterns = new string[](1);
        patterns[0] = "src/modules/FWSSConfigModule.sol:FWSSConfigModule";
        SetDelegateOperation[] memory routes = _deployFacetRoutes(_resolvePatterns(patterns));
        address proxy = _rawProxy();
        for (uint256 i; i < routes.length; ++i) {
            _route(proxy, routes[i].selector, routes[i].delegate);
        }
        assertEq(FilecoinWarmStorageService(proxy).paymentsContractAddress(), facetPaymentsContractAddress);
        assertEq(FilecoinWarmStorageService(proxy).pdpVerifierAddress(), facetPDPVerifierAddress);
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
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        _transition(service);

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
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        _transition(service);

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

    /// @dev A proxy running the deployed mainnet v1.4.0 proxy and implementation bytecode, not a rebuild.
    function _realLegacy()
        internal
        returns (FilecoinWarmStorageService service, FilecoinWarmStorageServiceStateView viewContract)
    {
        string memory fixture = vm.readFile(V1_4_0_MAINNET);

        // Its UUPS onlyProxy check compares the implementation slot with its own mainnet address.
        address implementation = vm.parseJsonAddress(fixture, ".implementation.address");
        vm.etch(implementation, vm.parseJsonBytes(fixture, ".implementation.code"));
        legacyImplementation = implementation;

        address proxy = address(uint160(uint256(keccak256(abi.encode(V1_4_0_MAINNET, ++legacyProxies)))));
        vm.etch(proxy, vm.parseJsonBytes(fixture, ".proxy.code"));
        vm.store(proxy, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));

        service = FilecoinWarmStorageService(proxy);
        facetPaymentsContractAddress = service.paymentsContractAddress();
        facetPDPVerifierAddress = service.pdpVerifierAddress();
        facetToken = service.usdfcTokenAddress();
        facetBeneficiary = service.filBeamBeneficiaryAddress();
        facetProviderRegistry = address(service.serviceProviderRegistry());
        facetSessionKeyRegistry = address(service.sessionKeyRegistry());
        vm.mockCall(address(facetToken), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(18)));
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

    function _newTransition(address migration) internal returns (FWSSDispatcherTransition) {
        return new FWSSDispatcherTransition(legacyImplementation, dispatcher, migration);
    }

    function _migrateData(address migration) internal pure returns (bytes memory) {
        return abi.encodeCall(Migrate.migrate, (migration));
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _transition(FilecoinWarmStorageService service) internal returns (FWSSDispatcherTransition transition) {
        address migration = _createMigration(bytes4(0));
        transition = _newTransition(migration);
        vm.roll(_announce(service, address(transition)));
        service.upgradeToAndCall(address(transition), _migrateData(migration));
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
        (FilecoinWarmStorageService service, FilecoinWarmStorageServiceStateView viewContract) = _realLegacy();
        address proxy = address(service);
        bytes32 ownerBefore = vm.load(proxy, OWNER_SLOT);
        bytes32 periodBefore = vm.load(proxy, bytes32(uint256(0)));
        bytes32 windowBefore = vm.load(proxy, bytes32(uint256(1)));
        bytes32 viewBefore = vm.load(proxy, bytes32(uint256(17)));
        FWSSProviderManagementModule(proxy).addApprovedProvider(7);

        address migration = _createMigration(bytes4(0));
        FWSSDispatcherTransition transition = _newTransition(migration);
        uint96 epoch = _announce(service, address(transition));
        (address announced, uint96 afterEpoch) = viewContract.nextUpgrade();
        assertEq(announced, address(transition));
        assertEq(afterEpoch, epoch);
        vm.roll(epoch);

        vm.recordLogs();
        service.upgradeToAndCall(address(transition), _migrateData(migration));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertDispatcherRoutes(proxy);
        assertEq(vm.load(proxy, OWNER_SLOT), ownerBefore);
        assertEq(vm.load(proxy, bytes32(uint256(0))), periodBefore);
        assertEq(vm.load(proxy, bytes32(uint256(1))), windowBefore);
        assertEq(vm.load(proxy, bytes32(uint256(17))), viewBefore);
        (address pending, uint96 readyAt) = _plan(proxy);
        assertEq(pending, address(0));
        assertEq(readyAt, 0);

        // Upgraded(transition), Upgraded(dispatcher), DiamondDelegateCall(migration), then the migration's own logs.
        assertEq(logs[0].topics[0], IERC1967.Upgraded.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(transition)))));
        assertEq(logs[1].topics[0], IERC1967.Upgraded.selector);
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(dispatcher))));
        assertEq(logs[2].topics[0], Migrate.DiamondDelegateCall.selector);
        assertEq(logs[2].topics[1], bytes32(uint256(uint160(migration))));

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

        // The transition's own entry points are gone with it.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC8167.FunctionNotFound.selector, FWSSDispatcherTransition.legacyUpgradePadding.selector
            )
        );
        FWSSDispatcherTransition(proxy).legacyUpgradePadding();
    }

    function testLegacyRejectsRawDispatcherAsUpgradeTarget() public {
        (FilecoinWarmStorageService service,) = _realLegacy();
        vm.expectRevert();
        service.announceUpgradePlan(dispatcher, 0);
    }

    function testTransitionRequiresDelayAndOwner() public {
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        address migration = _createMigration(bytes4(0));
        FWSSDispatcherTransition transition = _newTransition(migration);
        service.announceUpgradePlan(address(transition), 2);
        (, uint96 epoch) = _plan(proxy);

        vm.roll(epoch - 1);
        vm.expectRevert();
        service.upgradeToAndCall(address(transition), _migrateData(migration));
        vm.roll(epoch);
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        service.upgradeToAndCall(address(transition), _migrateData(migration));
        _assertUntouched(proxy, original, address(transition), epoch);

        service.upgradeToAndCall(address(transition), _migrateData(migration));
        _assertDispatcherRoutes(proxy);
    }

    function testEmptyUpgradeDataLeavesTransitionThatOwnerCanComplete() public {
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        address migration = _createMigration(bytes4(0));
        FWSSDispatcherTransition transition = _newTransition(migration);
        vm.roll(_announce(service, address(transition)));
        service.upgradeToAndCall(address(transition), "");
        assertEq(_implementation(proxy), address(transition));

        // Nothing but the transition is reachable, so no new plan can be announced meanwhile.
        vm.expectRevert();
        service.announceUpgradePlan(migration, 0);

        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        FWSSDispatcherTransition(proxy).migrate(migration);

        FWSSDispatcherTransition(proxy).migrate(migration);
        _assertDispatcherRoutes(proxy);
        (address pending, uint96 readyAt) = _plan(proxy);
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
    }

    /// @dev After an upgrade with empty data, a migration that cannot complete must not brick the proxy.
    function testOwnerCanAbortStuckTransition() public {
        (FilecoinWarmStorageService service, FilecoinWarmStorageServiceStateView viewContract) = _realLegacy();
        address proxy = address(service);
        address migration = address(new RevertingMigrationFixture());
        FWSSDispatcherTransition transition = _newTransition(migration);
        vm.roll(_announce(service, address(transition)));
        service.upgradeToAndCall(address(transition), "");

        vm.expectRevert(RevertingMigrationFixture.MigrationFailed.selector);
        FWSSDispatcherTransition(proxy).migrate(migration);
        vm.expectRevert(ERC8167Transition.UnauthorizedCallContext.selector);
        FWSSDispatcherTransition(proxy).proxiableUUID();
        vm.expectRevert(ERC8167Transition.UnauthorizedCallContext.selector);
        transition.abortTransition();
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        FWSSDispatcherTransition(proxy).abortTransition();

        FWSSDispatcherTransition(proxy).abortTransition();
        assertEq(_implementation(proxy), legacyImplementation);
        (uint64 provingPeriod,,,) = viewContract.getPDPConfig();
        assertEq(provingPeriod, 3000);
        service.announceUpgradePlan(address(transition), 0);
    }

    function testRevertingMigrationRollsBackBothUpgrades() public {
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        address migration = address(new RevertingMigrationFixture());
        FWSSDispatcherTransition transition = _newTransition(migration);
        uint96 epoch = _announce(service, address(transition));
        vm.roll(epoch);

        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(RevertingMigrationFixture.MigrationFailed.selector);
            service.upgradeToAndCall(address(transition), _migrateData(migration));
            _assertUntouched(proxy, original, address(transition), epoch);
        }
    }

    function testChangedMigrationCodeRollsBackBothUpgrades() public {
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        address migration = _createMigration(bytes4(0));
        FWSSDispatcherTransition transition = _newTransition(migration);
        uint96 epoch = _announce(service, address(transition));
        vm.roll(epoch);

        vm.etch(migration, address(new RevertingMigrationFixture()).code);
        vm.expectRevert(abi.encodeWithSelector(ERC8167Transition.UnexpectedMigration.selector, migration));
        service.upgradeToAndCall(address(transition), _migrateData(migration));
        _assertUntouched(proxy, original, address(transition), epoch);
    }

    function testMigrationThatReplacesTheDispatcherRollsBackBothUpgrades() public {
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        address migration = address(new DispatcherSwapMigrationFixture());
        FWSSDispatcherTransition transition = _newTransition(migration);
        uint96 epoch = _announce(service, address(transition));
        vm.roll(epoch);

        vm.expectRevert(abi.encodeWithSelector(ERC8167Transition.DispatcherChanged.selector, address(0xBEEF)));
        service.upgradeToAndCall(address(transition), _migrateData(migration));
        _assertUntouched(proxy, original, address(transition), epoch);
    }

    /// @dev The ordinary upgrade script sends migrate(view contract), which shares the selector.
    function testLegacyMigrateDataCannotLeaveTransitionInstalled() public {
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        FWSSDispatcherTransition transition = _newTransition(_createMigration(bytes4(0)));
        uint96 epoch = _announce(service, address(transition));
        vm.roll(epoch);

        vm.expectRevert(abi.encodeWithSelector(ERC8167Transition.UnexpectedMigration.selector, address(0)));
        service.upgradeToAndCall(address(transition), abi.encodeCall(FilecoinWarmStorageService.migrate, (address(0))));
        _assertUntouched(proxy, original, address(transition), epoch);
    }

    /// @dev The transition uninstalls itself first, so the callback reaches the dispatcher, not the transition.
    function testMigrationCannotReenterTransition() public {
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        address original = _implementation(proxy);
        address migration = address(new ReentrantMigrationFixture(Migrate.migrate.selector));
        FWSSDispatcherTransition transition = _newTransition(migration);
        uint96 epoch = _announce(service, address(transition));
        vm.roll(epoch);

        vm.expectRevert(abi.encodeWithSelector(IERC8167.FunctionNotFound.selector, Migrate.migrate.selector));
        service.upgradeToAndCall(address(transition), _migrateData(migration));
        _assertUntouched(proxy, original, address(transition), epoch);
    }

    function testMissingUpgradeRouteRollsBackBothUpgrades() public {
        bytes4[4] memory critical = [
            IERC8167.implementation.selector,
            IERC8167.selectors.selector,
            FWSSMigrateModule.announceMigration.selector,
            FWSSMigrateModule.migrate.selector
        ];
        for (uint256 i; i < critical.length; ++i) {
            (FilecoinWarmStorageService service,) = _realLegacy();
            address proxy = address(service);
            address original = _implementation(proxy);
            address migration = _createMigration(critical[i]);
            FWSSDispatcherTransition transition = _newTransition(migration);
            uint96 epoch = _announce(service, address(transition));
            vm.roll(epoch);

            vm.expectRevert(abi.encodeWithSelector(LibUpgradeRoutes.MissingUpgradeRoute.selector, critical[i]));
            service.upgradeToAndCall(address(transition), _migrateData(migration));
            _assertUntouched(proxy, original, address(transition), epoch);
        }
    }

    function testOwnershipModuleTransfersControlAfterTransition() public {
        (FilecoinWarmStorageService service,) = _realLegacy();
        address proxy = address(service);
        _transition(service);

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
