// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {FilecoinWarmStorageService} from "../../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../../src/FilecoinWarmStorageServiceStateView.sol";
import {AdminModule} from "../../src/modules/AdminModule.sol";
import {IFilecoinServiceMetadata} from "../../src/IFilecoinServiceMetadata.sol";

contract AdminModuleTest is Test {
    bytes32 private constant OWNABLE_STORAGE_LOCATION =
        0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    AdminModule public adminModule;

    function setUp() public {
        AdminModule implementation = new AdminModule();
        MyERC1967Proxy proxy = new MyERC1967Proxy(address(implementation), "");
        adminModule = AdminModule(address(proxy));
        vm.store(address(proxy), OWNABLE_STORAGE_LOCATION, bytes32(uint256(uint160(address(this)))));
    }

    function testServiceMetadata() public view {
        IFilecoinServiceMetadata metadata = IFilecoinServiceMetadata(address(adminModule));
        string memory serviceName = metadata.name();
        string memory serviceDescription = metadata.description();
        string memory serviceHomepage = metadata.homepage();

        assertEq(serviceName, "Filecoin Warm Storage Service", "Service name should match");
        assertEq(
            serviceDescription,
            "Warm storage service for the Filecoin Onchain Cloud. Manages PDP-backed datasets, Filecoin Pay storage rails, lifecycle fees, and optional CDN payment rails.",
            "Service description should match"
        );
        assertEq(serviceHomepage, "https://github.com/FilOzone/filecoin-services", "Service homepage should match");
        assertLe(bytes(serviceDescription).length, 256, "Service description should not exceed 256 bytes");
        assertLe(bytes(serviceHomepage).length, 256, "Service homepage should not exceed 256 bytes");
    }

    function testSetViewContract() public {
        // Deploy view contract
        FilecoinWarmStorageServiceStateView viewContract = new FilecoinWarmStorageServiceStateView(FilecoinWarmStorageService(address(adminModule)));

        // Set view contract
        adminModule.setViewContract(address(viewContract));

        // Verify it was set
        assertEq(adminModule.viewContractAddress(), address(viewContract), "View contract should be set");

        // Test that non-owner cannot set view contract
        vm.prank(address(0x123));
        vm.expectRevert();
        adminModule.setViewContract(address(0x456));

        // Test that it cannot be set again (one-time only)
        // NOTE: This check is commented out to allow setting the view contract easily during migrations prior to GA
        //       GH ISSUE: https://github.com/FilOzone/filecoin-services/issues/303
        //       This check needs to be re-enabled before mainnet deployment to prevent changing the view contract later.

        // FilecoinWarmStorageServiceStateView newViewContract =
        //     new FilecoinWarmStorageServiceStateView(FilecoinWarmStorageService(address(adminModule)));
        // vm.expectRevert(abi.encodeWithSelector(Errors.AddressAlreadySet.selector, Errors.AddressField.View));
        // adminModule.setViewContract(address(newViewContract));

        // Test that zero address is rejected (would need a new contract to test this properly)
        // This is now unreachable in this test since view contract is already set
    }
}
