//! Storage contracts and a content-addressed local blob adapter.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use std::path::{Component, Path, PathBuf};
use thiserror::Error;
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredObject {
    pub blob_id: String,
    pub digest: String,
    pub size: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CacheEntry {
    pub id: Uuid,
    pub repository_id: Uuid,
    pub key: String,
    pub object: StoredObject,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Artifact {
    pub id: Uuid,
    pub repository_id: Uuid,
    pub attempt_id: Uuid,
    pub name: String,
    pub object: StoredObject,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StorageQuotas {
    pub instance_bytes: i64,
    pub repository_bytes: i64,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum StorageError {
    #[error("storage input is invalid")]
    InvalidInput,
    #[error("storage object was not found")]
    NotFound,
    #[error("storage object digest does not match")]
    DigestMismatch,
    #[error("storage object exceeds its size limit")]
    ObjectTooLarge,
    #[error("storage quota is exceeded")]
    QuotaExceeded,
    #[error("storage operation is unavailable")]
    Unavailable,
    #[error("artifact already exists")]
    ImmutableConflict,
}

#[async_trait]
pub trait BlobStore: Send + Sync {
    async fn put(&self, tenant_id: &str, content: Vec<u8>) -> Result<StoredObject, StorageError>;
    async fn get(
        &self,
        tenant_id: &str,
        object: &StoredObject,
    ) -> Result<Vec<u8>, StorageError>;
}

#[async_trait]
pub trait MetadataRepository: Send + Sync {
    async fn restore_cache(
        &self,
        tenant_id: &str,
        repository_id: Uuid,
        key: &str,
        now: DateTime<Utc>,
    ) -> Result<Option<CacheEntry>, StorageError>;

    async fn save_cache(
        &self,
        tenant_id: &str,
        cache: &CacheEntry,
        quotas: StorageQuotas,
    ) -> Result<(), StorageError>;

    async fn dependency_artifact(
        &self,
        tenant_id: &str,
        pipeline_id: Uuid,
        from_job: &str,
        name: &str,
        now: DateTime<Utc>,
    ) -> Result<Artifact, StorageError>;

    async fn upload_artifact(
        &self,
        tenant_id: &str,
        artifact: &Artifact,
        quotas: StorageQuotas,
    ) -> Result<(), StorageError>;

    async fn stage_blob_gc(
        &self,
        tenant_id: &str,
        blob_id: &str,
        not_before: DateTime<Utc>,
        now: DateTime<Utc>,
    ) -> Result<(), StorageError>;
}

#[derive(Clone, Debug)]
pub struct LocalBlobStore {
    root: PathBuf,
    max_object_bytes: usize,
}

impl LocalBlobStore {
    /// Creates a content-addressed local store below an explicit root.
    ///
    /// # Errors
    ///
    /// Rejects non-absolute roots and zero object limits.
    pub fn new(root: PathBuf, max_object_bytes: usize) -> Result<Self, StorageError> {
        if !root.is_absolute() || max_object_bytes == 0 {
            return Err(StorageError::InvalidInput);
        }
        Ok(Self {
            root,
            max_object_bytes,
        })
    }

    fn object_path(root: &Path, digest: &str) -> Result<PathBuf, StorageError> {
        if digest.len() != 64
            || !digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(StorageError::InvalidInput);
        }
        let path = root.join("objects").join(&digest[..2]).join(digest);
        if path
            .strip_prefix(root)
            .map_err(|_| StorageError::InvalidInput)?
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
        {
            return Err(StorageError::InvalidInput);
        }
        Ok(path)
    }

    fn tenant_root(&self, tenant_id: &str) -> Result<PathBuf, StorageError> {
        if tenant_id.is_empty() || tenant_id.contains('\0') {
            return Err(StorageError::InvalidInput);
        }
        if tenant_id == "standalone" {
            Ok(self.root.clone())
        } else {
            Ok(self
                .root
                .join("tenants")
                .join(format!("{:x}", Sha256::digest(tenant_id.as_bytes()))))
        }
    }
}

#[async_trait]
impl BlobStore for LocalBlobStore {
    async fn put(&self, tenant_id: &str, content: Vec<u8>) -> Result<StoredObject, StorageError> {
        if content.len() > self.max_object_bytes {
            return Err(StorageError::ObjectTooLarge);
        }
        let root = self.tenant_root(tenant_id)?;
        tokio::task::spawn_blocking(move || put_local(&root, &content))
            .await
            .map_err(|_| StorageError::Unavailable)?
    }

    async fn get(
        &self,
        tenant_id: &str,
        object: &StoredObject,
    ) -> Result<Vec<u8>, StorageError> {
        let root = self.tenant_root(tenant_id)?;
        let object = object.clone();
        let maximum = self.max_object_bytes;
        tokio::task::spawn_blocking(move || get_local(&root, &object, maximum))
            .await
            .map_err(|_| StorageError::Unavailable)?
    }
}

fn put_local(root: &Path, content: &[u8]) -> Result<StoredObject, StorageError> {
    let digest = format!("{:x}", Sha256::digest(content));
    let target = LocalBlobStore::object_path(root, &digest)?;
    let temporary_directory = root.join(".tmp");
    std::fs::create_dir_all(&temporary_directory).map_err(|_| StorageError::Unavailable)?;
    let temporary = temporary_directory.join(Uuid::new_v4().to_string());
    let result = (|| {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|_| StorageError::Unavailable)?;
        file.write_all(content)
            .map_err(|_| StorageError::Unavailable)?;
        file.sync_all().map_err(|_| StorageError::Unavailable)?;
        let parent = target.parent().ok_or(StorageError::InvalidInput)?;
        std::fs::create_dir_all(parent).map_err(|_| StorageError::Unavailable)?;
        match std::fs::rename(&temporary, &target) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                std::fs::remove_file(&temporary).map_err(|_| StorageError::Unavailable)?;
            }
            Err(_) => return Err(StorageError::Unavailable),
        }
        Ok(StoredObject {
            blob_id: digest.clone(),
            digest,
            size: i64::try_from(content.len()).map_err(|_| StorageError::ObjectTooLarge)?,
        })
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

fn get_local(root: &Path, object: &StoredObject, maximum: usize) -> Result<Vec<u8>, StorageError> {
    if object.blob_id != object.digest || object.size < 0 {
        return Err(StorageError::InvalidInput);
    }
    let path = LocalBlobStore::object_path(root, &object.blob_id)?;
    let metadata = std::fs::symlink_metadata(&path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            StorageError::NotFound
        } else {
            StorageError::Unavailable
        }
    })?;
    if !metadata.file_type().is_file()
        || usize::try_from(metadata.len()).map_or(true, |size| size > maximum)
    {
        return Err(StorageError::InvalidInput);
    }
    let content = std::fs::read(path).map_err(|_| StorageError::Unavailable)?;
    let digest = format!("{:x}", Sha256::digest(&content));
    if digest != object.digest || i64::try_from(content.len()).ok() != Some(object.size) {
        return Err(StorageError::DigestMismatch);
    }
    Ok(content)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn local_objects_are_atomic_content_addressed_and_verified() {
        let root = std::env::temp_dir().join(format!("robine-storage-test-{}", Uuid::new_v4()));
        let store = LocalBlobStore::new(root.clone(), 1_024).unwrap();
        let object = store.put("standalone", b"archive".to_vec()).await.unwrap();
        assert_eq!(store.get("standalone", &object).await.unwrap(), b"archive");
        std::fs::write(
            LocalBlobStore::object_path(&root, &object.blob_id).unwrap(),
            b"tampered",
        )
        .unwrap();
        assert_eq!(
            store.get("standalone", &object).await,
            Err(StorageError::DigestMismatch)
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
