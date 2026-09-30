// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC8167} from "@erc8167/interfaces/IERC8167.sol";
import {Migrate} from "@erc8167/interfaces/Migrate.sol";
import {IMigrateModule} from "../src/interfaces/IMigrateModule.sol";
import {JosukeFacetSet} from "./helpers/JosukeFacetSet.sol";

/// @dev Offline checks that `josuke deploy` would otherwise report only against a live chain.
contract JosukeFacetsTest is JosukeFacetSet {
    function testLedgersShareFacetSources() public view {
        string[] memory mainnet = _facetSources(MAINNET_INDEX);
        string[] memory calibnet = _facetSources(CALIBNET_INDEX);

        assertEq(mainnet.length, calibnet.length);
        for (uint256 i; i < mainnet.length; ++i) {
            assertEq(mainnet[i], calibnet[i]);
        }
    }

    function testLedgerAddresses() public view {
        address mainnetAddress = _proxyAddress(MAINNET_INDEX);
        address calibnetAddress = _proxyAddress(CALIBNET_INDEX);
        // TODO: read these from deployments.json
        assertEq(mainnetAddress, 0x8408502033C418E1bbC97cE9ac48E5528F371A9f);
        assertEq(calibnetAddress, 0x02925630df557F957f70E112bA06e50965417CA0);
    }

    function testEachSelectorHasOneFacet() public view {
        Facet[] memory facets = _resolveFacets(MAINNET_INDEX);

        for (uint256 i; i < facets.length; ++i) {
            for (uint256 j; j < facets[i].selectors.length; ++j) {
                bytes4 selector = facets[i].selectors[j];
                assertEq(_owners(facets, selector), 1, string.concat(facets[i].sourceId, " shares a selector"));
            }
        }
    }

    function testFacetsProvideDispatcherTransitionRoutes() public view {
        Facet[] memory facets = _resolveFacets(MAINNET_INDEX);

        assertEq(_owners(facets, IERC8167.implementation.selector), 1);
        assertEq(_owners(facets, IMigrateModule.announceMigration.selector), 1);
        assertEq(_owners(facets, Migrate.migrate.selector), 1);
        // Josuke generates selectors() when no facet implements it.
        assertEq(_owners(facets, IERC8167.selectors.selector), 0);
    }

    function _owners(Facet[] memory facets, bytes4 selector) private pure returns (uint256 owners) {
        for (uint256 i; i < facets.length; ++i) {
            for (uint256 j; j < facets[i].selectors.length; ++j) {
                if (facets[i].selectors[j] == selector) ++owners;
            }
        }
    }
}
