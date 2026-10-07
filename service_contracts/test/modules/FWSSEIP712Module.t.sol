// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {FWSSEIP712Module} from "../../src/modules/FWSSEIP712Module.sol";

/// @dev Initializes the shared OpenZeppelin domain storage before installing the module.
contract FWSSEIP712Initializer is EIP712Upgradeable {
    function initialize(string memory name, string memory version) external initializer {
        __EIP712_init(name, version);
    }
}

contract FWSSEIP712ModuleTest is Test {
    string private constant DOMAIN_NAME = "FilecoinWarmStorageService";
    string private constant DOMAIN_VERSION = "1";

    FWSSEIP712Module private implementation;
    FWSSEIP712Module private domainModule;

    function setUp() public {
        implementation = new FWSSEIP712Module();
        domainModule = _deployProxy();
    }

    function _deployProxy() private returns (FWSSEIP712Module) {
        FWSSEIP712Initializer domainInitializer = new FWSSEIP712Initializer();
        MyERC1967Proxy proxy = new MyERC1967Proxy(
            address(domainInitializer), abi.encodeCall(FWSSEIP712Initializer.initialize, (DOMAIN_NAME, DOMAIN_VERSION))
        );
        vm.store(address(proxy), ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(implementation)))));
        return FWSSEIP712Module(address(proxy));
    }

    function _expectedSeparator(address proxy) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(DOMAIN_NAME)),
                keccak256(bytes(DOMAIN_VERSION)),
                block.chainid,
                proxy
            )
        );
    }

    function testEIP712DomainReadsInitializedProxyStorage() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = domainModule.eip712Domain();

        assertEq(uint8(fields), 0x0f);
        assertEq(name, DOMAIN_NAME);
        assertEq(version, DOMAIN_VERSION);
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(domainModule));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function testDomainSeparatorUsesInitializedDomainAndProxyAddress() public view {
        assertEq(domainModule.domainSeparatorV4(), _expectedSeparator(address(domainModule)));
    }

    function testDomainSeparatorUpdatesWithChainId() public {
        bytes32 previousSeparator = domainModule.domainSeparatorV4();
        vm.chainId(block.chainid + 1);

        assertEq(domainModule.domainSeparatorV4(), _expectedSeparator(address(domainModule)));
        assertTrue(domainModule.domainSeparatorV4() != previousSeparator);
    }

    function testDomainSeparatorDiffersBetweenProxies() public {
        FWSSEIP712Module otherProxy = _deployProxy();

        assertEq(otherProxy.domainSeparatorV4(), _expectedSeparator(address(otherProxy)));
        assertTrue(domainModule.domainSeparatorV4() != otherProxy.domainSeparatorV4());
    }
}
