// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.21;

// Reference authorizer for the optional per-data-set write ACL (PR #536). One clone (or standalone
// deploy) per client: the payer attaches the same address to each of their data sets and scopes
// credentials by dataSetId (WILDCARD_DATASET = all of them). Built with the repo's deterministic
// profile (solc 0.8.30, via_ir, optimizer_runs=200, bytecode_hash="none") so it has a stable code
// identity for SP allowlisting. See MultiMethodAuthorizer.md for the wire-format spec.

import {IDataSetAuthorizer} from "../interfaces/IDataSetAuthorizer.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title MultiMethodAuthorizer
/// @notice One authorizer that recognises TWO legitimate delegation paths for the SAME P256
///         primitive (both verified via the 0x100 secp256r1 precompile), and dispatches on the
///         method tag carried in `signature`:
///
///           method 0  MachineP256  — a raw key signs the operation digest directly.
///                                     Delegation to a machine agent / session key ("something it has").
///           method 1  Passkey      — a WebAuthn assertion (Touch ID / secure enclave) whose CHALLENGE
///                                     is the operation digest; requires the user-verified (biometric)
///                                     flag. Delegation to a human on a device ("you are + you have").
///
///         The owner keeps a registry of credentials. Each credential declares its method, its P256
///         public key, the data set it applies to (`WILDCARD_DATASET` = every data set this
///         authorizer is attached to), and exactly which operations it may authorize — so e.g. a
///         machine agent can AddPieces on one data set while only your passkey may Terminate, or a
///         single P256 key can act across all data sets like the session-key registry. The
///         `signature` blob is:
///
///           abi.encode(uint8 method, bytes payload)
///             machine payload = abi.encode(uint256 x, uint256 y, bytes32 r, bytes32 s)
///             passkey payload = abi.encode(uint256 x, uint256 y, bytes32 r, bytes32 s,
///                                          bytes authenticatorData, string clientDataJSON)
///           Both payloads lead with the same P256 fields (x, y, r, s); the passkey adds the WebAuthn
///           envelope after them, so isAuthorized decodes (x, y, r, s) once for either method.
///
/// Replay is handled by FWSS itself (the digest is operation-unique and FWSS enforces its own
/// nonces / termination state), so this authorizer stays a pure authenticate-and-authorize gate.
contract MultiMethodAuthorizer is Initializable, OwnableUpgradeable, IDataSetAuthorizer {
    enum Method {
        MachineP256,
        Passkey
    }

    struct Credential {
        Method method;
        uint256 pubKeyX;
        uint256 pubKeyY;
        uint256 dataSetId; // specific data set, or WILDCARD_DATASET for every attached data set
        bytes32 rpIdHash; // Passkey only: expected RP-ID hash (0 = accept any origin)
        uint64 expiry; // 0 = no expiry
        bool enabled;
        bytes32[] ops; // live grant list; addCredential replaces it, removeCredential wipes it
    }

    /// Sentinel dataSetId: credential applies to every data set this authorizer is attached to.
    /// Chosen as type(uint256).max so it cannot collide with a real FWSS data set id.
    uint256 public constant WILDCARD_DATASET = type(uint256).max;

    /// The on-chain secp256r1 verifier, hardwired to the 0x100 precompile. Kept a `constant` (not a
    /// constructor immutable) so every deployment has identical runtime bytecode — a stable code
    /// identity for SP allowlisting — and the verifier can never be pointed at an attacker-controlled
    /// contract. A precompile-less-chain fallback would be a separate, separately-audited contract,
    /// not a per-deployer knob.
    address public constant P256_VERIFIER = address(0x100);

    /// secp256r1 (P256) curve order n. High-S signatures (s > n/2) are malleable, and the 0x100
    /// precompile does NOT reject them — so this authorizer enforces low-S itself (see _verifyP256).
    uint256 internal constant _P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    mapping(bytes32 credId => Credential) public credentials;
    mapping(bytes32 credId => mapping(bytes32 operation => bool)) public allowedOp;

    // OwnershipTransferred is inherited from OwnableUpgradeable.
    event CredentialSet(bytes32 indexed credId, Method method, uint256 pubKeyX, uint256 pubKeyY, uint256 dataSetId);
    event CredentialEnabled(bytes32 indexed credId, bool enabled);
    event OperationAllowed(bytes32 indexed credId, bytes32 indexed operation, bool allowed);
    event Authorized(bytes32 indexed credId, bytes32 indexed operation, Method method);
    event CredentialRemoved(bytes32 indexed credId);

    error UnknownMethod(uint8 method);
    error UnknownCredential(bytes32 credId);
    error RenounceDisabled();

    // Ownership (owner(), onlyOwner, transferOwnership, OwnableUnauthorizedAccount/OwnableInvalidOwner)
    // comes from OwnableUpgradeable; the initializer machinery (one-shot guard, InvalidInitialization)
    // from Initializable. Both are pure runtime/logic dependencies — no immutables — so the runtime
    // bytecode / code identity used for SP allowlisting stays deployment-independent.

    /// Standalone deploys set the owner here: the constructor runs the `initializer` (during
    /// construction `code.length == 0`, the Initializable branch that permits this), so a standalone
    /// instance is born initialized to its deployer and cannot be re-initialized. Constructor logic
    /// lives in creation code, not runtime code, so it does not affect the code identity.
    constructor() initializer {
        __Ownable_init(msg.sender);
    }

    /// One-shot initializer for EIP-1167 minimal-proxy clones, which never run the constructor (so
    /// their storage starts zeroed and `_initialized == 0`). Intended model: one clone per client,
    /// initialized to that client's owner address; the client then attaches this same address as
    /// authorizer on each data set they want it to govern. Reverts once set (InvalidInitialization),
    /// so re-initialization is impossible. Deploy and initialize a clone atomically (factory/script)
    /// so a fresh clone can't be initialize-front-run. `__Ownable_init` rejects a zero owner.
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    /// Disabled: an ownerless authorizer could never manage credentials again, silently freezing
    /// every data set it gates. Transfer ownership to a new key instead of renouncing.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ───────────────────────── owner: registry management ─────────────────────────

    /// Register a credential and the operations it may authorize. Re-adding the same
    /// (method, key, dataSetId) **replaces** the previous grant set (old ops are cleared).
    /// After that, use `setOperationAllowed` to add or remove individual operations.
    /// `dataSetId` is a specific FWSS data set, or `WILDCARD_DATASET` to authorize on every data
    /// set this authorizer is attached to (session-key-registry equivalent for P256).
    function addCredential(
        Method method,
        uint256 pubKeyX,
        uint256 pubKeyY,
        uint256 dataSetId,
        bytes32 rpIdHash,
        uint64 expiry,
        bytes32[] calldata ops
    ) external onlyOwner returns (bytes32 credId) {
        credId = credentialId(method, pubKeyX, pubKeyY, dataSetId);
        _clearOps(credId);
        Credential storage c = credentials[credId];
        c.method = method;
        c.pubKeyX = pubKeyX;
        c.pubKeyY = pubKeyY;
        c.dataSetId = dataSetId;
        c.rpIdHash = rpIdHash;
        c.expiry = expiry;
        c.enabled = true;
        emit CredentialSet(credId, method, pubKeyX, pubKeyY, dataSetId);
        emit CredentialEnabled(credId, true);
        for (uint256 i = 0; i < ops.length; i++) {
            _grantOp(credId, ops[i]);
            emit OperationAllowed(credId, ops[i], true);
        }
    }

    /// Add or remove a single operation on an existing credential. The only incremental
    /// permission API — `addCredential` replaces the whole grant set, `removeCredential` wipes it.
    function setOperationAllowed(bytes32 credId, bytes32 operation, bool allowed) external onlyOwner {
        if (!_exists(credId)) revert UnknownCredential(credId);
        if (allowed) _grantOp(credId, operation);
        else _revokeOp(credId, operation);
        emit OperationAllowed(credId, operation, allowed);
    }

    function setCredentialEnabled(bytes32 credId, bool enabled) external onlyOwner {
        credentials[credId].enabled = enabled;
        emit CredentialEnabled(credId, enabled);
    }

    function setCredentialExpiry(bytes32 credId, uint64 expiry) external onlyOwner {
        credentials[credId].expiry = expiry;
    }

    /// Fully remove a credential and reclaim its storage, including every granted operation.
    /// Callers do not list ops — the live grant list on the credential is the source of truth.
    /// (Disabling via setCredentialEnabled(false) also stops it authorizing, but leaves the entry.)
    function removeCredential(bytes32 credId) external onlyOwner {
        _clearOps(credId);
        delete credentials[credId];
        emit CredentialRemoved(credId);
    }

    /// Current grant list for a credential (same set `removeCredential` will wipe).
    function credentialOps(bytes32 credId) external view returns (bytes32[] memory) {
        return credentials[credId].ops;
    }

    function credentialId(Method method, uint256 x, uint256 y, uint256 dataSetId) public pure returns (bytes32) {
        return keccak256(abi.encode(method, x, y, dataSetId));
    }

    /// Helper for clients: base64url(challenge) as it must appear in WebAuthn clientDataJSON.
    function encodeChallenge(bytes32 challenge) external pure returns (string memory) {
        return _b64url(abi.encodePacked(challenge));
    }

    // ───────────────────────────── authorization ─────────────────────────────

    /// @inheritdoc IDataSetAuthorizer
    function isAuthorized(
        uint256 dataSetId,
        address, /* payer */
        bytes32 operation,
        bytes32 digest,
        bytes calldata signature,
        bytes calldata /* operationData */
    ) external returns (bool) {
        (uint8 method, bytes memory payload) = abi.decode(signature, (uint8, bytes));
        // malformed / unrecognised method → revert (bubbles); in-scope authorization failures → false.
        if (method > uint8(Method.Passkey)) revert UnknownMethod(method);

        // Both payloads lead with the same P256 fields, so decode them once here; the passkey's
        // WebAuthn envelope trails and is decoded in _verifyPasskey.
        (uint256 x, uint256 y, bytes32 r, bytes32 s) = abi.decode(payload, (uint256, uint256, bytes32, bytes32));

        (bytes32 credId, bool allowed) = _lookupCred(Method(method), x, y, dataSetId, operation);
        if (!allowed) return false;

        if (method == uint8(Method.MachineP256)) {
            // machine key signs the FWSS digest directly.
            if (!_verifyP256(digest, x, y, r, s)) return false;
        } else {
            // WebAuthn passkey: presence + verification, challenge-binds to the digest, then
            // P256-verifies the WebAuthn message. rpIdHash is pinned per-credential.
            if (!_verifyPasskey(payload, digest, x, y, r, s, credentials[credId].rpIdHash)) return false;
        }

        emit Authorized(credId, operation, Method(method));
        return true;
    }

    /// Resolve a credential for this key on `dataSetId`, falling back to the wildcard credential.
    /// Returns the matching credId (specific preferred) and whether it currently authorizes `operation`.
    function _lookupCred(Method method, uint256 x, uint256 y, uint256 dataSetId, bytes32 operation)
        internal
        view
        returns (bytes32 credId, bool allowed)
    {
        credId = credentialId(method, x, y, dataSetId);
        if (_credentialAllows(credId, operation)) return (credId, true);
        if (dataSetId != WILDCARD_DATASET) {
            credId = credentialId(method, x, y, WILDCARD_DATASET);
            if (_credentialAllows(credId, operation)) return (credId, true);
        }
        return (credId, false);
    }

    /// WebAuthn passkey verification (method 1). Decodes the WebAuthn envelope trailing the shared
    /// (x, y, r, s) prefix, requires presence + verification, binds the assertion challenge to the
    /// FWSS digest, pins rpIdHash, then P256-verifies the WebAuthn signed message. Pure check (no
    /// state writes / events); the caller resolves the credential and emits.
    function _verifyPasskey(
        bytes memory payload,
        bytes32 digest,
        uint256 x,
        uint256 y,
        bytes32 r,
        bytes32 s,
        bytes32 rpIdHash
    ) internal view returns (bool) {
        (,,,, bytes memory authData, string memory clientDataJSON) =
            abi.decode(payload, (uint256, uint256, bytes32, bytes32, bytes, string));

        // authenticatorData: rpIdHash(32) | flags(1) | signCount(4) | ...
        if (authData.length < 37) return false;
        uint8 flags = uint8(authData[32]);
        if (flags & 0x01 == 0) return false; // UP: user present
        if (flags & 0x04 == 0) return false; // UV: user VERIFIED (biometric) — what makes this "a human"
        if (rpIdHash != bytes32(0)) {
            bytes32 rp;
            assembly {
                rp := mload(add(authData, 32))
            } // first 32 bytes of authData
            if (rp != rpIdHash) return false;
        }

        // challenge binding: clientDataJSON must be a webauthn.get whose challenge == base64url(digest)
        bytes memory cd = bytes(clientDataJSON);
        if (!_contains(cd, bytes('"type":"webauthn.get"'))) return false;
        if (!_contains(cd, abi.encodePacked('"challenge":"', _b64url(abi.encodePacked(digest)), '"'))) return false;

        // WebAuthn signed message = sha256(authenticatorData || sha256(clientDataJSON))
        bytes32 message = sha256(abi.encodePacked(authData, sha256(cd)));
        return _verifyP256(message, x, y, r, s);
    }

    function _exists(bytes32 credId) internal view returns (bool) {
        Credential storage c = credentials[credId];
        return c.enabled || c.expiry != 0 || c.pubKeyX != 0 || c.pubKeyY != 0 || c.ops.length != 0;
    }

    function _clearOps(bytes32 credId) internal {
        bytes32[] storage existing = credentials[credId].ops;
        for (uint256 i = 0; i < existing.length; i++) {
            delete allowedOp[credId][existing[i]];
        }
        delete credentials[credId].ops;
    }

    function _grantOp(bytes32 credId, bytes32 operation) internal {
        if (allowedOp[credId][operation]) return;
        credentials[credId].ops.push(operation);
        allowedOp[credId][operation] = true;
    }

    function _revokeOp(bytes32 credId, bytes32 operation) internal {
        if (!allowedOp[credId][operation]) return;
        delete allowedOp[credId][operation];
        bytes32[] storage existing = credentials[credId].ops;
        uint256 n = existing.length;
        for (uint256 i = 0; i < n; i++) {
            if (existing[i] == operation) {
                existing[i] = existing[n - 1];
                existing.pop();
                return;
            }
        }
    }

    function _credentialAllows(bytes32 credId, bytes32 operation) internal view returns (bool) {
        Credential storage c = credentials[credId];
        if (!c.enabled) return false;
        if (c.expiry != 0 && block.timestamp > c.expiry) return false;
        return allowedOp[credId][operation];
    }

    // Params are ordered (key x, y, then signature r, s) to match the payload decode and the rest of
    // this contract; the precompile's own input layout is hash‖r‖s‖x‖y (RIP-7212), applied below.
    function _verifyP256(bytes32 hash, uint256 x, uint256 y, bytes32 r, bytes32 s) internal view returns (bool) {
        // Reject high-S (malleable) signatures: the 0x100 precompile accepts them, so we enforce
        // low-S here to match the spec and prevent signature malleability.
        if (uint256(s) > _P256_N / 2) return false;
        bytes memory input = abi.encodePacked(hash, r, s, bytes32(x), bytes32(y));
        (bool ok, bytes memory out) = P256_VERIFIER.staticcall(input);
        return ok && out.length == 32 && bytes32(out) == bytes32(uint256(1));
    }

    // ───────────────────────────── small utils ─────────────────────────────

    /// base64url (RFC 4648 §5), no padding — WebAuthn challenge encoding.
    function _b64url(bytes memory data) internal pure returns (string memory) {
        bytes memory T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        uint256 len = data.length;
        if (len == 0) return "";
        bytes memory out = new bytes((len * 8 + 5) / 6);
        uint256 i;
        uint256 j;
        unchecked {
            while (i + 3 <= len) {
                uint256 n = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i + 1])) << 8) | uint8(data[i + 2]);
                out[j++] = T[(n >> 18) & 63];
                out[j++] = T[(n >> 12) & 63];
                out[j++] = T[(n >> 6) & 63];
                out[j++] = T[n & 63];
                i += 3;
            }
            uint256 rem = len - i;
            if (rem == 1) {
                uint256 n = uint256(uint8(data[i])) << 16;
                out[j++] = T[(n >> 18) & 63];
                out[j++] = T[(n >> 12) & 63];
            } else if (rem == 2) {
                uint256 n = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i + 1])) << 8);
                out[j++] = T[(n >> 18) & 63];
                out[j++] = T[(n >> 12) & 63];
                out[j++] = T[(n >> 6) & 63];
            }
        }
        return string(out);
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        uint256 n = needle.length;
        if (n == 0) return true;
        if (n > hay.length) return false;
        for (uint256 i = 0; i <= hay.length - n; i++) {
            bool m = true;
            for (uint256 k = 0; k < n; k++) {
                if (hay[i + k] != needle[k]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }
}
