// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {FWSSDispatcherTransition} from "../src/FWSSDispatcherTransition.sol";
import {ERC8167Transition} from "../src/lib/ERC8167Transition.sol";

contract FWSSDispatcherTransitionTest is Test {
    address internal dispatcher;
    address internal migration;

    function setUp() public {
        dispatcher = deployCode("lib/erc8167/out/Proxy.evm/Proxy.json");
        migration = address(0x5EED);
        vm.etch(migration, hex"00");
    }

    function testConstructorPinsDispatcherAndMigration() public {
        FWSSDispatcherTransition transition = new FWSSDispatcherTransition(dispatcher, migration);

        assertEq(transition.dispatcher(), dispatcher);
        assertEq(transition.migration(), migration);
        assertEq(transition.migrationCodeHash(), migration.codehash);
    }

    function testConstructorRejectsInvalidAddresses() public {
        address fake = address(0xF00D);
        vm.etch(fake, new bytes(88));

        vm.expectRevert(ERC8167Transition.InvalidTransition.selector);
        new FWSSDispatcherTransition(fake, migration);
        vm.expectRevert(ERC8167Transition.InvalidTransition.selector);
        new FWSSDispatcherTransition(address(0), migration);
        vm.expectRevert(ERC8167Transition.InvalidTransition.selector);
        new FWSSDispatcherTransition(dispatcher, address(0x1234));
    }

    function testProxiableOnlyWhenCalledDirectly() public {
        FWSSDispatcherTransition transition = new FWSSDispatcherTransition(dispatcher, migration);
        assertEq(transition.proxiableUUID(), ERC1967Utils.IMPLEMENTATION_SLOT);

        vm.expectRevert(ERC8167Transition.UnauthorizedCallContext.selector);
        transition.migrate(migration);
    }

    /// @dev v1.4.0 announceUpgradePlan rejects implementations of 3000 bytes or less.
    function testCodeExceedsLegacyAnnouncementFloor() public {
        FWSSDispatcherTransition transition = new FWSSDispatcherTransition(dispatcher, migration);
        assertGt(address(transition).code.length, 3000);
    }
}
