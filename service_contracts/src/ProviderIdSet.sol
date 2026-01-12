pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// This linear design assumes that the set is small and sparse
// It uses much less space than an iterable mapping but performs worse when the set is sufficiently large
contract ProviderIdSet is Ownable {
    constructor() Ownable(msg.sender) {}

    // compressed arrayset: 8 providerIds per item
    uint256[] private list;

    error ProviderIdTooLarge(uint256 providerId);
    error ProviderIdNotFound(uint256 providerId);

    function getProviderIds() public view returns (uint256[] memory) {
        uint256[] memory providers = new uint256[](list.length * 8);

        uint256 size = 0;
        for (uint256 i = 0; i < list.length; i++) {
            uint256 iteration = list[i];
            while (iteration > 0) {
                providers[size++] = iteration & 0xffffffff;
                iteration >>= 32;
            }
        }

        // truncate length
        assembly ("memory-safe") {
            mstore(providers, size)
        }

        return providers;
    }

    /**
     * No-op if providerId is 0 or if providerId is already in the set
     */
    function addProviderId(uint256 providerId) external onlyOwner {
        require(providerId < 0x100000000, ProviderIdTooLarge(providerId));
        for (uint256 i = 0; i < list.length; i++) {
            uint256 read = list[i];
            uint256 iteration = read;
            for (uint256 j = 0; j < 8; j++) {
                uint256 curr = iteration & 0xffffffff;
                if (curr == 0) {
                    // insert
                    list[i] = read | providerId << j * 32;
                    return;
                }
                if (curr == providerId) {
                    // found
                    return;
                }
                iteration >>= 32;
            }
        }
        // insert
        list.push(providerId);
    }

    function removeProviderId(uint256 providerId) external onlyOwner {
        for (uint256 i = 0; i < list.length; i++) {
            uint256 read = list[i];
            uint256 iteration = read;
            for (uint256 j = 0; j < 8; j++) {
                uint256 curr = iteration & 0xffffffff;
                require(curr != 0, ProviderIdNotFound(providerId));
                if (curr != providerId) {
                    iteration >>= 32;
                    continue;
                }
                // found at i,j

                unchecked {
                    uint256 lastFew;
                    if (i == list.length - 1) {
                        // can skip sload
                        lastFew = read;
                    } else {
                        lastFew = list[list.length - 1];
                    }
                    if (lastFew < 0x100000000) {
                        // special case: lastFew contains one item
                        read ^= (lastFew ^ providerId) << j * 32;
                        list[i] = read;
                        list.pop();
                        return;
                    }

                    // find the last item
                    // NOTE: can binary search instead
                    for (uint256 k = 224; k != 0; k -= 32) {
                        uint256 last = lastFew >> k;
                        if (last == 0) {
                            continue;
                        }
                        // move last to i,j
                        read ^= (last ^ providerId) << j * 32;
                        if (i == list.length - 1) {
                            read &= (1 << k) - 1;
                        } else {
                            // pop last
                            lastFew &= (1 << k) - 1;
                            list[list.length - 1] = lastFew;
                        }
                        list[i] = read;
                        return;
                    }
                }
            }
        }
        require(false, ProviderIdNotFound(providerId));
    }
}
