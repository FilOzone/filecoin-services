// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC8167} from "@erc8167/interfaces/IERC8167.sol";
import {Migrate} from "@erc8167/interfaces/Migrate.sol";
import {IMigrateModule} from "../src/interfaces/IMigrateModule.sol";
import {JosukeFacetSet} from "./helpers/JosukeFacetSet.sol";

/// @dev Offline checks that `josuke deploy` would otherwise report only against a live chain.
contract JosukeFacetsTest is JosukeFacetSet {
    function testLedgersShareFacetSources() public view {
        string[] memory mainnet = _facetSources(MAINNET_LEDGER);
        string[] memory calibnet = _facetSources(CALIBNET_LEDGER);

        assertEq(mainnet.length, calibnet.length);
        for (uint256 i; i < mainnet.length; ++i) {
            assertEq(mainnet[i], calibnet[i]);
        }
    }

    function testEachSelectorHasOneFacet() public view {
        Facet[] memory facets = _resolveFacets(MAINNET_LEDGER);

        for (uint256 i; i < facets.length; ++i) {
            for (uint256 j; j < facets[i].selectors.length; ++j) {
                bytes4 selector = facets[i].selectors[j];
                assertEq(_owners(facets, selector), 1, string.concat(facets[i].sourceId, " shares a selector"));
            }
        }
    }

    function testFacetsProvideDispatcherTransitionRoutes() public view {
        Facet[] memory facets = _resolveFacets(MAINNET_LEDGER);

        assertEq(_owners(facets, IERC8167.implementation.selector), 1);
        assertEq(_owners(facets, IMigrateModule.announceMigration.selector), 1);
        assertEq(_owners(facets, Migrate.migrate.selector), 1);
        // Josuke generates selectors() when no facet implements it.
        assertEq(_owners(facets, IERC8167.selectors.selector), 0);
    }

    function testOverlappingPatternsResolveEachFacetOnce() public view {
        string[] memory glob = new string[](1);
        glob[0] = "src/modules/*.sol";
        string[] memory overlapping = new string[](3);
        overlapping[0] = "src/modules/MigrateModule.sol:MigrateModule";
        overlapping[1] = "src/modules/*.sol";
        overlapping[2] = "src/modules/*.sol";

        Facet[] memory once = _resolvePatterns(glob);
        Facet[] memory deduplicated = _resolvePatterns(overlapping);
        assertEq(deduplicated.length, once.length);
        assertEq(deduplicated[0].sourceId, "src/modules/MigrateModule.sol:MigrateModule");
    }

    function _owners(Facet[] memory facets, bytes4 selector) private pure returns (uint256 owners) {
        for (uint256 i; i < facets.length; ++i) {
            for (uint256 j; j < facets[i].selectors.length; ++j) {
                if (facets[i].selectors[j] == selector) ++owners;
            }
        }
    }
}
