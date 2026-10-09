// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC8167} from "@erc8167/interfaces/IERC8167.sol";
import {Migration, SetDelegateOperation, SetDelegateOperationLibrary} from "@erc8167/lib/Migration.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {FWSS_DISPATCHER_CODE_HASH, FWSSDispatcherTransition} from "../src/FWSSDispatcherTransition.sol";
import {OwnershipModule} from "../src/modules/OwnershipModule.sol";
import {FWSSDispatcherTransitionDeploy} from "../script/FWSSDispatcherTransitionDeploy.s.sol";
import {FWSSDispatcherTransitionExecute} from "../script/FWSSDispatcherTransitionExecute.s.sol";
import {DeploymentsJson} from "../script/lib/DeploymentsJson.sol";
import {JosukeLedger} from "../script/lib/JosukeLedger.sol";
import {JosukeFacetSet} from "./helpers/JosukeFacetSet.sol";

/// @dev Drives the transition scripts against the deployed mainnet v1.4.0 bytecode, at the mainnet proxy address
/// that deployments.json and josuke.json record for chain 314.
contract FWSSDispatcherTransitionScriptsTest is JosukeFacetSet {
    uint256 private constant CHAIN = 314;
    string private constant V1_4_0_MAINNET = "test/fixtures/fwss-v1.4.0-mainnet.json";
    string private constant SCRATCH = "out/FWSSDispatcherTransitionScripts";
    string private constant DEPLOYMENTS = "out/FWSSDispatcherTransitionScripts/deployments.json";
    string private constant SCRATCH_LEDGER = "out/FWSSDispatcherTransitionScripts/josuke.json";
    string private constant GIT_COMMIT = "0123456789abcdef0123456789abcdef01234567";
    string private constant DISPATCHER_ARTIFACT = "lib/erc8167/out/Proxy.evm/Proxy.json";
    string private constant TRANSITION_ARTIFACT = "src/FWSSDispatcherTransition.sol:FWSSDispatcherTransition";
    string private constant TRANSITION_ENTRY = ".314.contracts.FWSS_DISPATCHER_TRANSITION";

    FilecoinWarmStorageService internal service;
    address internal proxy;
    address internal legacyImplementation;
    FilecoinWarmStorageServiceStateView internal viewContract;
    address internal migration;

    // Routes the migration installs.
    bytes4[] internal exportedSelectors;
    mapping(bytes4 selector => address delegate) internal routedTo;

    function setUp() public {
        vm.chainId(CHAIN);
        string memory fixture = vm.readFile(V1_4_0_MAINNET);

        // Its UUPS onlyProxy check compares the implementation slot with its own mainnet address.
        legacyImplementation = vm.parseJsonAddress(fixture, ".implementation.address");
        vm.etch(legacyImplementation, vm.parseJsonBytes(fixture, ".implementation.code"));
        proxy = vm.parseJsonAddress(fixture, ".proxy.address");
        vm.etch(proxy, vm.parseJsonBytes(fixture, ".proxy.code"));
        vm.store(proxy, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(legacyImplementation))));
        service = FilecoinWarmStorageService(proxy);

        // The execute script reads the plan from the view recorded in deployments.json.
        viewContract = FilecoinWarmStorageServiceStateView(
            vm.parseJsonAddress(vm.readFile("deployments.json"), ".314.FWSS_VIEW_ADDRESS")
        );
        deployCodeTo(
            "FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView",
            abi.encode(proxy),
            address(viewContract)
        );

        // The dataset facet's constructor checks USDFC decimals.
        deployCodeTo("SharedMocks.sol:MockERC20", address(service.usdfcTokenAddress()));

        // The scripts broadcast as DEFAULT_SENDER under forge test, so it owns the proxy.
        vm.startPrank(DEFAULT_SENDER);
        service.initialize(2880, 60, address(0x16));
        service.setViewContract(address(viewContract));
        service.configureProvingPeriod(3000, 61);
        vm.stopPrank();

        migration = _createMigration();
    }

    /// @dev The scripts read process-wide environment variables and shared files, and forge runs the test functions of
    /// a contract in parallel, so the scenarios run in sequence here, each from the setUp state.
    function testTransitionScripts() public {
        uint256 clean = vm.snapshotState();

        _reset(clean);
        _deployAnnounceExecuteOnV140();

        _reset(clean);
        _deployIsIdempotent();

        _reset(clean);
        _deployReusesRecordedDispatcher();

        _reset(clean);
        _deployRequiresProposedMigration();

        _reset(clean);
        _deployRequiresGitCommit();

        _reset(clean);
        _deployDryRunRecordsNothing();

        _reset(clean);
        _deployRefusesBroadcastWithoutWallet();

        _reset(clean);
        _executeChecks();

        _reset(clean);
        _deployReplacesRecordedDispatcherWithoutCode();

        _reset(clean);
        _deployReplacesTransitionWithOtherPins();

        _reset(clean);
        _deployReplacesUnrelatedCodeAtRecordedTransition();

        _reset(clean);
        _deployChecksTransitionFromEnv();

        _reset(clean);
        _deployHonoursPinned();

        _reset(clean);
        _deployRefusesAfterTransition();

        _reset(clean);
        _scriptsRefuseProxyLeftOnTransition();

        _reset(clean);
        _executeFallsBackToViewContractAddress();

        _reset(clean);
        _malformedEnvReverts();

        _reset(clean);
        _deployRejectsAmbiguousLedger();
    }

    function testIsoTimestamp() public pure {
        assertEq(DeploymentsJson.isoTimestamp(0), "1970-01-01T00:00:00Z");
        assertEq(DeploymentsJson.isoTimestamp(951782400), "2000-02-29T00:00:00Z");
        assertEq(DeploymentsJson.isoTimestamp(1735689599), "2024-12-31T23:59:59Z");
        assertEq(DeploymentsJson.isoTimestamp(1787329742), "2026-08-21T16:29:02Z");
        assertEq(DeploymentsJson.isoTimestamp(4107575107), "2100-03-01T09:05:07Z");
    }

    function _deployAnnounceExecuteOnV140() internal {
        new FWSSDispatcherTransitionDeploy().run();

        string memory json = vm.readFile(DEPLOYMENTS);
        address dispatcher = vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_ADDRESS");
        assertEq(dispatcher.codehash, FWSS_DISPATCHER_CODE_HASH);
        FWSSDispatcherTransition transition =
            FWSSDispatcherTransition(vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS"));
        assertEq(transition.previousImplementation(), legacyImplementation);
        assertEq(transition.dispatcher(), dispatcher);
        assertEq(transition.migration(), migration);
        _assertTransitionRecord(json, dispatcher);

        assertEq(vm.parseJsonString(json, ".314.metadata.commit"), GIT_COMMIT);
        _assertIsoTimestamp(vm.parseJsonString(json, ".314.metadata.deployed_at"));
        assertEq(vm.parseJsonString(json, ".314.metadata.fwss_version"), "1.4.0");
        string memory original = vm.readFile("deployments.json");
        assertEq(
            vm.parseJsonString(json, ".314.FWSS_PROXY_ADDRESS"), vm.parseJsonString(original, ".314.FWSS_PROXY_ADDRESS")
        );
        assertEq(
            vm.parseJsonString(json, ".314159.FWSS_PROXY_ADDRESS"),
            vm.parseJsonString(original, ".314159.FWSS_PROXY_ADDRESS")
        );
        _assertChecksummed(vm.parseJsonString(json, ".314.FWSS_DISPATCHER_ADDRESS"));
        _assertChecksummed(vm.parseJsonString(json, ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS"));
        bytes memory raw = bytes(json);
        assertEq(raw[raw.length - 1], bytes1("\n"));

        vm.prank(DEFAULT_SENDER);
        service.announceUpgradePlan(address(transition), 0);
        (, uint96 afterEpoch) = viewContract.nextUpgrade();
        vm.roll(afterEpoch);
        new FWSSDispatcherTransitionExecute().run();

        assertEq(_implementation(), dispatcher);
        _assertFacetRoutes();
        assertEq(OwnershipModule(proxy).owner(), DEFAULT_SENDER);
        (uint64 provingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        assertEq(provingPeriod, 3000);
        assertEq(challengeWindow, 61);
        assertEq(vm.readFile(DEPLOYMENTS), json, "execute must not write deployments.json");
    }

    function _deployIsIdempotent() internal {
        new FWSSDispatcherTransitionDeploy().run();
        string memory recorded = vm.readFile(DEPLOYMENTS);
        uint256 nonce = vm.getNonce(DEFAULT_SENDER);

        new FWSSDispatcherTransitionDeploy().run();

        assertEq(vm.readFile(DEPLOYMENTS), recorded);
        assertEq(vm.getNonce(DEFAULT_SENDER), nonce);
    }

    function _deployReusesRecordedDispatcher() internal {
        address dispatcher = deployCode(DISPATCHER_ARTIFACT);
        vm.setEnv("FWSS_DISPATCHER_ADDRESS", vm.toString(dispatcher));
        new FWSSDispatcherTransitionDeploy().run();

        string memory json = vm.readFile(DEPLOYMENTS);
        assertFalse(vm.keyExistsJson(json, ".314.FWSS_DISPATCHER_ADDRESS"));
        address transition = vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");
        assertEq(FWSSDispatcherTransition(transition).dispatcher(), dispatcher);

        vm.setEnv("FWSS_DISPATCHER_ADDRESS", vm.toString(legacyImplementation));
        FWSSDispatcherTransitionDeploy deploy = new FWSSDispatcherTransitionDeploy();
        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(legacyImplementation),
                    " is not the pinned ERC-8167 dispatcher (code hash ",
                    vm.toString(legacyImplementation.codehash),
                    ")"
                )
            )
        );
        deploy.run();
    }

    function _deployRequiresProposedMigration() internal {
        FWSSDispatcherTransitionDeploy deploy = new FWSSDispatcherTransitionDeploy();

        _writeLedger(proxy, address(0));
        vm.expectRevert(abi.encodeWithSelector(JosukeLedger.NoProposedMigration.selector, proxy, CHAIN));
        deploy.run();

        _writeLedger(address(0xDEAD), migration);
        vm.expectRevert(abi.encodeWithSelector(JosukeLedger.ProxyNotInLedger.selector, proxy));
        deploy.run();
    }

    function _deployRequiresGitCommit() internal {
        vm.setEnv("GIT_COMMIT", "");
        FWSSDispatcherTransitionDeploy deploy = new FWSSDispatcherTransitionDeploy();

        vm.expectRevert(bytes("set GIT_COMMIT=$(git rev-parse HEAD) to record the deployment"));
        deploy.run();

        // The commit is checked before anything is written.
        assertEq(vm.readFile(DEPLOYMENTS), vm.readFile("deployments.json"));
    }

    function _deployDryRunRecordsNothing() internal {
        // A dry run needs no commit, since it records nothing.
        vm.setEnv("GIT_COMMIT", "");
        new DryRunDeploy().run();

        assertEq(vm.readFile(DEPLOYMENTS), vm.readFile("deployments.json"));
    }

    function _deployRefusesBroadcastWithoutWallet() internal {
        FWSSDispatcherTransitionDeploy deploy = new BroadcastDeploy();
        uint256 nonce = vm.getNonce(DEFAULT_SENDER);

        vm.expectRevert(bytes("--broadcast needs a wallet: pass --keystore, --account or --private-key"));
        deploy.run();

        assertEq(vm.getNonce(DEFAULT_SENDER), nonce);
        assertEq(vm.readFile(DEPLOYMENTS), vm.readFile("deployments.json"));
    }

    function _executeChecks() internal {
        new FWSSDispatcherTransitionDeploy().run();
        address transition = vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");
        FWSSDispatcherTransitionExecute execute = new FWSSDispatcherTransitionExecute();

        vm.expectRevert(
            bytes(
                string.concat("the announced upgrade is ", vm.toString(address(0)), ", not ", vm.toString(transition))
            )
        );
        execute.run();

        vm.prank(DEFAULT_SENDER);
        service.announceUpgradePlan(transition, 2);
        (, uint96 afterEpoch) = viewContract.nextUpgrade();
        vm.expectRevert(
            bytes(string.concat("not time yet (", vm.toString(block.number), " < ", vm.toString(afterEpoch), ")"))
        );
        execute.run();
        vm.roll(afterEpoch);

        address otherMigration = address(0xC0FFEE);
        _writeLedger(proxy, otherMigration);
        vm.expectRevert(
            bytes(
                string.concat(
                    "the transition pins migration ",
                    vm.toString(migration),
                    ", but ",
                    SCRATCH_LEDGER,
                    " proposes ",
                    vm.toString(otherMigration)
                )
            )
        );
        execute.run();
        _writeLedger(proxy, migration);

        bytes memory migrationCode = migration.code;
        vm.etch(migration, hex"00");
        vm.expectRevert(
            bytes(string.concat("the code at ", vm.toString(migration), " changed since the transition was deployed"))
        );
        execute.run();
        vm.etch(migration, migrationCode);

        // A copy of v1.4.0 keeps the view and owner reads working while the proxy runs something else.
        address otherImplementation = address(0x1404);
        vm.etch(otherImplementation, legacyImplementation.code);
        vm.store(proxy, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(otherImplementation))));
        vm.expectRevert(
            bytes(
                string.concat(
                    "the transition would abort to ",
                    vm.toString(legacyImplementation),
                    ", but the proxy runs ",
                    vm.toString(otherImplementation)
                )
            )
        );
        execute.run();
        vm.store(proxy, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(legacyImplementation))));

        vm.setEnv("CALLDATA_ONLY", "true");
        execute.run();
        assertEq(_implementation(), legacyImplementation);
        vm.setEnv("CALLDATA_ONLY", "");

        address newOwner = address(0xB0B);
        vm.prank(DEFAULT_SENDER);
        service.transferOwnership(newOwner);
        vm.expectRevert(
            bytes(
                string.concat(
                    "sender ",
                    vm.toString(DEFAULT_SENDER),
                    " is not the proxy owner ",
                    vm.toString(newOwner),
                    "; pass --sender with the owner's wallet, or set CALLDATA_ONLY=true"
                )
            )
        );
        execute.run();
    }

    function _deployReplacesRecordedDispatcherWithoutCode() internal {
        address missing = address(0xD15);
        vm.writeJson(string.concat("\"", vm.toString(missing), "\""), DEPLOYMENTS, ".314.FWSS_DISPATCHER_ADDRESS");

        new FWSSDispatcherTransitionDeploy().run();

        string memory json = vm.readFile(DEPLOYMENTS);
        address dispatcher = vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_ADDRESS");
        assertNotEq(dispatcher, missing);
        assertEq(dispatcher.codehash, FWSS_DISPATCHER_CODE_HASH);
        _assertTransitionRecord(json, dispatcher);
    }

    function _deployReplacesTransitionWithOtherPins() internal {
        new FWSSDispatcherTransitionDeploy().run();
        address first = vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");

        // Any contract passes the transition's code check.
        address otherMigration = address(viewContract);
        _writeLedger(proxy, otherMigration);
        new FWSSDispatcherTransitionDeploy().run();

        string memory json = vm.readFile(DEPLOYMENTS);
        address second = vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");
        assertNotEq(second, first);
        assertEq(FWSSDispatcherTransition(second).migration(), otherMigration);
        string[] memory args = vm.parseJsonStringArray(json, string.concat(TRANSITION_ENTRY, ".constructor_args"));
        assertEq(args[2], vm.toString(otherMigration));
    }

    function _deployReplacesUnrelatedCodeAtRecordedTransition() internal {
        new FWSSDispatcherTransitionDeploy().run();
        string memory json = vm.readFile(DEPLOYMENTS);
        address dispatcher = vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_ADDRESS");
        address first = vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");

        // The record still matches, but the address now holds a dispatcher.
        vm.etch(first, dispatcher.code);
        new FWSSDispatcherTransitionDeploy().run();

        json = vm.readFile(DEPLOYMENTS);
        address second = vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");
        assertNotEq(second, first);
        assertEq(FWSSDispatcherTransition(second).migration(), migration);
        _assertTransitionRecord(json, dispatcher);
    }

    function _deployChecksTransitionFromEnv() internal {
        address dispatcher = deployCode(DISPATCHER_ARTIFACT);
        vm.setEnv("FWSS_DISPATCHER_ADDRESS", vm.toString(dispatcher));
        FWSSDispatcherTransitionDeploy deploy = new FWSSDispatcherTransitionDeploy();

        address otherMigration = address(viewContract);
        address other = address(new FWSSDispatcherTransition(legacyImplementation, dispatcher, otherMigration));
        vm.setEnv("FWSS_DISPATCHER_TRANSITION_ADDRESS", vm.toString(other));
        vm.expectRevert(
            bytes(
                string.concat(
                    "FWSS_DISPATCHER_TRANSITION_ADDRESS ",
                    vm.toString(other),
                    " does not pin the expected previous implementation ",
                    vm.toString(legacyImplementation),
                    ", dispatcher ",
                    vm.toString(dispatcher),
                    " and migration ",
                    vm.toString(migration)
                )
            )
        );
        deploy.run();

        address matching = address(new FWSSDispatcherTransition(legacyImplementation, dispatcher, migration));
        vm.setEnv("FWSS_DISPATCHER_TRANSITION_ADDRESS", vm.toString(matching));
        uint256 nonce = vm.getNonce(DEFAULT_SENDER);
        deploy.run();

        assertEq(vm.getNonce(DEFAULT_SENDER), nonce);
        assertEq(vm.readFile(DEPLOYMENTS), vm.readFile("deployments.json"));
    }

    function _deployHonoursPinned() internal {
        new FWSSDispatcherTransitionDeploy().run();
        address transition = vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");
        vm.writeJson("true", DEPLOYMENTS, string.concat(TRANSITION_ENTRY, ".pinned"));
        string memory recorded = vm.readFile(DEPLOYMENTS);
        uint256 nonce = vm.getNonce(DEFAULT_SENDER);

        // A stale record does not matter to a pinned contract, only what is on chain.
        vm.writeJson("[]", DEPLOYMENTS, string.concat(TRANSITION_ENTRY, ".constructor_args"));
        new FWSSDispatcherTransitionDeploy().run();
        assertEq(vm.getNonce(DEFAULT_SENDER), nonce);
        vm.writeFile(DEPLOYMENTS, recorded);

        address dispatcher = vm.parseJsonAddress(recorded, ".314.FWSS_DISPATCHER_ADDRESS");
        address otherMigration = address(viewContract);
        _writeLedger(proxy, otherMigration);
        FWSSDispatcherTransitionDeploy deploy = new FWSSDispatcherTransitionDeploy();
        vm.expectRevert(
            bytes(
                string.concat(
                    "the pinned FWSSDispatcherTransition ",
                    vm.toString(transition),
                    " does not pin the expected previous implementation ",
                    vm.toString(legacyImplementation),
                    ", dispatcher ",
                    vm.toString(dispatcher),
                    " and migration ",
                    vm.toString(otherMigration)
                )
            )
        );
        deploy.run();
    }

    function _deployRefusesAfterTransition() internal {
        address dispatcher = deployCode(DISPATCHER_ARTIFACT);
        vm.store(proxy, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(dispatcher))));
        FWSSDispatcherTransitionDeploy deploy = new FWSSDispatcherTransitionDeploy();

        vm.expectRevert(bytes("the proxy already runs the ERC-8167 dispatcher"));
        deploy.run();
    }

    /// @dev An upgrade with empty data leaves the proxy on the transition. A deploy rerun would otherwise pin a new
    /// transition to this one and overwrite the record; execute would revert without a reason inside the view read.
    function _scriptsRefuseProxyLeftOnTransition() internal {
        new FWSSDispatcherTransitionDeploy().run();
        string memory recorded = vm.readFile(DEPLOYMENTS);
        address transition = vm.parseJsonAddress(recorded, ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");
        vm.prank(DEFAULT_SENDER);
        service.announceUpgradePlan(transition, 0);
        (, uint96 afterEpoch) = viewContract.nextUpgrade();
        vm.roll(afterEpoch);
        vm.prank(DEFAULT_SENDER);
        service.upgradeToAndCall(transition, "");
        assertEq(_implementation(), transition);

        bytes memory reason = bytes(
            string.concat(
                "the proxy runs the transition ",
                vm.toString(transition),
                "; call migrate(migration) or abortTransition() on ",
                vm.toString(proxy)
            )
        );
        FWSSDispatcherTransitionDeploy deploy = new FWSSDispatcherTransitionDeploy();
        vm.expectRevert(reason);
        deploy.run();
        assertEq(vm.readFile(DEPLOYMENTS), recorded);

        FWSSDispatcherTransitionExecute execute = new FWSSDispatcherTransitionExecute();
        vm.expectRevert(reason);
        execute.run();

        // The owner finishes or aborts through the proxy.
        vm.prank(DEFAULT_SENDER);
        FWSSDispatcherTransition(proxy).abortTransition();
        assertEq(_implementation(), legacyImplementation);
    }

    function _executeFallsBackToViewContractAddress() internal {
        new FWSSDispatcherTransitionDeploy().run();
        string memory json = vm.readFile(DEPLOYMENTS);
        address dispatcher = vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_ADDRESS");
        address transition = vm.parseJsonAddress(json, ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");

        vm.writeFile(
            DEPLOYMENTS,
            string.concat(
                "{\"314\":{\"FWSS_PROXY_ADDRESS\":\"",
                vm.toString(proxy),
                "\",\"FWSS_DISPATCHER_TRANSITION_ADDRESS\":\"",
                vm.toString(transition),
                "\"}}\n"
            )
        );
        vm.prank(DEFAULT_SENDER);
        service.announceUpgradePlan(transition, 0);
        (, uint96 afterEpoch) = viewContract.nextUpgrade();
        vm.roll(afterEpoch);
        new FWSSDispatcherTransitionExecute().run();

        assertEq(_implementation(), dispatcher);
    }

    function _malformedEnvReverts() internal {
        FWSSDispatcherTransitionDeploy deploy = new FWSSDispatcherTransitionDeploy();
        uint256 nonce = vm.getNonce(DEFAULT_SENDER);

        // vm.envOr would read this as unset and deploy a dispatcher.
        vm.setEnv("FWSS_DISPATCHER_ADDRESS", "0x123");
        vm.expectRevert();
        deploy.run();
        assertEq(vm.getNonce(DEFAULT_SENDER), nonce);
        vm.setEnv("FWSS_DISPATCHER_ADDRESS", "");

        new FWSSDispatcherTransitionDeploy().run();
        address transition = vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), ".314.FWSS_DISPATCHER_TRANSITION_ADDRESS");
        vm.prank(DEFAULT_SENDER);
        service.announceUpgradePlan(transition, 0);
        (, uint96 afterEpoch) = viewContract.nextUpgrade();
        vm.roll(afterEpoch);
        FWSSDispatcherTransitionExecute execute = new FWSSDispatcherTransitionExecute();

        // vm.envOr would read this as false and upgrade.
        vm.setEnv("CALLDATA_ONLY", "yes");
        vm.expectRevert();
        execute.run();
        assertEq(_implementation(), legacyImplementation);
    }

    function _deployRejectsAmbiguousLedger() internal {
        FWSSDispatcherTransitionDeploy deploy = new FWSSDispatcherTransitionDeploy();
        string memory entry = string.concat(
            "{\"address\":\"",
            vm.toString(proxy),
            "\",\"deployments\":{\"314\":{\"proposed\":{\"migration\":{\"address\":\"",
            vm.toString(migration),
            "\"}}}}}"
        );

        // The duplicate comes after a non-matching entry, so the whole array is scanned.
        vm.writeFile(
            SCRATCH_LEDGER,
            string.concat("[", entry, ",{\"address\":\"0x000000000000000000000000000000000000dEaD\"},", entry, "]")
        );
        vm.expectRevert(abi.encodeWithSelector(JosukeLedger.ProxyListedTwice.selector, proxy));
        deploy.run();

        vm.writeFile(SCRATCH_LEDGER, string.concat("[", entry, ",{\"deployments\":null}]"));
        vm.expectRevert(abi.encodeWithSelector(JosukeLedger.LedgerEntryWithoutAddress.selector, 1));
        deploy.run();
    }

    /// @dev Restores the setUp state, fresh scratch files and an environment with only the scratch inputs set. An
    /// empty variable counts as unset.
    function _reset(uint256 clean) internal {
        vm.revertToState(clean);

        vm.createDir(SCRATCH, true);
        vm.copyFile("deployments.json", DEPLOYMENTS);
        _writeLedger(proxy, migration);

        vm.setEnv("DEPLOYMENTS_JSON_PATH", DEPLOYMENTS);
        vm.setEnv("JOSUKE_LEDGER", SCRATCH_LEDGER);
        vm.setEnv("GIT_COMMIT", GIT_COMMIT);
        vm.setEnv("FWSS_PROXY_ADDRESS", "");
        vm.setEnv("FWSS_DISPATCHER_ADDRESS", "");
        vm.setEnv("FWSS_DISPATCHER_TRANSITION_ADDRESS", "");
        vm.setEnv("FWSS_VIEW_ADDRESS", "");
        vm.setEnv("CALLDATA_ONLY", "");
    }

    /// @dev Writes a one-entry ledger in the shape `josuke deploy` leaves; no proposal when `proposed` is zero.
    function _writeLedger(address ledgerProxy, address proposed) internal {
        string memory deployments = proposed == address(0)
            ? "null"
            : string.concat(
                "{\"314\":{\"proposed\":{\"gitCommit\":\"",
                GIT_COMMIT,
                "\",\"migration\":{\"address\":\"",
                vm.toString(proposed),
                "\"}}}}"
            );
        vm.writeFile(
            SCRATCH_LEDGER,
            string.concat(
                "[{\"address\":\"",
                vm.toString(ledgerProxy),
                "\",\"facetSrc\":[\"src/modules/*.sol\",\"lib/erc8167/src/Implementation.evm\"],\"deployments\":",
                deployments,
                "}]"
            )
        );
    }

    /// @dev The config and dataset facets pin the same immutables as the v1.4.0 monolith they replace.
    function _facetConstructorArgs(string memory sourceId) internal view override returns (bytes memory) {
        if (keccak256(bytes(sourceId)) == keccak256("src/modules/FWSSConfigModule.sol:FWSSConfigModule")) {
            return
                abi.encode(service.paymentsContractAddress(), service.pdpVerifierAddress(), service.usdfcTokenAddress());
        }
        if (keccak256(bytes(sourceId)) == keccak256("src/modules/FWSSDataSetModule.sol:FWSSDataSetModule")) {
            return abi.encode(
                service.usdfcTokenAddress(),
                service.filBeamBeneficiaryAddress(),
                service.serviceProviderRegistry(),
                service.sessionKeyRegistry()
            );
        }
        if (keccak256(bytes(sourceId)) == keccak256("src/modules/FWSSPaymentModule.sol:FWSSPaymentModule")) {
            return abi.encode(service.usdfcTokenAddress(), service.sessionKeyRegistry());
        }
        return super._facetConstructorArgs(sourceId);
    }

    function _createMigration() internal returns (address) {
        SetDelegateOperation[] memory routes = _deployFacetRoutes(_resolveFacets(MAINNET_INDEX));
        SetDelegateOperationLibrary.validate(routes);

        for (uint256 i; i < routes.length; ++i) {
            exportedSelectors.push(routes[i].selector);
            routedTo[routes[i].selector] = routes[i].delegate;
        }

        return Migration.createMigration(routes);
    }

    function _assertTransitionRecord(string memory json, address dispatcher) internal view {
        string[] memory keys = vm.parseJsonKeys(json, TRANSITION_ENTRY);
        assertEq(keys.length, 4);
        assertEq(keys[0], "initcode_hash");
        assertEq(keys[1], "artifact_contract");
        assertEq(keys[2], "libraries");
        assertEq(keys[3], "constructor_args");

        // The legacy hash strips a CBOR trailer, which this artifact has none of: its last two bytes read as a length
        // beyond the code, so the hash covers the whole initcode.
        bytes memory initcode = vm.getCode(TRANSITION_ARTIFACT);
        uint256 trailer = uint16(bytes2(abi.encodePacked(initcode[initcode.length - 2], initcode[initcode.length - 1])));
        assertGe(trailer + 2, initcode.length, "the legacy CBOR strip now changes the transition initcode");
        assertEq(vm.parseJsonBytes32(json, string.concat(TRANSITION_ENTRY, ".initcode_hash")), keccak256(initcode));

        assertEq(vm.parseJsonString(json, string.concat(TRANSITION_ENTRY, ".artifact_contract")), TRANSITION_ARTIFACT);
        assertEq(vm.parseJsonKeys(json, string.concat(TRANSITION_ENTRY, ".libraries")).length, 0);

        string[] memory args = vm.parseJsonStringArray(json, string.concat(TRANSITION_ENTRY, ".constructor_args"));
        assertEq(args.length, 3);
        assertEq(args[0], vm.toString(legacyImplementation));
        assertEq(args[1], vm.toString(dispatcher));
        assertEq(args[2], vm.toString(migration));
        for (uint256 i; i < args.length; ++i) {
            _assertChecksummed(args[i]);
        }
    }

    function _assertChecksummed(string memory value) internal pure {
        assertEq(vm.toString(vm.parseAddress(value)), value, "not EIP-55");
    }

    /// @dev YYYY-MM-DDTHH:MM:SSZ
    function _assertIsoTimestamp(string memory value) internal pure {
        bytes memory raw = bytes(value);
        assertEq(raw.length, 20);
        for (uint256 i; i < raw.length; ++i) {
            if (i == 4 || i == 7) assertEq(raw[i], bytes1("-"));
            else if (i == 10) assertEq(raw[i], bytes1("T"));
            else if (i == 13 || i == 16) assertEq(raw[i], bytes1(":"));
            else if (i == 19) assertEq(raw[i], bytes1("Z"));
            else assertTrue(raw[i] >= "0" && raw[i] <= "9", value);
        }
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    /// @dev Ported from FWSSDispatcherTest._assertFacetRoutes.
    function _assertFacetRoutes() internal view {
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
}

/// @dev Runs the deploy script as `forge script` without `--broadcast` does
contract DryRunDeploy is FWSSDispatcherTransitionDeploy {
    function _isDryRun() internal pure override returns (bool) {
        return true;
    }
}

/// @dev Runs the deploy script as `forge script --broadcast` does
contract BroadcastDeploy is FWSSDispatcherTransitionDeploy {
    function _isBroadcast() internal pure override returns (bool) {
        return true;
    }
}
