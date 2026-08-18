//! Compatibility cryptography for Robine's encrypted secret records.

use aes_gcm::{
    Aes256Gcm, KeyInit,
    aead::{Aead, AeadCore, AeadInPlace, OsRng, Payload},
};
use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use std::collections::BTreeMap;
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SecretScope {
    Repository,
    Instance,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EncryptedSecret {
    pub id: Uuid,
    pub name: String,
    pub scope: SecretScope,
    pub repository_id: Option<Uuid>,
    pub allowed_repository_ids: Vec<Uuid>,
    pub ciphertext: Vec<u8>,
    pub nonce: Vec<u8>,
    pub tag: Vec<u8>,
    pub key_version: i32,
}

#[derive(Clone)]
pub struct AesGcmKeyring {
    keys: BTreeMap<i32, [u8; 32]>,
}

#[derive(Debug, Error)]
pub enum SecretError {
    #[error("secret key configuration is invalid")]
    InvalidConfiguration,
    #[error("secret key version is unavailable")]
    KeyUnavailable,
    #[error("encrypted secret record is invalid")]
    InvalidCiphertext,
    #[error("secret authentication failed")]
    AuthenticationFailed,
    #[error("secret repository is unavailable")]
    Unavailable,
}

#[async_trait]
pub trait SecretRepository: Send + Sync {
    async fn find_instance(
        &self,
        _tenant_id: &str,
        _name: &str,
    ) -> Result<Option<EncryptedSecret>, SecretError> {
        Err(SecretError::Unavailable)
    }

    async fn upsert_instance(
        &self,
        _tenant_id: &str,
        _actor_id: Uuid,
        _secret: &EncryptedSecret,
    ) -> Result<(), SecretError> {
        Err(SecretError::Unavailable)
    }

    async fn find_authorized(
        &self,
        tenant_id: &str,
        repository_id: Uuid,
        names: &[String],
    ) -> Result<Vec<EncryptedSecret>, SecretError>;

    async fn list_repository(
        &self,
        tenant_id: &str,
        repository_id: Uuid,
    ) -> Result<Vec<EncryptedSecret>, SecretError>;

    async fn upsert_repository(
        &self,
        tenant_id: &str,
        actor_id: Uuid,
        secret: &EncryptedSecret,
    ) -> Result<(), SecretError>;

    async fn rotation_batch(
        &self,
        tenant_id: &str,
        after: Option<Uuid>,
        target_version: i32,
        limit: i64,
    ) -> Result<Vec<EncryptedSecret>, SecretError>;

    async fn rotate(
        &self,
        tenant_id: &str,
        actor_id: Uuid,
        expected_version: i32,
        secret: &EncryptedSecret,
    ) -> Result<bool, SecretError>;

    async fn rotation_pending(
        &self,
        tenant_id: &str,
        target_version: i32,
    ) -> Result<u64, SecretError>;
}

pub trait SecretDecryptor: Send + Sync {
    /// Decrypts one authenticated secret into a buffer that clears itself on drop.
    ///
    /// # Errors
    ///
    /// Rejects unavailable keys, malformed records, and authentication failures.
    fn decrypt(&self, secret: &EncryptedSecret) -> Result<Zeroizing<Vec<u8>>, SecretError>;
}

impl AesGcmKeyring {
    #[must_use]
    pub fn current_version(&self) -> Option<i32> {
        self.keys.last_key_value().map(|(version, _)| *version)
    }

    /// Parses the legacy single-key or versioned-key environment representation.
    ///
    /// # Errors
    ///
    /// Rejects malformed JSON, versions, base64, and keys other than 32 bytes.
    pub fn from_encoded(
        single_key: Option<&str>,
        encoded_keys: Option<&str>,
        default_version: i32,
    ) -> Result<Self, SecretError> {
        if default_version <= 0 {
            return Err(SecretError::InvalidConfiguration);
        }
        let encoded = if let Some(encoded_keys) = encoded_keys {
            serde_json::from_str::<BTreeMap<String, String>>(encoded_keys)
                .map_err(|_| SecretError::InvalidConfiguration)?
        } else if let Some(single_key) = single_key {
            BTreeMap::from([(default_version.to_string(), single_key.into())])
        } else {
            return Err(SecretError::InvalidConfiguration);
        };
        let mut keys = BTreeMap::new();
        for (version, value) in encoded {
            let version = version
                .parse::<i32>()
                .ok()
                .filter(|version| *version > 0)
                .ok_or(SecretError::InvalidConfiguration)?;
            let decoded = BASE64
                .decode(value)
                .map_err(|_| SecretError::InvalidConfiguration)?;
            let key: [u8; 32] = decoded
                .try_into()
                .map_err(|_| SecretError::InvalidConfiguration)?;
            keys.insert(version, key);
        }
        keys.contains_key(&default_version)
            .then_some(Self { keys })
            .ok_or(SecretError::InvalidConfiguration)
    }

    /// Decrypts one legacy AES-256-GCM record using exact Erlang external-term AAD.
    ///
    /// # Errors
    ///
    /// Rejects unavailable keys, malformed nonce/tag lengths, or authentication failure.
    pub fn decrypt(&self, secret: &EncryptedSecret) -> Result<Zeroizing<Vec<u8>>, SecretError> {
        let key = self
            .keys
            .get(&secret.key_version)
            .ok_or(SecretError::KeyUnavailable)?;
        if secret.nonce.len() != 12 || secret.tag.len() != 16 {
            return Err(SecretError::InvalidCiphertext);
        }
        let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| SecretError::InvalidCiphertext)?;
        let mut encrypted = Vec::with_capacity(secret.ciphertext.len() + secret.tag.len());
        encrypted.extend_from_slice(&secret.ciphertext);
        encrypted.extend_from_slice(&secret.tag);
        cipher
            .decrypt(
                aes_gcm::Nonce::from_slice(&secret.nonce),
                Payload {
                    msg: &encrypted,
                    aad: &erlang_aad(secret),
                },
            )
            .map(Zeroizing::new)
            .map_err(|_| SecretError::AuthenticationFailed)
    }

    /// Encrypts a write-only repository secret using the current (highest) key version.
    ///
    /// # Errors
    ///
    /// Returns an error when no encryption key is configured or encryption fails.
    pub fn encrypt_repository(
        &self,
        repository_id: Uuid,
        name: String,
        plaintext: &[u8],
    ) -> Result<EncryptedSecret, SecretError> {
        let (&key_version, key) = self
            .keys
            .last_key_value()
            .ok_or(SecretError::KeyUnavailable)?;
        let mut secret = EncryptedSecret {
            id: Uuid::new_v4(),
            name,
            scope: SecretScope::Repository,
            repository_id: Some(repository_id),
            allowed_repository_ids: Vec::new(),
            ciphertext: plaintext.to_vec(),
            nonce: Vec::new(),
            tag: Vec::new(),
            key_version,
        };
        let cipher =
            Aes256Gcm::new_from_slice(key).map_err(|_| SecretError::InvalidConfiguration)?;
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let tag = cipher
            .encrypt_in_place_detached(&nonce, &erlang_aad(&secret), &mut secret.ciphertext)
            .map_err(|_| SecretError::AuthenticationFailed)?;
        secret.nonce = nonce.to_vec();
        secret.tag = tag.to_vec();
        Ok(secret)
    }

    /// Encrypts a write-only instance credential using the current key version.
    ///
    /// # Errors
    ///
    /// Returns an error when no encryption key is configured or encryption fails.
    pub fn encrypt_instance(
        &self,
        name: String,
        plaintext: &[u8],
    ) -> Result<EncryptedSecret, SecretError> {
        let (&key_version, key) = self
            .keys
            .last_key_value()
            .ok_or(SecretError::KeyUnavailable)?;
        let mut secret = EncryptedSecret {
            id: Uuid::new_v4(),
            name,
            scope: SecretScope::Instance,
            repository_id: None,
            allowed_repository_ids: Vec::new(),
            ciphertext: plaintext.to_vec(),
            nonce: Vec::new(),
            tag: Vec::new(),
            key_version,
        };
        let cipher =
            Aes256Gcm::new_from_slice(key).map_err(|_| SecretError::InvalidConfiguration)?;
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let tag = cipher
            .encrypt_in_place_detached(&nonce, &erlang_aad(&secret), &mut secret.ciphertext)
            .map_err(|_| SecretError::AuthenticationFailed)?;
        secret.nonce = nonce.to_vec();
        secret.tag = tag.to_vec();
        Ok(secret)
    }

    /// Re-encrypts a record with the current key while preserving authenticated metadata.
    ///
    /// # Errors
    ///
    /// Rejects an unreadable source record or unavailable current key.
    pub fn reencrypt(&self, secret: &EncryptedSecret) -> Result<EncryptedSecret, SecretError> {
        let plaintext = self.decrypt(secret)?;
        let (&key_version, key) = self
            .keys
            .last_key_value()
            .ok_or(SecretError::KeyUnavailable)?;
        if secret.key_version == key_version {
            return Ok(secret.clone());
        }
        let mut rotated = secret.clone();
        rotated.key_version = key_version;
        rotated.ciphertext = plaintext.to_vec();
        let cipher =
            Aes256Gcm::new_from_slice(key).map_err(|_| SecretError::InvalidConfiguration)?;
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let tag = cipher
            .encrypt_in_place_detached(&nonce, &erlang_aad(&rotated), &mut rotated.ciphertext)
            .map_err(|_| SecretError::AuthenticationFailed)?;
        rotated.nonce = nonce.to_vec();
        rotated.tag = tag.to_vec();
        Ok(rotated)
    }
}

impl SecretDecryptor for AesGcmKeyring {
    fn decrypt(&self, secret: &EncryptedSecret) -> Result<Zeroizing<Vec<u8>>, SecretError> {
        Self::decrypt(self, secret)
    }
}

fn erlang_aad(secret: &EncryptedSecret) -> Vec<u8> {
    let mut output = vec![131, 104, 5];
    encode_binary(&mut output, secret.id.to_string().as_bytes());
    encode_binary(&mut output, secret.name.as_bytes());
    encode_small_atom(
        &mut output,
        match secret.scope {
            SecretScope::Repository => b"repository",
            SecretScope::Instance => b"instance",
        },
    );
    if let Some(repository_id) = secret.repository_id {
        encode_binary(&mut output, repository_id.to_string().as_bytes());
    } else {
        encode_small_atom(&mut output, b"nil");
    }
    let mut allowed = secret.allowed_repository_ids.clone();
    allowed.sort_unstable();
    if allowed.is_empty() {
        output.push(106);
    } else {
        output.push(108);
        output.extend_from_slice(
            &u32::try_from(allowed.len())
                .unwrap_or(u32::MAX)
                .to_be_bytes(),
        );
        for repository_id in allowed {
            encode_binary(&mut output, repository_id.to_string().as_bytes());
        }
        output.push(106);
    }
    output
}

fn encode_binary(output: &mut Vec<u8>, value: &[u8]) {
    output.push(109);
    output.extend_from_slice(&u32::try_from(value.len()).unwrap_or(u32::MAX).to_be_bytes());
    output.extend_from_slice(value);
}

fn encode_small_atom(output: &mut Vec<u8>, value: &[u8]) {
    output.push(119);
    output.push(u8::try_from(value.len()).unwrap_or(u8::MAX));
    output.extend_from_slice(value);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> EncryptedSecret {
        EncryptedSecret {
            id: Uuid::parse_str("00000000-0000-0000-0000-000000000001").expect("id"),
            name: "TOKEN".into(),
            scope: SecretScope::Repository,
            repository_id: Some(
                Uuid::parse_str("00000000-0000-0000-0000-000000000002").expect("repository"),
            ),
            allowed_repository_ids: Vec::new(),
            ciphertext: hex("abd452dfdb323cda1b8c1946"),
            nonce: vec![0; 12],
            tag: hex("1c7723dd992388998b29049e73862619"),
            key_version: 1,
        }
    }

    #[test]
    fn aad_matches_erlang_external_term_format() {
        assert_eq!(
            hex_string(&erlang_aad(&fixture())),
            "8368056d0000002430303030303030302d303030302d303030302d303030302d3030303030303030303030316d00000005544f4b454e770a7265706f7369746f72796d0000002430303030303030302d303030302d303030302d303030302d3030303030303030303030326a"
        );
    }

    #[test]
    fn decrypts_a_ciphertext_produced_by_erlang_crypto() {
        let encoded = BASE64.encode([42_u8; 32]);
        let keyring = AesGcmKeyring::from_encoded(Some(&encoded), None, 1).expect("keyring");
        assert_eq!(
            keyring.decrypt(&fixture()).expect("decrypt").as_slice(),
            b"super-secret"
        );
        let mut tampered = fixture();
        tampered.tag[0] ^= 1;
        assert!(matches!(
            keyring.decrypt(&tampered),
            Err(SecretError::AuthenticationFailed)
        ));
    }

    #[test]
    fn newly_encrypted_repository_secrets_round_trip_with_compatible_aad() {
        let encoded = BASE64.encode([42_u8; 32]);
        let keyring = AesGcmKeyring::from_encoded(Some(&encoded), None, 1).expect("keyring");
        let secret = keyring
            .encrypt_repository(Uuid::new_v4(), "REGISTRY_TOKEN".into(), b"super-secret")
            .expect("encrypt");
        assert_ne!(secret.ciphertext, b"super-secret");
        assert_eq!(secret.nonce.len(), 12);
        assert_eq!(secret.tag.len(), 16);
        assert_eq!(
            keyring.decrypt(&secret).expect("decrypt").as_slice(),
            b"super-secret"
        );
    }

    fn hex(value: &str) -> Vec<u8> {
        value
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                u8::from_str_radix(std::str::from_utf8(pair).expect("hex"), 16).expect("byte")
            })
            .collect()
    }

    fn hex_string(value: &[u8]) -> String {
        use std::fmt::Write;
        value.iter().fold(String::new(), |mut output, byte| {
            write!(output, "{byte:02x}").expect("write to string");
            output
        })
    }
}
