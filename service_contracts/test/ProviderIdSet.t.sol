pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {ProviderIdSet} from "../src/ProviderIdSet.sol";

contract ProviderIdSetTest is Test {
    ProviderIdSet set;

    function setUp() public {
        set = new ProviderIdSet();
    }

    function testAddGet() public {
        for (uint256 i = 0; i < 300; i++) {
            uint256[] memory providerIds = set.getProviderIds();
            assertEq(providerIds.length, i);
            for (uint256 j = 0; j < i; j++) {
                assertEq(providerIds[j], j * j + 1);
            }
            assertFalse(set.containsProviderId(i * i + 1));
            set.addProviderId(i * i + 1);
            assertTrue(set.containsProviderId(i * i + 1));
        }
    }

    function testOwnable() public {
        assertEq(set.owner(), address(this));

        address other = makeAddr("another");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        set.addProviderId(1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        set.removeProviderId(1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        set.transferOwnership(address(0));

        set.transferOwnership(other);
        assertEq(set.owner(), other);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        set.renounceOwnership();

        vm.prank(other);
        set.renounceOwnership();

        assertEq(set.owner(), address(0));
    }

    function testAddDuplicates() public {
        assertFalse(set.containsProviderId(300));
        for (uint256 i = 0; i < 10; i++) {
            set.addProviderId(300);
            assertTrue(set.containsProviderId(300));
            uint256[] memory providerIds = set.getProviderIds();
            assertEq(providerIds.length, 1);
            assertEq(providerIds[0], 300);
        }
    }

    function testAddManyDuplicates() public {
        for (uint256 i = 0; i < 3; i++) {
            // adding zero is a no-op
            for (uint256 j = 0; j <= 35; j++) {
                set.addProviderId(j);
            }
            uint256[] memory providerIds = set.getProviderIds();
            assertEq(providerIds.length, 35);
            for (uint256 j = 1; j <= 35; j++) {
                assertEq(providerIds[j - 1], j);
            }
        }
    }

    function testProviderIdTooLarge() public {
        vm.expectRevert(abi.encodeWithSelector(ProviderIdSet.ProviderIdTooLarge.selector, 0x100000000));
        set.addProviderId(0x100000000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProviderIdSet.ProviderIdTooLarge.selector,
                0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
            )
        );
        set.addProviderId(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);

        set.addProviderId(0xffffffff);
        assertTrue(set.containsProviderId(0xffffffff));
    }

    function testRemoveFIFO() public {
        for (uint256 resets = 0; resets < 2; resets++) {
            for (uint256 i = 0; i < 36; i++) {
                assertEq(set.getProviderIds().length, i);
                set.addProviderId(36 - i);
                assertTrue(set.containsProviderId(36 - i));
            }
            unchecked {
                for (uint256 size = 36; size <= 36; size--) {
                    uint256[] memory providerIds = set.getProviderIds();
                    assertEq(providerIds.length, size);
                    uint256 checkSum = 0;
                    for (uint256 i = 0; i < size; i++) {
                        checkSum += providerIds[i];
                        checkSum -= i + 1;
                    }
                    assertEq(int256(checkSum), 0);
                    for (uint256 i = size + 1; i <= 36; i++) {
                        vm.expectRevert(abi.encodeWithSelector(ProviderIdSet.ProviderIdNotFound.selector, i));
                        set.removeProviderId(i);
                    }
                    if (size > 0) {
                        assertTrue(set.containsProviderId(size));
                        set.removeProviderId(size);
                        assertFalse(set.containsProviderId(size));
                    }
                }
            }
        }
    }

    function testRemoveLIFO() public {
        for (uint256 resets = 0; resets < 2; resets++) {
            for (uint256 i = 0; i < 36; i++) {
                assertEq(set.getProviderIds().length, i);
                set.addProviderId(i + 1);
            }
            unchecked {
                for (uint256 size = 36; size <= 36; size--) {
                    uint256[] memory providerIds = set.getProviderIds();
                    assertEq(providerIds.length, size);
                    uint256 checkSum = 0;
                    for (uint256 i = 0; i < size; i++) {
                        checkSum += providerIds[i];
                        checkSum -= i + 1;
                    }
                    assertEq(int256(checkSum), 0);
                    for (uint256 i = size + 1; i <= 36; i++) {
                        vm.expectRevert(abi.encodeWithSelector(ProviderIdSet.ProviderIdNotFound.selector, i));
                        set.removeProviderId(i);
                    }
                    if (size > 0) {
                        assertTrue(set.containsProviderId(size));
                        set.removeProviderId(size);
                        assertFalse(set.containsProviderId(size));
                    }
                }
            }
        }
    }

    function testAddRemoveLargeIds() public {
        for (uint256 shift = 0; shift < 32; shift++) {
            assertEq(set.getProviderIds().length, shift);
            assertFalse(set.containsProviderId(1 << shift));
            set.addProviderId(1 << shift);
            assertTrue(set.containsProviderId(1 << shift));
        }
        uint256 removed = 0;
        for (uint256 shift = 0; shift < 32; shift++) {
            uint256[] memory providerIds = set.getProviderIds();
            assertEq(providerIds.length, 32 - shift);
            uint256 found = 0;
            for (uint256 i = 0; i < providerIds.length; i++) {
                // only one bit is set in these providerIds
                assertEq(providerIds[i] & (providerIds[i] - 1), 0);

                found ^= providerIds[i];
            }
            assertEq(found ^ removed, 0xffffffff);

            assertTrue(set.containsProviderId(1 << shift));
            set.removeProviderId(1 << shift);
            assertFalse(set.containsProviderId(1 << shift));
            removed |= 1 << shift;
        }
        assertEq(set.getProviderIds().length, 0);
    }
}
