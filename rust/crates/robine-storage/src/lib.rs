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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InventoryObject {
    pub blob_id: String,
    pub size: i64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BlobInventory {
    pub objects: Vec<InventoryObject>,
    pub unsafe_objects: u64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RetentionStage {
    pub artifacts_deleted: u64,
    pub caches_deleted: u64,
    pub logs_deleted: u64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RetentionResult {
    pub artifacts_deleted: u64,
    pub caches_deleted: u64,
    pub logs_deleted: u64,
    pub blobs_deleted: u64,
    pub logical_bytes: i64,
    pub physical_bytes: i64,
    pub orphan_objects: u64,
    pub missing_objects: u64,
    pub unsafe_objects: u64,
    pub temporary_deleted: u64,
    pub orphans_staged: u64,
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
    async fn get(&self, tenant_id: &str, object: &StoredObject) -> Result<Vec<u8>, StorageError>;
    async fn delete(&self, tenant_id: &str, blob_id: &str) -> Result<(), StorageError>;
    async fn inventory(&self, tenant_id: &str) -> Result<BlobInventory, StorageError>;
    async fn delete_temporary_before(
        &self,
        tenant_id: &str,
        cutoff: DateTime<Utc>,
    ) -> Result<u64, StorageError>;
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

#[async_trait]
pub trait RetentionRepository: Send + Sync {
    async fn stage_expired(
        &self,
        tenant_id: &str,
        now: DateTime<Utc>,
        log_cutoff: DateTime<Utc>,
        not_before: DateTime<Utc>,
        batch_size: i64,
    ) -> Result<RetentionStage, StorageError>;

    async fn eligible_gc(
        &self,
        tenant_id: &str,
        now: DateTime<Utc>,
        batch_size: i64,
    ) -> Result<Vec<String>, StorageError>;

    async fn blob_referenced(&self, tenant_id: &str, blob_id: &str) -> Result<bool, StorageError>;

    async fn acknowledge_gc(&self, tenant_id: &str, blob_id: &str) -> Result<(), StorageError>;

    async fn referenced_objects(
        &self,
        tenant_id: &str,
    ) -> Result<Vec<InventoryObject>, StorageError>;

    async fn stage_orphans(
        &self,
        tenant_id: &str,
        blob_ids: &[String],
        not_before: DateTime<Utc>,
        now: DateTime<Utc>,
    ) -> Result<u64, StorageError>;
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

    async fn get(&self, tenant_id: &str, object: &StoredObject) -> Result<Vec<u8>, StorageError> {
        let root = self.tenant_root(tenant_id)?;
        let object = object.clone();
        let maximum = self.max_object_bytes;
        tokio::task::spawn_blocking(move || get_local(&root, &object, maximum))
            .await
            .map_err(|_| StorageError::Unavailable)?
    }

    async fn delete(&self, tenant_id: &str, blob_id: &str) -> Result<(), StorageError> {
        let root = self.tenant_root(tenant_id)?;
        let blob_id = blob_id.to_owned();
        tokio::task::spawn_blocking(move || delete_local(&root, &blob_id))
            .await
            .map_err(|_| StorageError::Unavailable)?
    }

    async fn inventory(&self, tenant_id: &str) -> Result<BlobInventory, StorageError> {
        let root = self.tenant_root(tenant_id)?;
        tokio::task::spawn_blocking(move || inventory_local(&root))
            .await
            .map_err(|_| StorageError::Unavailable)?
    }

    async fn delete_temporary_before(
        &self,
        tenant_id: &str,
        cutoff: DateTime<Utc>,
    ) -> Result<u64, StorageError> {
        let root = self.tenant_root(tenant_id)?;
        tokio::task::spawn_blocking(move || delete_temporary_local(&root, cutoff))
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

fn delete_local(root: &Path, blob_id: &str) -> Result<(), StorageError> {
    let path = LocalBlobStore::object_path(root, blob_id)?;
    match std::fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.file_type().is_file() => {
            std::fs::remove_file(path).map_err(|_| StorageError::Unavailable)
        }
        Ok(_) => Err(StorageError::InvalidInput),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err(StorageError::Unavailable),
    }
}

fn inventory_local(root: &Path) -> Result<BlobInventory, StorageError> {
    let objects_root = root.join("objects");
    let shards = match std::fs::read_dir(&objects_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(BlobInventory::default());
        }
        Err(_) => return Err(StorageError::Unavailable),
    };
    let mut inventory = BlobInventory::default();
    for shard in shards {
        let shard = shard.map_err(|_| StorageError::Unavailable)?;
        let shard_name = shard.file_name();
        let shard_name = shard_name.to_str().unwrap_or_default();
        let shard_metadata =
            std::fs::symlink_metadata(shard.path()).map_err(|_| StorageError::Unavailable)?;
        if !shard_metadata.file_type().is_dir()
            || shard_name.len() != 2
            || !shard_name.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            inventory.unsafe_objects = inventory.unsafe_objects.saturating_add(1);
            continue;
        }
        for object in std::fs::read_dir(shard.path()).map_err(|_| StorageError::Unavailable)? {
            let object = object.map_err(|_| StorageError::Unavailable)?;
            let blob_id = object.file_name();
            let blob_id = blob_id.to_str().unwrap_or_default();
            let metadata =
                std::fs::symlink_metadata(object.path()).map_err(|_| StorageError::Unavailable)?;
            if metadata.file_type().is_file()
                && blob_id.starts_with(shard_name)
                && LocalBlobStore::object_path(root, blob_id).is_ok()
            {
                inventory.objects.push(InventoryObject {
                    blob_id: blob_id.to_owned(),
                    size: i64::try_from(metadata.len()).map_err(|_| StorageError::Unavailable)?,
                });
            } else {
                inventory.unsafe_objects = inventory.unsafe_objects.saturating_add(1);
            }
        }
    }
    inventory
        .objects
        .sort_by(|left, right| left.blob_id.cmp(&right.blob_id));
    Ok(inventory)
}

fn delete_temporary_local(root: &Path, cutoff: DateTime<Utc>) -> Result<u64, StorageError> {
    let temporary_root = root.join(".tmp");
    let entries = match std::fs::read_dir(temporary_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(_) => return Err(StorageError::Unavailable),
    };
    let cutoff = std::time::UNIX_EPOCH
        .checked_add(std::time::Duration::from_secs(
            u64::try_from(cutoff.timestamp()).map_err(|_| StorageError::InvalidInput)?,
        ))
        .ok_or(StorageError::InvalidInput)?;
    let mut deleted = 0_u64;
    for entry in entries {
        let entry = entry.map_err(|_| StorageError::Unavailable)?;
        let metadata =
            std::fs::symlink_metadata(entry.path()).map_err(|_| StorageError::Unavailable)?;
        if metadata.file_type().is_file()
            && metadata.modified().map_err(|_| StorageError::Unavailable)? <= cutoff
        {
            std::fs::remove_file(entry.path()).map_err(|_| StorageError::Unavailable)?;
            deleted = deleted.saturating_add(1);
        }
    }
    Ok(deleted)
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
        let inventory = store.inventory("standalone").await.unwrap();
        assert_eq!(inventory.objects.len(), 1);
        assert_eq!(inventory.objects[0].blob_id, object.blob_id);
        std::fs::write(root.join(".tmp").join("abandoned"), b"partial").unwrap();
        assert_eq!(
            store
                .delete_temporary_before("standalone", Utc::now() + chrono::Duration::seconds(1))
                .await
                .unwrap(),
            1
        );
        std::fs::write(
            LocalBlobStore::object_path(&root, &object.blob_id).unwrap(),
            b"tampered",
        )
        .unwrap();
        assert_eq!(
            store.get("standalone", &object).await,
            Err(StorageError::DigestMismatch)
        );
        store.delete("standalone", &object.blob_id).await.unwrap();
        assert!(
            store
                .inventory("standalone")
                .await
                .unwrap()
                .objects
                .is_empty()
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
