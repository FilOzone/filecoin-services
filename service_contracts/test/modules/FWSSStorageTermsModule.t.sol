// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {Errors} from "../../src/Errors.sol";
import {TOKEN_DECIMALS} from "../../src/lib/PriceListUSDFC.sol";
import {StorageTerms} from "../../src/lib/StorageTerms.sol";
import {FWSSStorageTermsModule} from "../../src/modules/FWSSStorageTermsModule.sol";
import {STORAGE_TERMS_STORAGE_LOCATION} from "../../src/storage/FWSSStorageTerms.sol";
import {MockERC20} from "../mocks/SharedMocks.sol";
import {SixDecimalToken} from "../mocks/SixDecimalToken.sol";

contract FWSSStorageTermsModuleTest is Test {
    bytes32 private constant OWNABLE_STORAGE_LOCATION =
        0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    FWSSStorageTermsModule internal module;
    MockERC20 internal usdfc;
    SixDecimalToken internal six;

    event StorageTermsRegistered(
        bytes32 indexed storageTermsId, address token, uint8 tokenDecimals, uint96 pricePerTiBPerMonth, bytes32 salt
    );
    event StorageTermsDisabled(bytes32 indexed storageTermsId);

    function setUp() public {
        usdfc = new MockERC20();
        six = new SixDecimalToken();
        FWSSStorageTermsModule implementation = new FWSSStorageTermsModule(usdfc);
        MyERC1967Proxy proxy = new MyERC1967Proxy(address(implementation), "");
        module = FWSSStorageTermsModule(address(proxy));
        vm.store(address(proxy), OWNABLE_STORAGE_LOCATION, bytes32(uint256(uint160(address(this)))));
    }

    function _sixTerms() internal view returns (StorageTerms memory) {
        return
            StorageTerms({token: address(six), tokenDecimals: 6, pricePerTiBPerMonth: 5e6, salt: bytes32(uint256(6))});
    }

    function _recordSlot(bytes32 id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(id, STORAGE_TERMS_STORAGE_LOCATION)));
    }

    function _head(bytes32 id) internal view returns (uint256) {
        return uint256(vm.load(address(module), bytes32(_recordSlot(id))));
    }

    function _id(StorageTerms memory terms) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("filecoin.FWSS.StorageTerms.v1"),
                terms.token,
                terms.tokenDecimals,
                uint256(terms.pricePerTiBPerMonth),
                terms.salt
            )
        );
    }

    function testRegisterWritesRecordAndEmits() public {
        StorageTerms memory terms = _sixTerms();
        bytes32 expectedId = _id(terms);
        vm.expectEmit(true, false, false, true, address(module));
        emit StorageTermsRegistered(expectedId, address(six), 6, 5e6, terms.salt);
        assertEq(module.registerStorageTerms(terms), expectedId);

        uint256 slot = _recordSlot(expectedId);
        assertEq(_head(expectedId), uint256(uint160(address(six))) | (6 << 160) | (1 << 168) | (1 << 176));
        assertEq(uint256(vm.load(address(module), bytes32(slot + 1))), 5e6);
        assertEq(vm.load(address(module), bytes32(slot + 2)), terms.salt);
    }

    function testReRegisterReEnables() public {
        StorageTerms memory terms = _sixTerms();
        bytes32 id = module.registerStorageTerms(terms);
        module.disableStorageTerms(id);
        assertEq(_head(id) >> 176, 0, "disabled");

        vm.expectEmit(true, false, false, true, address(module));
        emit StorageTermsRegistered(id, address(six), 6, 5e6, terms.salt);
        assertEq(module.registerStorageTerms(terms), id);
        assertEq(_head(id), uint256(uint160(address(six))) | (6 << 160) | (1 << 168) | (1 << 176));
    }

    function testDisableEmitsAndKeepsDefinition() public {
        StorageTerms memory terms = _sixTerms();
        bytes32 id = module.registerStorageTerms(terms);
        vm.expectEmit(true, false, false, false, address(module));
        emit StorageTermsDisabled(id);
        module.disableStorageTerms(id);

        uint256 slot = _recordSlot(id);
        assertEq(_head(id), uint256(uint160(address(six))) | (6 << 160) | (1 << 168), "version kept, enabled cleared");
        assertEq(uint256(vm.load(address(module), bytes32(slot + 1))), 5e6);
        assertEq(vm.load(address(module), bytes32(slot + 2)), terms.salt);

        // Disabling twice is idempotent
        module.disableStorageTerms(id);
        assertEq(_head(id) >> 176, 0);
    }

    function testLegacyCannotBeDisabledEvenWhenRegistered() public {
        StorageTerms memory legacy =
            StorageTerms({token: address(usdfc), tokenDecimals: 18, pricePerTiBPerMonth: 2.5e18, salt: bytes32(0)});
        vm.expectRevert(Errors.LegacyStorageTermsCannotBeDisabled.selector);
        module.disableStorageTerms(_id(legacy));

        assertEq(module.registerStorageTerms(legacy), _id(legacy));
        vm.expectRevert(Errors.LegacyStorageTermsCannotBeDisabled.selector);
        module.disableStorageTerms(_id(legacy));
    }

    function testConstructorRejectsZeroUsdfc() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.USDFC));
        new FWSSStorageTermsModule(IERC20Metadata(address(0)));
    }

    function testFuzzConstructorRejectsIncorrectTokenDecimals(uint8 decimals) public {
        vm.assume(decimals != TOKEN_DECIMALS);
        vm.mockCall(address(usdfc), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(decimals));

        vm.expectRevert();
        new FWSSStorageTermsModule(usdfc);
    }
}
