# Secret encryption review

## Scope and decision

Robine's MVP stores secret values with versioned direct AES-256-GCM. This review covers `Robine.Adapters.Security.AesGcmCipher`, persistence boundaries, key loading, and rotation. It does not claim protection from a compromised application host or trusted workflow code that deliberately exfiltrates a supplied secret.

The construction is accepted for the self-hosted MVP. A KMS-backed envelope-encryption adapter remains future work.

## Construction

- Keys are exactly 256 bits and remain outside PostgreSQL.
- Every encryption generates a fresh cryptographically random 96-bit nonce.
- AES-GCM produces and verifies a 128-bit authentication tag.
- Authenticated additional data binds ciphertext to the immutable secret ID, name, scope, repository ownership, and sorted instance grants.
- Records carry a positive key version. Reads select that exact version and fail closed when it is unavailable.
- Ciphertext, nonce, and tag fields are redacted from Ecto inspection.
- Adapter boundaries validate key, nonce, tag, version, and binary types before entering the crypto NIF.

Random 96-bit nonce collision probability is negligible at the intended self-hosted scale. Operators should avoid cloning a keyring into unrelated high-volume instances.

## Rotation and recovery

Operators configure old and new versions together, select the new current version, restart, and run cursor-based batches. Each record is decrypted with its stored version and encrypted with the current version using a fresh nonce. The ciphertext update and `secret.key_rotated` audit event commit atomically under a row lock.

Interrupted batches leave a readable mixture of versions. The returned cursor resumes the ordered scan. Old keys remain configured until rotation reports completion, backups are verified, and no stored record references the old version.

## Residual risks

- BEAM binaries are immutable and cannot be reliably zeroized; plaintext lifetime is minimized but not cryptographically erased from process memory.
- Environment variables and deployment configuration remain operator-controlled sensitive surfaces.
- Database tampering can deny access, but authenticated encryption prevents modified ciphertext from being accepted as plaintext.
- Masking reduces accidental disclosure; it cannot stop trusted executed code from encoding or transmitting a secret deliberately.
- Losing an old key permanently loses records not yet rotated.

## Required operator controls

- Back up the keyring separately from PostgreSQL and test joint restoration.
- Restrict environment and configuration access to the Robine service account.
- Never remove an old version before rotation completion is verified.
- Rotate after suspected key exposure and review `secret.key_rotated` audit events.
