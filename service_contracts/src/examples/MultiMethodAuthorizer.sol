// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// Reference authorizer for the optional per-data-set write ACL (PR #536). Deployable standalone or
// as an EIP-1167 minimal-proxy clone; built here with the repo's deterministic profile
// (solc 0.8.30, via_ir, optimizer_runs=200, bytecode_hash="none") so it has a stable code identity
// for SP allowlisting. See MultiMethodAuthorizer.md for the wire-format spec.
//
// The IDataSetAuthorizer interface is inlined so this compiles before #536 merges. Once #536 lands,
// replace this inline copy with an import of the canonical `src/interfaces/IDataSetAuthorizer.sol`.

/// filecoin-services PR #536 IDataSetAuthorizer (state-mutating CALL).
interface IDataSetAuthorizer {
    function isAuthorized(
        uint256 dataSetId,
        address payer,
        bytes32 operation,
        bytes32 digest,
        bytes calldata signature,
        bytes calldata operationData
    ) external returns (bool authorized);
}

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
///         public key, and exactly which operations it may authorize — so e.g. a machine agent can
///         AddPieces while only your passkey may Terminate. The `signature` blob is:
///
///           abi.encode(uint8 method, bytes payload)
///             machine payload = abi.encode(uint256 x, uint256 y, bytes32 r, bytes32 s)
///             passkey payload = abi.encode(uint256 x, uint256 y, bytes authenticatorData,
///                                          string clientDataJSON, bytes32 r, bytes32 s)
///
/// Replay is handled by FWSS itself (the digest is operation-unique and FWSS enforces its own
/// nonces / termination state), so this authorizer stays a pure authenticate-and-authorize gate.
contract MultiMethodAuthorizer is IDataSetAuthorizer {
    enum Method { MachineP256, Passkey }

    struct Credential {
        Method method;
        uint256 pubKeyX;
        uint256 pubKeyY;
        bytes32 rpIdHash; // Passkey only: expected RP-ID hash (0 = accept any origin)
        uint64 expiry; // 0 = no expiry
        bool enabled;
    }

    /// The on-chain secp256r1 verifier, hardwired to the 0x100 precompile. Kept a `constant` (not a
    /// constructor immutable) so every deployment has identical runtime bytecode — a stable code
    /// identity for SP allowlisting — and the verifier can never be pointed at an attacker-controlled
    /// contract. A precompile-less-chain fallback would be a separate, separately-audited contract,
    /// not a per-deployer knob.
    address public constant P256_VERIFIER = address(0x100);
    address public owner;

    mapping(bytes32 credId => Credential) public credentials;
    mapping(bytes32 credId => mapping(bytes32 operation => bool)) public allowedOp;

    event OwnershipTransferred(address indexed from, address indexed to);
    event CredentialSet(bytes32 indexed credId, Method method, uint256 pubKeyX, uint256 pubKeyY);
    event CredentialEnabled(bytes32 indexed credId, bool enabled);
    event OperationAllowed(bytes32 indexed credId, bytes32 indexed operation, bool allowed);
    event Authorized(bytes32 indexed credId, bytes32 indexed operation, Method method);
    event CredentialRemoved(bytes32 indexed credId);

    error NotOwner();
    error UnknownMethod(uint8 method);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// Standalone deploys set the owner here. Constructor logic lives in creation code, not runtime
    /// code, so it does not affect the runtime bytecode / code identity used for SP allowlisting.
    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// One-shot initializer for EIP-1167 minimal-proxy clones, which never run the constructor (so
    /// their `owner` starts at zero). No-op / reverts once set, so a standalone deploy can't be
    /// re-initialized. Deploy and initialize a clone atomically (factory/script) so a fresh clone
    /// can't be initialize-front-run.
    function initialize(address initialOwner) external {
        require(owner == address(0), "already initialized");
        require(initialOwner != address(0), "zero owner");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    // ───────────────────────── owner: registry management ─────────────────────────

    /// Register (or overwrite) a credential and the operations it may authorize.
    function addCredential(
        Method method,
        uint256 pubKeyX,
        uint256 pubKeyY,
        bytes32 rpIdHash,
        uint64 expiry,
        bytes32[] calldata ops
    ) external onlyOwner returns (bytes32 credId) {
        credId = credentialId(method, pubKeyX, pubKeyY);
        credentials[credId] =
            Credential({method: method, pubKeyX: pubKeyX, pubKeyY: pubKeyY, rpIdHash: rpIdHash, expiry: expiry, enabled: true});
        emit CredentialSet(credId, method, pubKeyX, pubKeyY);
        emit CredentialEnabled(credId, true);
        for (uint256 i = 0; i < ops.length; i++) {
            allowedOp[credId][ops[i]] = true;
            emit OperationAllowed(credId, ops[i], true);
        }
    }

    function setOperationAllowed(bytes32 credId, bytes32 operation, bool allowed) external onlyOwner {
        allowedOp[credId][operation] = allowed;
        emit OperationAllowed(credId, operation, allowed);
    }

    function setCredentialEnabled(bytes32 credId, bool enabled) external onlyOwner {
        credentials[credId].enabled = enabled;
        emit CredentialEnabled(credId, enabled);
    }

    function setCredentialExpiry(bytes32 credId, uint64 expiry) external onlyOwner {
        credentials[credId].expiry = expiry;
    }

    /// Fully remove a credential and reclaim its storage (no unbounded growth). Pass the operations
    /// the credential was granted so their `allowedOp` slots are cleared too; unknown/extra ops are
    /// harmless no-ops. (Disabling via setCredentialEnabled(false) also stops it authorizing, but
    /// leaves the entry in storage — this deletes it.)
    function removeCredential(bytes32 credId, bytes32[] calldata ops) external onlyOwner {
        delete credentials[credId];
        for (uint256 i = 0; i < ops.length; i++) {
            delete allowedOp[credId][ops[i]];
        }
        emit CredentialRemoved(credId);
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    function credentialId(Method method, uint256 x, uint256 y) public pure returns (bytes32) {
        return keccak256(abi.encode(method, x, y));
    }

    /// Helper for clients: base64url(challenge) as it must appear in WebAuthn clientDataJSON.
    function encodeChallenge(bytes32 challenge) external pure returns (string memory) {
        return _b64url(abi.encodePacked(challenge));
    }

    // ───────────────────────────── authorization ─────────────────────────────

    /// @inheritdoc IDataSetAuthorizer
    function isAuthorized(uint256, address, bytes32 operation, bytes32 digest, bytes calldata signature, bytes calldata)
        external
        returns (bool)
    {
        (uint8 method, bytes memory payload) = abi.decode(signature, (uint8, bytes));
        if (method == uint8(Method.MachineP256)) return _machine(operation, digest, payload);
        if (method == uint8(Method.Passkey)) return _passkey(operation, digest, payload);
        revert UnknownMethod(method); // malformed → revert (bubbles); in-scope failures → false
    }

    /// method 0 — machine key signs the FWSS digest directly.
    function _machine(bytes32 operation, bytes32 digest, bytes memory payload) internal returns (bool) {
        (uint256 x, uint256 y, bytes32 r, bytes32 s) = abi.decode(payload, (uint256, uint256, bytes32, bytes32));
        bytes32 credId = credentialId(Method.MachineP256, x, y);
        if (!_credentialAllows(credId, operation)) return false;
        if (!_verifyP256(digest, r, s, x, y)) return false;
        emit Authorized(credId, operation, Method.MachineP256);
        return true;
    }

    /// method 1 — WebAuthn passkey: verify presence+verification and that the assertion's
    /// challenge is exactly the FWSS digest, then P256-verify the WebAuthn message.
    function _passkey(bytes32 operation, bytes32 digest, bytes memory payload) internal returns (bool) {
        (uint256 x, uint256 y, bytes memory authData, string memory clientDataJSON, bytes32 r, bytes32 s) =
            abi.decode(payload, (uint256, uint256, bytes, string, bytes32, bytes32));
        bytes32 credId = credentialId(Method.Passkey, x, y);
        Credential storage c = credentials[credId];
        if (!_credentialAllows(credId, operation)) return false;

        // authenticatorData: rpIdHash(32) | flags(1) | signCount(4) | ...
        if (authData.length < 37) return false;
        uint8 flags = uint8(authData[32]);
        if (flags & 0x01 == 0) return false; // UP: user present
        if (flags & 0x04 == 0) return false; // UV: user VERIFIED (biometric) — what makes this "a human"
        if (c.rpIdHash != bytes32(0)) {
            bytes32 rp;
            assembly {
                rp := mload(add(authData, 32))
            } // first 32 bytes of authData
            if (rp != c.rpIdHash) return false;
        }

        // challenge binding: clientDataJSON must be a webauthn.get whose challenge == base64url(digest)
        bytes memory cd = bytes(clientDataJSON);
        if (!_contains(cd, bytes('"type":"webauthn.get"'))) return false;
        if (!_contains(cd, abi.encodePacked('"challenge":"', _b64url(abi.encodePacked(digest)), '"'))) return false;

        // WebAuthn signed message = sha256(authenticatorData || sha256(clientDataJSON))
        bytes32 message = sha256(abi.encodePacked(authData, sha256(cd)));
        if (!_verifyP256(message, r, s, x, y)) return false;
        emit Authorized(credId, operation, Method.Passkey);
        return true;
    }

    function _credentialAllows(bytes32 credId, bytes32 operation) internal view returns (bool) {
        Credential storage c = credentials[credId];
        if (!c.enabled) return false;
        if (c.expiry != 0 && block.timestamp > c.expiry) return false;
        return allowedOp[credId][operation];
    }

    function _verifyP256(bytes32 hash, bytes32 r, bytes32 s, uint256 x, uint256 y) internal view returns (bool) {
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
