# MultiMethodAuthorizer — authorization envelope & credential registry (formal spec)

Formal description of the wire format ("UCAN"-style delegation envelope) and the on-chain
registry entries consumed by `MultiMethodAuthorizer`, an `IDataSetAuthorizer` for
filecoin-services PR #536. This document is normative for anyone building a client that signs
for this authorizer or a contract that interoperates with it. Source of truth:
[`MultiMethodAuthorizer.sol`](MultiMethodAuthorizer.sol).

---

## 1. Model

The authorizer splits a delegated authorization into two halves:

- **Authentication** travels in the *signature envelope* that FWSS forwards to `isAuthorized`
  (Sections 4–5). It proves possession of a P256 key — and, for the passkey method, proves a
  human was *present and verified* (biometric) at signing time. It carries **no policy**.
- **Authorization** ("what may this key do, on which data set") lives in the **on-chain
  credential registry** (Section 3), managed by the authorizer's owner. Each credential names
  a data set (`WILDCARD_DATASET` = every data set this authorizer is attached to) and
  enumerates exactly which operations it may authorize, plus an optional expiry and an
  enable/disable switch.

**Deployment model:** one clone (or standalone deploy) **per client**, not per data set. The
client attaches that same address as authorizer on each FWSS data set they want it to govern,
then scopes grants in the registry. Wildcard credentials do **not** auto-attach the authorizer
to data sets — FWSS attachment is still per data set; wildcard only means "once attached, this
key may act." This is the cheap on-chain analogue of the session-key registry (one P256 grant
across all the client's data sets) while still allowing per-data-set grants on the same clone.

### 1.1 Relationship to UCAN

This is a UCAN-style *delegation* — a key other than the payer is authorized to act — but the
capability and caveats are held **on-chain**, not inside a signed token. Mapping to UCAN terms:

| UCAN concept | Here |
|---|---|
| Issuer (`iss`) | The authorizer **owner** (the client) who calls `addCredential` |
| Audience (`aud`) | The registered **credential** (a P256 public key `(x, y)` scoped to a `dataSetId`) |
| Capability (`can` / resource) | An `(operation, dataSetId)` pair — `allowedOp[credId][operation]` plus the credential's `dataSetId` (or `WILDCARD_DATASET`) |
| Caveats | `expiry`, `enabled`, and (passkey) `rpIdHash` + user-verification requirement |
| Proof / invocation signature | The P256 signature over the FWSS operation `digest` (Section 6) |

Consequence: unlike a token-carried UCAN, **there is no off-chain capability object to parse or
revoke** — delegation is granted and revoked by owner transactions (`addCredential` /
`removeCredential` / `setCredentialEnabled`), and the "challenge" being signed is the FWSS
operation digest itself. Replay/ordering is **not** in this envelope; it is FWSS's responsibility
(see [PLAYBOOK reviewer note](../../repos/filecoin_stuff/synapse-sdk/examples/authz/PLAYBOOK.md)).

---

## 2. Primitives & notation

- `‖` — byte concatenation. `H(x)` — SHA-256. `keccak(x)` — Keccak-256.
- **P256** — ECDSA over NIST P-256 (secp256r1). Signatures are `(r, s)` with **low-`s`**
  normalization required (`s ≤ n/2`, `n` the curve order); high-`s` signatures are rejected by
  the precompile and MUST NOT be sent.
- **Verification** is delegated to the FEVM **secp256r1 precompile at `0x100`** (EIP-7951 /
  RIP-7212, nv28 / actors v18). Input (160 bytes, big-endian 32-byte words):

  ```
  input = digest‖r‖s‖x‖y          # message hash, sig, pubkey
  ```
  Output is 32 bytes equal to `uint256(1)` on success, empty/`0` otherwise.
- **base64url** — RFC 4648 §5, **no padding** (the WebAuthn challenge encoding).
- All integers are big-endian. `bytes32(x)` is the 32-byte big-endian encoding of `uint256 x`.

---

## 3. Credential registry (on-chain entries)

```solidity
enum Method { MachineP256 /*0*/, Passkey /*1*/ }

uint256 constant WILDCARD_DATASET = type(uint256).max; // all attached data sets

struct Credential {
    Method  method;     // 0 = machine key, 1 = WebAuthn passkey
    uint256 pubKeyX;    // P256 public key X
    uint256 pubKeyY;    // P256 public key Y
    uint256 dataSetId;  // specific FWSS data set, or WILDCARD_DATASET
    bytes32 rpIdHash;   // Passkey only: expected SHA-256(rpId); 0 = accept any origin
    uint64  expiry;     // unix seconds; 0 = no expiry
    bool    enabled;    // owner kill-switch
}

mapping(bytes32 credId => Credential) credentials;
mapping(bytes32 credId => mapping(bytes32 operation => bool)) allowedOp;
```

**Credential identifier** (deterministic, collision-resistant per method+key+data set):

```
credId = keccak(abi.encode(Method method, uint256 x, uint256 y, uint256 dataSetId))
```

The same P256 key may therefore be registered more than once — e.g. AddPieces-only on data set
7, and a separate wildcard credential for Terminate on every attached data set. Those are two
`credId`s.

**Operation identifiers** — the FWSS EIP-712 struct type-hashes (the `operation` argument of
`isAuthorized` and the key of `allowedOp`):

| Operation | `operation` typehash |
|---|---|
| AddPieces | `0x954bdc254591a7eab1b73f03842464d9283a08352772737094d710a4428fd183` |
| SchedulePieceRemovals | `0x5415701e313bb627e755b16924727217bb356574fe20e7061442c200b0822b22` |
| TerminateService | `0x522bd88a11de1cdc6574394dde7a21ae488ff13e16e7408d0ea721dd8479dffc` |

**Owner API** (only the authorizer's `owner`; see PLAYBOOK for cast invocations):
`addCredential(method, x, y, dataSetId, rpIdHash, expiry, ops[])`, `setOperationAllowed`,
`setCredentialEnabled`, `setCredentialExpiry`, `removeCredential(credId, ops[])`,
`transferOwnership`.

A credential **authorizes** `(operation, dataSetId)` iff:
`enabled ∧ (expiry == 0 ∨ block.timestamp ≤ expiry) ∧ allowedOp[credId][operation]`
**and** the credential's `dataSetId` is either the requested data set or `WILDCARD_DATASET`.

Lookup in `isAuthorized` prefers the **specific** credential `(method, x, y, dataSetId)` and, if
that does not currently authorize the operation, falls back to the **wildcard** credential
`(method, x, y, WILDCARD_DATASET)`. The two grants are a union: a wildcard AddPieces still
authorizes AddPieces on data set 7 even if a specific credential for data set 7 exists but
does not list AddPieces. To deny a key on one data set while keeping a wildcard, remove the
wildcard and register per-data-set credentials instead.

### 3.1 `expiry` and time on FEVM

`expiry` is compared against `block.timestamp`. The FEVM does **not** read wall-clock time — it
synthesizes `block.timestamp` deterministically from the tipset height:

```
block.timestamp = genesis_unix + epoch × blocktime      # blocktime = 30 s mainnet, 4 s on the FOC devnet
```

Consequences an implementer must respect:

- **Unit is Unix seconds; resolution is one epoch.** `block.timestamp` advances only once per epoch
  (30 s mainnet / 4 s devnet) and is constant across a tipset — sub-epoch precision is meaningless.
- **It is consensus-deterministic and not proposer-manipulable** (a pure function of height), so it
  is safe to gate on — a stronger guarantee than Ethereum's proposer-influenced timestamp.
- **Anchor `expiry` to chain time, not the local clock.** Chain time only advances when blocks are
  produced, so on a devnet (or any idle chain) it can diverge from real wall-clock by hours. Clients
  MUST set `expiry = <latest block.timestamp> + duration_seconds`, never `Date.now()/1000 + duration`.
- Epoch-native alternative: a variant could gate on `block.number` (which on FEVM is the Filecoin
  epoch) and express `expiry` in epochs, removing the genesis/blocktime conversion. This contract
  uses `block.timestamp` for EVM-tooling legibility; the semantics above are identical either way.

---

## 4. Signature envelope (outer format)

The blob FWSS forwards as the `signature` argument of `isAuthorized` is a **method-tagged
envelope**:

```
signature = abi.encode(uint8 method, bytes payload)
```

| Field | Type | Meaning |
|---|---|---|
| `method` | `uint8` | `0` MachineP256, `1` Passkey. Any other value → **revert** `UnknownMethod` |
| `payload` | `bytes` | Method-specific, decoded per Section 5 |

Malformed envelopes (undecodable, unknown method) **revert** and bubble; in-scope-but-invalid
authorizations return **`false`** (FWSS maps that to `Unauthorized`).

---

## 5. Method payloads (inner format)

### 5.1 Method 0 — MachineP256 (a stored key signs the digest directly)

```
payload = abi.encode(uint256 x, uint256 y, bytes32 r, bytes32 s)
```

| Field | Type | Meaning |
|---|---|---|
| `x`, `y` | `uint256` | P256 public key; selects `credId = keccak(abi.encode(0, x, y, dataSetId))` (then wildcard fallback) |
| `r`, `s` | `bytes32` | P256 signature over the FWSS `digest` (low-`s`) |

Signed message = the FWSS `digest` **verbatim**.

### 5.2 Method 1 — Passkey (WebAuthn assertion; proves human presence + verification)

```
payload = abi.encode(uint256 x, uint256 y, bytes authenticatorData, string clientDataJSON, bytes32 r, bytes32 s)
```

| Field | Type | Meaning |
|---|---|---|
| `x`, `y` | `uint256` | P256 public key; selects `credId = keccak(abi.encode(1, x, y, dataSetId))` (then wildcard fallback) |
| `authenticatorData` | `bytes` | WebAuthn authenticator data (≥ 37 bytes) |
| `clientDataJSON` | `string` | WebAuthn client data JSON |
| `r`, `s` | `bytes32` | P256 signature over the WebAuthn **message** (below), low-`s` |

**`authenticatorData` layout** (only the fixed prefix is inspected):

```
byte 0..31   rpIdHash   = SHA-256(rpId)
byte 32      flags      bit0 (0x01) UP user-present;  bit2 (0x04) UV user-verified
byte 33..36  signCount  uint32 big-endian
byte 37..    (optional attested-credential / extensions — ignored)
```

**`clientDataJSON`** MUST be a WebAuthn *get* assertion whose challenge is the FWSS digest. The
authorizer checks, by substring match, that it contains **both**:

```
"type":"webauthn.get"
"challenge":"<base64url(digest)>"          # no padding; digest is the 32-byte FWSS digest
```

(`origin` and other members are not constrained by the contract; `rpIdHash` binding is enforced
via `authenticatorData`, see Section 6.)

**WebAuthn signed message** (what `(r, s)` signs):

```
message = H( authenticatorData ‖ H(clientDataJSON) )
```

---

## 6. Verification algorithm (normative)

`isAuthorized(dataSetId, payer, operation, digest, signature, operationData)`:

1. Decode the envelope → `(method, payload)`. Unknown `method` ⇒ **revert**.
2. Resolve the credential: specific `credId = keccak(abi.encode(method, x, y, dataSetId))` if it
   currently authorizes `operation` (Section 3); otherwise the wildcard
   `credId = keccak(abi.encode(method, x, y, WILDCARD_DATASET))`. If neither authorizes ⇒ `false`.
   (`payer` is not consulted — FWSS attachment is what bound this authorizer to the data set.)
3. **Machine (0):** decode `(x, y, r, s)`.
   - If `P256Verify(digest, r, s, x, y) ≠ 1` ⇒ return `false`.
   - Else emit `Authorized(credId, operation, MachineP256)`; return `true`.
4. **Passkey (1):** decode `(x, y, authenticatorData, clientDataJSON, r, s)`.
   - If `authenticatorData.length < 37` ⇒ return `false`.
   - If `flags & 0x01 == 0` (no user-present) ⇒ return `false`.
   - If `flags & 0x04 == 0` (**no user-verified / biometric**) ⇒ return `false`.
   - If `credential.rpIdHash ≠ 0` and `authenticatorData[0..31] ≠ credential.rpIdHash` ⇒ `false`.
   - If `clientDataJSON` lacks `"type":"webauthn.get"` ⇒ return `false`.
   - If `clientDataJSON` lacks `"challenge":"base64url(digest)"` ⇒ return `false`.
   - Compute `message = H(authenticatorData ‖ H(clientDataJSON))`.
   - If `P256Verify(message, r, s, x, y) ≠ 1` ⇒ return `false`.
   - Else emit `Authorized(credId, operation, Passkey)`; return `true`.

`operationData` (the raw ABI-encoded operation payload FWSS also forwards) is **not** consulted by
this authorizer — authorization is by `operation` typehash + registry scope. It is available for
subclasses that want content-level ACLs (e.g. metadata/path gating).

### 6.1 What the digest binds (and what it doesn't)

The `digest` is FWSS's EIP-712 operation digest. It cryptographically binds the operation to its
parameters (for AddPieces: `clientDataSetId, nonce, pieceData[], metadata` — including a per-payer
nonce). The passkey path additionally binds `digest` into the WebAuthn challenge, so a passkey
assertion cannot be re-pointed at a different operation. This authorizer keeps **no nonce of its
own**; replay protection for each operation is FWSS's (AddPieces: client nonce; Terminate:
terminal-state guard; SchedulePieceRemovals: delegated upstream — flagged for reviewers).

---

## 7. Worked example — machine-key AddPieces envelope

```
x  = 0xef23…79f2         # P256 pubkey X
y  = 0xf1f3…089a         # P256 pubkey Y
digest = <FWSS AddPieces EIP-712 digest>
(r, s) = P256_sign(privkey, digest)          # low-s normalized

payload   = abi.encode(x, y, r, s)                    # 4 × 32 bytes
signature = abi.encode(uint8(0), payload)             # method 0 + payload
# FWSS calls: isAuthorized(dataSetId, payer,
#   operation = 0x954bdc…d183 (ADD_PIECES_TYPEHASH),
#   digest, signature, operationData)
```

Registration that makes it pass (owner tx):

```
addCredential(0 /*MachineP256*/, x, y, dataSetId, 0 /*rpIdHash n/a*/, 0 /*no expiry*/,
              [0x954bdc…d183]  /*AddPieces only*/)
# session-key equivalent — same key, every attached data set:
addCredential(0 /*MachineP256*/, x, y, type(uint256).max /*WILDCARD_DATASET*/, 0, 0,
              [0x954bdc…d183])
```

---

## 8. Security notes for implementers

- **Always low-`s` normalize** before sending; the precompile rejects high-`s`, which reads as an
  auth failure.
- **UV is load-bearing** for the passkey method: it is the on-chain evidence that a human verified
  (Touch ID / secure enclave). A client that requests a non-verifying assertion (`userVerification`
  ≠ `required`) will be rejected (`flags & 0x04 == 0`).
- **rpIdHash pinning:** set a non-zero `rpIdHash` on passkey credentials to bind them to a specific
  relying-party origin; `0` accepts any origin and should be used only for testing.
- **Revocation is on-chain and immediate:** `setCredentialEnabled(credId, false)` disables;
  `removeCredential(credId, ops[])` deletes the entry *and* its `allowedOp` slots (bounded storage).
- **Wildcard is a union, not a default-deny overlay.** A wildcard credential still authorizes on
  a data set that also has a more specific credential for the same key. There is no per-data-set
  exception list — restrict a key by dropping the wildcard and issuing specific grants.
- **Attachment is still per data set.** `WILDCARD_DATASET` does not make the authorizer apply to
  data sets the payer has not attached it to.
- The signature envelope proves authentication only — never treat a valid signature as
  authorization without the registry check.
