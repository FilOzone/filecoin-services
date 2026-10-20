// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC8167} from "@erc8167/interfaces/IERC8167.sol";
import {AbiCheats} from "@erc8167/lib/AbiCheats.sol";
import {Constructor} from "@erc8167/lib/Constructor.sol";
import {SetDelegateOperation} from "@erc8167/lib/Migration.sol";

/// @dev Resolves a Josuke ledger's `facetSrc` from build artifacts, as `josuke deploy` does, without an RPC.
/// Supported patterns: `<dir>/*.sol`, `<path>:<Contract>` and `<path>.evm`. Deploys with CREATE from this contract, so
/// scripts broadcast the deployments and tests run them in place.
abstract contract JosukeFacetSet is CommonBase {
    string internal constant LEDGER = "josuke.json";
    uint256 MAINNET_INDEX = 0;
    uint256 CALIBNET_INDEX = 1;

    struct Facet {
        string sourceId;
        string artifact;
        bytes4[] selectors;
    }

    // Constructor arguments by parameter name, as Josuke records them per chain in `constructorArgs`.
    mapping(string name => address value) private constructorArgs;
    mapping(string name => bool) private constructorArgSet;

    error UnsupportedFacetSource(string pattern);
    error NoDeployableFacet(string pattern);
    error MissingConstructorArg(string sourceId, string name);
    error UnsupportedConstructorArg(string sourceId, string name, string abiType);

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

    /// @dev Sets the value for every facet constructor parameter with this name.
    function _setConstructorArg(string memory name, address value) internal {
        constructorArgs[name] = value;
        constructorArgSet[name] = true;
    }

    /// @dev ABI-encodes a facet's constructor arguments by parameter name, as Josuke does from `constructorArgs`.
    function _facetConstructorArgs(Facet memory facet) internal view returns (bytes memory args) {
        string memory json = vm.readFile(facet.artifact);
        for (uint256 i; vm.keyExistsJson(json, _abiEntry(i)); ++i) {
            if (
                keccak256(bytes(vm.parseJsonString(json, string.concat(_abiEntry(i), ".type"))))
                    != keccak256("constructor")
            ) {
                continue;
            }

            string memory inputs = string.concat(_abiEntry(i), ".inputs");
            for (uint256 j; vm.keyExistsJson(json, string.concat(inputs, "[", vm.toString(j), "]")); ++j) {
                string memory input = string.concat(inputs, "[", vm.toString(j), "]");
                string memory name = vm.parseJsonString(json, string.concat(input, ".name"));
                string memory abiType = vm.parseJsonString(json, string.concat(input, ".type"));
                require(
                    keccak256(bytes(abiType)) == keccak256("address"),
                    UnsupportedConstructorArg(facet.sourceId, name, abiType)
                );
                require(constructorArgSet[name], MissingConstructorArg(facet.sourceId, name));
                args = abi.encodePacked(args, abi.encode(constructorArgs[name]));
            }
        }
    }

    function _abiEntry(uint256 index) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(index), "]");
    }

    function _deployFacet(Facet memory facet) private returns (address) {
        return Constructor.create(abi.encodePacked(vm.getCode(facet.artifact), _facetConstructorArgs(facet)));
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

    /// @dev Deploys the `selectors()` delegate Josuke generates. Sorts `exported` in place.
    function _deploySelectors(bytes4[] memory exported) internal returns (address) {
        for (uint256 i = 1; i < exported.length; ++i) {
            bytes4 selector = exported[i];
            uint256 j = i;
            for (; j != 0 && exported[j - 1] > selector; --j) {
                exported[j] = exported[j - 1];
            }
            exported[j] = selector;
        }

        // PUSH1 20 PUSH1 24, then PUSH4 <selector> DUP2 MSTORE for each selector, joined by DUP2 ADD
        bytes memory runtime = hex"60206024";
        for (uint256 i; i < exported.length; ++i) {
            if (i != 0) {
                runtime = abi.encodePacked(runtime, hex"8101");
            }
            runtime = abi.encodePacked(runtime, hex"63", exported[i], hex"8152");
        }

        // PUSH <count> DUP3 MSTORE SWAP1 PUSH0 MSTORE MSIZE PUSH0 RETURN
        uint256 count = exported.length;
        require(count != 0 && count <= type(uint16).max);
        bytes memory pushCount = count <= type(uint8).max
            ? abi.encodePacked(hex"60", uint8(count))
            : abi.encodePacked(hex"61", uint16(count));
        return Constructor.deploy(abi.encodePacked(runtime, pushCount, hex"8252905f52595ff3"));
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
