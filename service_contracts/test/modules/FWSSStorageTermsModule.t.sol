// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";
import {FWSSStorageTermsModule} from "../../src/modules/FWSSStorageTermsModule.sol";
import {FWSSOwnable} from "../../src/lib/FWSSOwnable.sol";
import {LibStorageTerms} from "../../src/lib/LibStorageTerms.sol";
import {StorageTerms} from "../../src/lib/StorageTerms.sol";

contract StorageTermsDecimalsToken {
    uint8 private immutable tokenDecimals;

    constructor(uint8 tokenDecimals_) {
        tokenDecimals = tokenDecimals_;
    }

    function decimals() external view returns (uint8) {
        return tokenDecimals;
    }
}

contract FWSSStorageTermsModuleTest is FilecoinWarmStorageServiceFixture {
    function _terms() private view returns (StorageTerms memory) {
        return StorageTerms({
            token: address(mockUSDFC), tokenDecimals: 18, salt: bytes32("terms"), pricePerTiBPerMonth: 2.5 ether
        });
    }

    function _module() private view returns (FWSSStorageTermsModule) {
        return FWSSStorageTermsModule(address(pdpServiceWithPayments));
    }

    function testFreshDeploymentInitializesLegacyTerms() public view {
        (StorageTerms memory terms, bool enabled) = _module().getStorageTerms(bytes32(0));
        assertEq(terms.token, address(mockUSDFC));
        assertEq(terms.tokenDecimals, 18);
        assertEq(terms.salt, bytes32(0));
        assertEq(terms.pricePerTiBPerMonth, 2.5 ether);
        assertTrue(enabled);
    }

    function testRegisterDisableAndReregisterTerms() public {
        StorageTerms memory terms = _terms();
        bytes32 id = _module().registerStorageTerms(terms);
        assertEq(id, _module().getStorageTermsId(terms));

        (StorageTerms memory stored, bool enabled) = _module().getStorageTerms(id);
        assertEq(stored.token, terms.token);
        assertEq(stored.tokenDecimals, terms.tokenDecimals);
        assertEq(stored.salt, terms.salt);
        assertEq(stored.pricePerTiBPerMonth, terms.pricePerTiBPerMonth);
        assertTrue(enabled);

        _module().disableStorageTerms(id);
        (, enabled) = _module().getStorageTerms(id);
        assertFalse(enabled);
        _module().registerStorageTerms(terms);
        (, enabled) = _module().getStorageTerms(id);
        assertTrue(enabled);
    }

    function testDistinctSaltsHaveIndependentEnabledStateAndMaxPriceRoundTrips() public {
        StorageTerms memory first = _terms();
        StorageTerms memory second = _terms();
        second.salt = bytes32("other");
        second.pricePerTiBPerMonth = type(uint96).max;

        bytes32 firstId = _module().registerStorageTerms(first);
        bytes32 secondId = _module().registerStorageTerms(second);
        assertTrue(firstId != secondId);

        _module().disableStorageTerms(firstId);
        (, bool firstEnabled) = _module().getStorageTerms(firstId);
        (StorageTerms memory storedSecond, bool secondEnabled) = _module().getStorageTerms(secondId);
        assertFalse(firstEnabled);
        assertTrue(secondEnabled);
        assertEq(storedSecond.pricePerTiBPerMonth, type(uint96).max);
    }

    function testLegacyIdCanonicalizesToZeroAndCanBeDisabled() public {
        StorageTerms memory legacy = StorageTerms({
            token: address(mockUSDFC), tokenDecimals: 18, salt: bytes32(0), pricePerTiBPerMonth: 2.5 ether
        });
        assertEq(_module().getStorageTermsId(legacy), bytes32(0));
        _module().disableStorageTerms(bytes32(0));
        (, bool enabled) = _module().getStorageTerms(bytes32(0));
        assertFalse(enabled);
    }

    function testOnlyOwnerMayRegisterOrDisable() public {
        StorageTerms memory terms = _terms();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, client));
        _module().registerStorageTerms(terms);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, client));
        _module().disableStorageTerms(bytes32(0));
    }

    function testRejectsUnknownTermsAndInvalidDecimalsOrPrice() public {
        vm.expectRevert(abi.encodeWithSelector(LibStorageTerms.UnknownStorageTerms.selector, bytes32(uint256(1))));
        _module().getStorageTerms(bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(LibStorageTerms.UnknownStorageTerms.selector, bytes32(uint256(1))));
        _module().disableStorageTerms(bytes32(uint256(1)));

        StorageTerms memory invalidDecimals = _terms();
        invalidDecimals.tokenDecimals = 17;
        vm.expectRevert(abi.encodeWithSelector(FWSSStorageTermsModule.InvalidTokenDecimals.selector, uint8(17)));
        _module().registerStorageTerms(invalidDecimals);

        StorageTerms memory lowPrice = _terms();
        lowPrice.pricePerTiBPerMonth = 2.5 ether - 1;
        vm.expectPartialRevert(FWSSStorageTermsModule.PriceBelowMinimum.selector);
        _module().registerStorageTerms(lowPrice);
    }

    function testRejectsTokenDecimalsAboveEighteen() public {
        StorageTerms memory terms = StorageTerms({
            token: address(new StorageTermsDecimalsToken(19)),
            tokenDecimals: 19,
            salt: bytes32("nineteen"),
            pricePerTiBPerMonth: 1
        });
        vm.expectRevert(abi.encodeWithSelector(FWSSStorageTermsModule.InvalidTokenDecimals.selector, uint8(19)));
        _module().registerStorageTerms(terms);
    }

    function testRoundsMinimumPriceUpForZeroDecimalTokens() public {
        address token = address(new StorageTermsDecimalsToken(0));
        StorageTerms memory low =
            StorageTerms({token: token, tokenDecimals: 0, salt: bytes32("zero-low"), pricePerTiBPerMonth: 2});
        vm.expectRevert(
            abi.encodeWithSelector(FWSSStorageTermsModule.PriceBelowMinimum.selector, uint96(2), uint256(3))
        );
        _module().registerStorageTerms(low);

        StorageTerms memory minimum = low;
        minimum.salt = bytes32("zero-minimum");
        minimum.pricePerTiBPerMonth = 3;
        _module().registerStorageTerms(minimum);
    }

    function testRegistersNativeTermsAtEighteenDecimals() public {
        StorageTerms memory nativeTerms = StorageTerms({
            token: address(0), tokenDecimals: 18, salt: bytes32("native"), pricePerTiBPerMonth: 2.5 ether
        });
        bytes32 id = _module().registerStorageTerms(nativeTerms);
        (StorageTerms memory stored, bool enabled) = _module().getStorageTerms(id);
        assertEq(stored.token, address(0));
        assertTrue(enabled);
    }
}
