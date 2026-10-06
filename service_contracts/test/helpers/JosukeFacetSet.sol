// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC8167} from "@erc8167/interfaces/IERC8167.sol";
import {AbiCheats} from "@erc8167/lib/AbiCheats.sol";
import {Constructor} from "@erc8167/lib/Constructor.sol";
import {SetDelegateOperation} from "@erc8167/lib/Migration.sol";
import {FWSSFilBeamModule} from "../../src/modules/FWSSFilBeamModule.sol";

/// @dev Resolves a Josuke ledger's `facetSrc` from build artifacts, as `josuke deploy` does, without an RPC.
/// Supported patterns: `<dir>/*.sol`, `<path>:<Contract>` and `<path>.evm`.
abstract contract JosukeFacetSet is Test {
    string internal constant LEDGER = "josuke.json";
    uint256 MAINNET_INDEX = 0;
    uint256 CALIBNET_INDEX = 1;

    struct Facet {
        string sourceId;
        string artifact;
        bytes4[] selectors;
    }

    error UnsupportedFacetSource(string pattern);
    error NoDeployableFacet(string pattern);

    function _proxyAddress(uint256 index) internal view returns (address) {
        return
            vm.parseAddress(
                vm.parseJsonString(vm.readFile(LEDGER), string.concat(".[", vm.toString(index), "].address"))
            );
    }

    function _facetSources(uint256 index) internal view returns (string[] memory) {
        return vm.parseJsonStringArray(vm.readFile(LEDGER), string.concat(".[", vm.toString(index), "].facetSrc"));
    }

    function _resolveFacets(uint256 index) internal view returns (Facet[] memory) {
        return _resolvePatterns(_facetSources(index));
    }

    /// @dev Like Josuke, keeps the first facet for each source ID when patterns overlap.
    function _resolvePatterns(string[] memory patterns) internal view returns (Facet[] memory facets) {
        for (uint256 i; i < patterns.length; ++i) {
            Facet[] memory found = _resolve(patterns[i]);
            require(found.length != 0, NoDeployableFacet(patterns[i]));
            for (uint256 j; j < found.length; ++j) {
                if (!_contains(facets, found[j].sourceId)) facets = _append(facets, found[j]);
            }
        }
    }

    /// @dev ABI-encoded constructor arguments, which Josuke records per chain as `constructorArgs`.
    function _facetConstructorArgs(string memory sourceId) internal view virtual returns (bytes memory) {}

    /// @dev Solidity creation lets Forge link Rails for FilBeam; other facets use their artifacts.
    function _deployFacet(Facet memory facet) private returns (address) {
        bytes memory constructorArgs = _facetConstructorArgs(facet.sourceId);
        if (keccak256(bytes(facet.sourceId)) == keccak256(bytes("src/modules/FWSSFilBeamModule.sol:FWSSFilBeamModule")))
        {
            return address(new FWSSFilBeamModule());
        }

        return deployCode(facet.artifact, constructorArgs);
    }

    /// @dev Deploys every facet and returns one route per exported selector, plus the generated `selectors()`.
    function _deployFacetRoutes(Facet[] memory facets) internal returns (SetDelegateOperation[] memory routes) {
        uint256 count = 1;
        for (uint256 i; i < facets.length; ++i) {
            count += facets[i].selectors.length;
        }

        routes = new SetDelegateOperation[](count);
        bytes4[] memory exported = new bytes4[](count);
        uint256 next;
        for (uint256 i; i < facets.length; ++i) {
            address delegate = _deployFacet(facets[i]);
            for (uint256 j; j < facets[i].selectors.length; ++j) {
                routes[next] = SetDelegateOperation({selector: facets[i].selectors[j], delegate: delegate});
                exported[next++] = facets[i].selectors[j];
            }
        }
        exported[next] = IERC8167.selectors.selector;
        routes[next] =
            SetDelegateOperation({selector: IERC8167.selectors.selector, delegate: _deploySelectors(exported)});
    }

    /// @dev Stands in for the `selectors()` delegate Josuke generates when no facet implements it.
    function _deploySelectors(bytes4[] memory exported) internal returns (address) {
        bytes memory result = abi.encode(exported);
        require(result.length <= type(uint16).max);

        // PUSH2 len PUSH1 12 PUSH0 CODECOPY PUSH2 len PUSH0 RETURN, followed by the ABI-encoded result.
        bytes2 length = bytes2(uint16(result.length));
        return Constructor.deploy(abi.encodePacked(hex"61", length, hex"600c5f39", hex"61", length, hex"5ff3", result));
    }

    function _resolve(string memory pattern) private view returns (Facet[] memory) {
        if (_endsWith(pattern, ".evm")) {
            return _single(pattern, _evmArtifact(pattern));
        }

        string[] memory contractParts = vm.split(pattern, ":");
        if (contractParts.length == 2) {
            string memory file = _basename(contractParts[0]);
            return _single(pattern, string.concat("out/", file, "/", contractParts[1], ".json"));
        }

        string[] memory globParts = vm.split(pattern, "/*.sol");
        if (globParts.length == 2 && bytes(globParts[1]).length == 0) {
            return _resolveSolidityDirectory(globParts[0]);
        }

        revert UnsupportedFacetSource(pattern);
    }

    function _resolveSolidityDirectory(string memory dir) private view returns (Facet[] memory facets) {
        Vm.DirEntry[] memory sources = vm.readDir(dir);
        for (uint256 i; i < sources.length; ++i) {
            if (sources[i].isDir || !_endsWith(sources[i].path, ".sol")) continue;

            string memory file = _basename(sources[i].path);
            Vm.DirEntry[] memory artifacts = vm.readDir(string.concat("out/", file));
            for (uint256 j; j < artifacts.length; ++j) {
                string memory artifact = artifacts[j].path;
                // Interfaces and abstract contracts have no creation bytecode.
                if (bytes(vm.parseJsonString(vm.readFile(artifact), ".bytecode.object")).length <= 2) continue;

                string memory name = vm.replace(_basename(artifact), ".json", "");
                facets = _concat(facets, _single(string.concat(dir, "/", file, ":", name), artifact));
            }
        }
    }

    /// @dev Josuke builds `.evm` facets with the nearest Makefile above the source.
    function _evmArtifact(string memory source) private view returns (string memory) {
        string[] memory parts = vm.split(source, "/");
        string memory name = vm.replace(parts[parts.length - 1], ".evm", "");
        for (uint256 depth = parts.length - 1; depth != 0; --depth) {
            string memory dir = parts[0];
            for (uint256 i = 1; i < depth; ++i) {
                dir = string.concat(dir, "/", parts[i]);
            }
            if (vm.exists(string.concat(dir, "/Makefile"))) {
                return string.concat(dir, "/out/", name, ".evm/", name, ".json");
            }
        }
        revert UnsupportedFacetSource(source);
    }

    function _single(string memory sourceId, string memory artifact) private view returns (Facet[] memory facet) {
        facet = new Facet[](1);
        facet[0] = Facet({sourceId: sourceId, artifact: artifact, selectors: AbiCheats.getSelectors(vm, artifact)});
    }

    function _contains(Facet[] memory facets, string memory sourceId) private pure returns (bool) {
        for (uint256 i; i < facets.length; ++i) {
            if (keccak256(bytes(facets[i].sourceId)) == keccak256(bytes(sourceId))) return true;
        }
        return false;
    }

    function _append(Facet[] memory facets, Facet memory facet) private pure returns (Facet[] memory result) {
        result = new Facet[](facets.length + 1);
        for (uint256 i; i < facets.length; ++i) {
            result[i] = facets[i];
        }
        result[facets.length] = facet;
    }

    function _concat(Facet[] memory a, Facet[] memory b) private pure returns (Facet[] memory result) {
        result = new Facet[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            result[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            result[a.length + i] = b[i];
        }
    }

    function _basename(string memory path) private pure returns (string memory) {
        string[] memory parts = vm.split(path, "/");
        return parts[parts.length - 1];
    }

    function _endsWith(string memory value, string memory suffix) private pure returns (bool) {
        bytes memory v = bytes(value);
        bytes memory s = bytes(suffix);
        if (s.length > v.length) return false;
        for (uint256 i; i < s.length; ++i) {
            if (v[v.length - s.length + i] != s[i]) return false;
        }
        return true;
    }
}
