// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {VmSafe} from "forge-std/Vm.sol";

/// @title DeploymentsJson
/// @notice Reads and writes deployments.json in the format of tools/deployments.sh
library DeploymentsJson {
    VmSafe private constant VM = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The file to use: DEPLOYMENTS_JSON_PATH, or deployments.json. An empty value counts as unset.
    /// @return The path of deployments.json
    function path() internal view returns (string memory) {
        string memory configured = VM.envOr("DEPLOYMENTS_JSON_PATH", string(""));
        return bytes(configured).length == 0 ? "deployments.json" : configured;
    }

    /// @notice Reads an address recorded for a chain
    /// @param chainId The chain
    /// @param key The address key, e.g. FWSS_PROXY_ADDRESS
    /// @return The recorded address, or zero when the chain or key is missing
    function getAddress(uint256 chainId, string memory key) internal view returns (address) {
        string memory json = VM.readFile(path());
        string memory jsonKey = _key(chainId, key);
        if (!VM.keyExistsJson(json, jsonKey)) return address(0);
        return VM.parseJsonAddress(json, jsonKey);
    }

    /// @notice Records an address for a chain in EIP-55 form
    /// @param chainId The chain
    /// @param key The address key, e.g. FWSS_DISPATCHER_ADDRESS
    /// @param value The address
    function setAddress(uint256 chainId, string memory key, address value) internal {
        _write(_quote(VM.toString(value)), _key(chainId, key));
    }

    /// @notice Records the build metadata of a deployed contract under `contracts.<contractKey>`, which the legacy
    /// tools compare to decide whether to redeploy. Linked libraries are not supported: `libraries` is always empty.
    /// @param chainId The chain
    /// @param contractKey The contract key, e.g. FWSS_DISPATCHER_TRANSITION
    /// @param artifactContract The artifact, e.g. src/Foo.sol:Foo
    /// @param constructorArgs The constructor arguments as recorded strings
    function recordContract(
        uint256 chainId,
        string memory contractKey,
        string memory artifactContract,
        string[] memory constructorArgs
    ) internal {
        // One write per field, in the legacy key order; vm.serializeJson would sort the keys.
        string memory entry = _key(chainId, string.concat("contracts.", contractKey));
        _write(_quote(VM.toString(initcodeHash(artifactContract))), string.concat(entry, ".initcode_hash"));
        _write(_quote(artifactContract), string.concat(entry, ".artifact_contract"));
        _write("{}", string.concat(entry, ".libraries"));
        _write(_stringArray(constructorArgs), string.concat(entry, ".constructor_args"));
    }

    /// @notice Whether the record of a contract matches the current artifact and the given constructor arguments
    /// @param chainId The chain
    /// @param contractKey The contract key, e.g. FWSS_DISPATCHER_TRANSITION
    /// @param artifactContract The artifact, e.g. src/Foo.sol:Foo
    /// @param constructorArgs The constructor arguments as recorded strings
    /// @return False when the record is missing or differs
    function matchesRecord(
        uint256 chainId,
        string memory contractKey,
        string memory artifactContract,
        string[] memory constructorArgs
    ) internal view returns (bool) {
        string memory json = VM.readFile(path());
        string memory entry = _key(chainId, string.concat("contracts.", contractKey));
        string memory hashKey = string.concat(entry, ".initcode_hash");
        string memory argsKey = string.concat(entry, ".constructor_args");
        if (!VM.keyExistsJson(json, hashKey) || !VM.keyExistsJson(json, argsKey)) return false;
        if (VM.parseJsonBytes32(json, hashKey) != initcodeHash(artifactContract)) return false;

        string[] memory recorded = VM.parseJsonStringArray(json, argsKey);
        if (recorded.length != constructorArgs.length) return false;
        for (uint256 i; i < recorded.length; ++i) {
            if (keccak256(bytes(recorded[i])) != keccak256(bytes(constructorArgs[i]))) return false;
        }
        return true;
    }

    /// @notice Whether the deployment policy pins a contract: never redeploy it, use the recorded address. Mirrors
    /// `deployment_is_pinned` in tools/deployments.sh, except that a non-boolean `pinned` reverts.
    /// @param chainId The chain
    /// @param contractKey The contract key, e.g. FWSS_DISPATCHER_TRANSITION
    /// @return False when `pinned` is absent
    function isPinned(uint256 chainId, string memory contractKey) internal view returns (bool) {
        string memory json = VM.readFile(path());
        string memory key = _key(chainId, string.concat("contracts.", contractKey, ".pinned"));
        return VM.keyExistsJson(json, key) && VM.parseJsonBool(json, key);
    }

    /// @notice Records the commit and time of a deployment, keeping the other metadata such as fwss_version
    /// @param chainId The chain
    /// @param commit The deployed git commit; not written when empty
    function setMetadata(uint256 chainId, string memory commit) internal {
        string memory metadata = _key(chainId, "metadata");
        if (bytes(commit).length != 0) _write(_quote(commit), string.concat(metadata, ".commit"));
        _write(_quote(isoTimestamp(VM.unixTime() / 1000)), string.concat(metadata, ".deployed_at"));
    }

    /// @notice The hash the legacy tools record as `initcode_hash`: the artifact initcode without constructor
    /// arguments, CBOR metadata stripped
    /// @param artifactContract The artifact, e.g. src/Foo.sol:Foo
    /// @return The initcode hash
    function initcodeHash(string memory artifactContract) internal view returns (bytes32) {
        return keccak256(stripCbor(VM.getCode(artifactContract)));
    }

    /// @notice Mirrors `_strip_cbor` in tools/deployments.sh, so records stay comparable with the legacy tools: the
    /// last two bytes are read as a big-endian trailer length `n`, and the last `n + 2` bytes are dropped when shorter
    /// than the code. The result can differ from the true code when the code has no trailer, as it does in the legacy.
    /// @param code The initcode
    /// @return The initcode without its CBOR trailer
    function stripCbor(bytes memory code) internal pure returns (bytes memory) {
        if (code.length < 2) return code;
        uint256 strip = (uint256(uint8(code[code.length - 2])) << 8 | uint8(code[code.length - 1])) + 2;
        if (strip >= code.length) return code;

        bytes memory stripped = new bytes(code.length - strip);
        for (uint256 i; i < stripped.length; ++i) {
            stripped[i] = code[i];
        }
        return stripped;
    }

    /// @notice Formats a Unix time as `date -u +%Y-%m-%dT%H:%M:%SZ` does
    /// @param unixSeconds Seconds since 1970-01-01T00:00:00Z
    /// @return The ISO-8601 UTC timestamp
    function isoTimestamp(uint256 unixSeconds) internal pure returns (string memory) {
        uint256 secondOfDay = unixSeconds % 86400;

        // civil_from_days from Howard Hinnant's date algorithms, for days since 1970-01-01.
        uint256 z = unixSeconds / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 day = doy - (153 * mp + 2) / 5 + 1;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        uint256 year = yoe + era * 400 + (month <= 2 ? 1 : 0);

        return string.concat(
            VM.toString(year),
            "-",
            _pad2(month),
            "-",
            _pad2(day),
            "T",
            _pad2(secondOfDay / 3600),
            ":",
            _pad2(secondOfDay % 3600 / 60),
            ":",
            _pad2(secondOfDay % 60),
            "Z"
        );
    }

    /// @notice Writes a JSON value and keeps the trailing newline the legacy jq output ends with
    function _write(string memory value, string memory key) private {
        string memory file = path();
        VM.writeJson(value, file, key);

        bytes memory written = bytes(VM.readFile(file));
        if (written.length == 0 || written[written.length - 1] != "\n") {
            VM.writeFile(file, string.concat(string(written), "\n"));
        }
    }

    function _key(uint256 chainId, string memory key) private pure returns (string memory) {
        return string.concat(".", VM.toString(chainId), ".", key);
    }

    /// @notice Encodes a JSON string; the values written here (addresses, hashes, paths) need no escaping
    function _quote(string memory value) private pure returns (string memory) {
        return string.concat("\"", value, "\"");
    }

    function _stringArray(string[] memory values) private pure returns (string memory json) {
        json = "[";
        for (uint256 i; i < values.length; ++i) {
            json = string.concat(json, i == 0 ? "" : ",", _quote(values[i]));
        }
        json = string.concat(json, "]");
    }

    function _pad2(uint256 value) private pure returns (string memory) {
        return value < 10 ? string.concat("0", VM.toString(value)) : VM.toString(value);
    }
}
