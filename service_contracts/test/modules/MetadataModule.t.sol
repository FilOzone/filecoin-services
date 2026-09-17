// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {MetadataModule} from "../../src/modules/MetadataModule.sol";
import {IFilecoinServiceMetadata} from "../../src/IFilecoinServiceMetadata.sol";

contract MetadataModuleTest is Test {
    MetadataModule public metadataModule;

    function setUp() public {
        metadataModule = new MetadataModule();
    }

    function testServiceMetadata() public view {
        IFilecoinServiceMetadata metadata = IFilecoinServiceMetadata(address(metadataModule));
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
}
