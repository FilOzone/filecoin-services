// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";
import {FWSSStorageTermsModule} from "../../src/modules/FWSSStorageTermsModule.sol";
import {FWSSOwnable} from "../../src/lib/FWSSOwnable.sol";
import {LibStorageTerms} from "../../src/lib/LibStorageTerms.sol";
import {PAY_VERSION_FILECOIN_PAY_V1, PAY_VERSION_FILECOIN_PAY_V2, StorageTerms} from "../../src/lib/StorageTerms.sol";

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
            token: address(mockUSDFC),
            tokenDecimals: 18,
            salt: bytes32("terms"),
            pricePerTiBPerMonth: 2.5 ether,
            payVersion: 0
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
        assertEq(terms.payVersion, PAY_VERSION_FILECOIN_PAY_V1);
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

    function testLegacyDefinitionRegistersIndependentHashedRecord() public {
        StorageTerms memory legacy = StorageTerms({
            token: address(mockUSDFC),
            tokenDecimals: 18,
            salt: bytes32(0),
            pricePerTiBPerMonth: 2.5 ether,
            payVersion: 0
        });
        bytes32 id = _module().registerStorageTerms(legacy);
        assertEq(
            id,
            keccak256(
                abi.encode(
                    keccak256("filecoin.FWSS.StorageTerms.v1"),
                    legacy.token,
                    legacy.tokenDecimals,
                    legacy.salt,
                    legacy.pricePerTiBPerMonth
                )
            )
        );
        _module().disableStorageTerms(id);
        (, bool hashedEnabled) = _module().getStorageTerms(id);
        (, bool legacyEnabled) = _module().getStorageTerms(bytes32(0));
        assertFalse(hashedEnabled);
        assertTrue(legacyEnabled);
    }

    function testCannotDisableLegacyStorageTerms() public {
        vm.expectRevert(LibStorageTerms.CannotDisableLegacyStorageTerms.selector);
        _module().disableStorageTerms(bytes32(0));
    }

    function testFuzzStorageTermsIdMatchesAbiEncoding(
        address token,
        uint8 tokenDecimals,
        bytes32 salt,
        uint96 pricePerTiBPerMonth
    ) public view {
        StorageTerms memory terms = StorageTerms({
            token: token,
            tokenDecimals: tokenDecimals,
            salt: salt,
            pricePerTiBPerMonth: pricePerTiBPerMonth,
            payVersion: 0
        });
        bytes32 expected = keccak256(
            abi.encode(keccak256("filecoin.FWSS.StorageTerms.v1"), token, tokenDecimals, salt, pricePerTiBPerMonth)
        );
        assertEq(_module().getStorageTermsId(terms), expected);
    }

    function testFilecoinPayV1TermsIdKeepsItsReleasedValue() public view {
        // Computed off-chain with the 1.6.0 formula; payVersion zero must not move existing ids
        StorageTerms memory terms = StorageTerms({
            token: address(0xFC),
            tokenDecimals: 18,
            salt: bytes32(0),
            pricePerTiBPerMonth: 2.5 ether,
            payVersion: PAY_VERSION_FILECOIN_PAY_V1
        });
        assertEq(_module().getStorageTermsId(terms), 0xb443f8b8a6e0df472f91d087eea5f70f2c4501b3ff2f6c90b3741e937415d333);
    }

    function testFuzzPayV2StorageTermsIdMatchesAbiEncoding(
        address token,
        uint8 tokenDecimals,
        bytes32 salt,
        uint96 pricePerTiBPerMonth
    ) public view {
        StorageTerms memory terms = StorageTerms({
            token: token,
            tokenDecimals: tokenDecimals,
            salt: salt,
            pricePerTiBPerMonth: pricePerTiBPerMonth,
            payVersion: PAY_VERSION_FILECOIN_PAY_V2
        });
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("filecoin.FWSS.StorageTerms.v2"),
                token,
                tokenDecimals,
                salt,
                pricePerTiBPerMonth,
                PAY_VERSION_FILECOIN_PAY_V2
            )
        );
        assertEq(_module().getStorageTermsId(terms), expected);
    }

    function testPayV2TermsGetTheirOwnRecordBesideTheirV1Twin() public {
        StorageTerms memory v1Terms = _terms();
        StorageTerms memory v2Terms = _terms();
        v2Terms.payVersion = PAY_VERSION_FILECOIN_PAY_V2;

        bytes32 v1Id = _module().registerStorageTerms(v1Terms);
        bytes32 v2Id = _module().registerStorageTerms(v2Terms);
        assertNotEq(v1Id, v2Id);

        (StorageTerms memory storedV1,) = _module().getStorageTerms(v1Id);
        (StorageTerms memory storedV2, bool v2Enabled) = _module().getStorageTerms(v2Id);
        assertEq(storedV1.payVersion, PAY_VERSION_FILECOIN_PAY_V1);
        assertEq(storedV2.payVersion, PAY_VERSION_FILECOIN_PAY_V2);
        assertEq(storedV2.pricePerTiBPerMonth, v1Terms.pricePerTiBPerMonth);
        assertTrue(v2Enabled);

        _module().disableStorageTerms(v1Id);
        (, v2Enabled) = _module().getStorageTerms(v2Id);
        assertTrue(v2Enabled);
    }

    function testRejectsUnsupportedPayVersion() public {
        StorageTerms memory terms = _terms();
        terms.payVersion = PAY_VERSION_FILECOIN_PAY_V2 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                FWSSStorageTermsModule.UnsupportedPayVersion.selector, PAY_VERSION_FILECOIN_PAY_V2 + 1
            )
        );
        _module().registerStorageTerms(terms);
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
            pricePerTiBPerMonth: 1,
            payVersion: 0
        });
        vm.expectRevert(abi.encodeWithSelector(FWSSStorageTermsModule.InvalidTokenDecimals.selector, uint8(19)));
        _module().registerStorageTerms(terms);
    }

    function testRoundsMinimumPriceUpForZeroDecimalTokens() public {
        address token = address(new StorageTermsDecimalsToken(0));
        StorageTerms memory low = StorageTerms({
            token: token, tokenDecimals: 0, salt: bytes32("zero-low"), pricePerTiBPerMonth: 2, payVersion: 0
        });
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
            token: address(0), tokenDecimals: 18, salt: bytes32("native"), pricePerTiBPerMonth: 2.5 ether, payVersion: 0
        });
        bytes32 id = _module().registerStorageTerms(nativeTerms);
        (StorageTerms memory stored, bool enabled) = _module().getStorageTerms(id);
        assertEq(stored.token, address(0));
        assertTrue(enabled);
    }
}
