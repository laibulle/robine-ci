use crate::{
    BlobInventory, BlobStore, InventoryObject, StorageError, StoredObject, delete_temporary_local,
};
use async_trait::async_trait;
use aws_config::{BehaviorVersion, Region, timeout::TimeoutConfig};
use aws_sdk_s3::{
    Client,
    config::Builder as ClientConfig,
    primitives::ByteStream,
    types::{CompletedMultipartUpload, CompletedPart, ServerSideEncryption},
};
use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use std::{path::PathBuf, time::Duration};
use url::Url;

const MINIMUM_PART_SIZE: usize = 5 * 1_024 * 1_024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum S3Encryption {
    None,
    Aes256,
    Kms { key_id: String },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct S3Config {
    pub endpoint: String,
    pub region: String,
    pub bucket: String,
    pub prefix: String,
    pub path_style: bool,
    pub allow_http_loopback: bool,
    pub max_object_bytes: usize,
    pub part_size: usize,
    pub request_timeout: Duration,
    pub attempt_timeout: Duration,
    pub connect_timeout: Duration,
    pub spool_root: PathBuf,
    pub encryption: S3Encryption,
}

impl S3Config {
    fn validate(&self) -> Result<(), StorageError> {
        let endpoint = Url::parse(&self.endpoint).map_err(|_| StorageError::InvalidInput)?;
        let safe_transport = endpoint.scheme() == "https"
            || (endpoint.scheme() == "http"
                && self.allow_http_loopback
                && matches!(endpoint.host_str(), Some("localhost" | "127.0.0.1" | "::1")));
        if !safe_transport
            || endpoint.username() != ""
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
            || !matches!(endpoint.path(), "" | "/")
            || !valid_bucket(&self.bucket)
            || !valid_prefix(&self.prefix)
            || self.region.is_empty()
            || self.max_object_bytes == 0
            || self.part_size < MINIMUM_PART_SIZE
            || !self.spool_root.is_absolute()
            || self.request_timeout.is_zero()
            || self.attempt_timeout.is_zero()
            || self.connect_timeout.is_zero()
        {
            return Err(StorageError::InvalidInput);
        }
        if let S3Encryption::Kms { key_id } = &self.encryption
            && key_id.is_empty()
        {
            return Err(StorageError::InvalidInput);
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct S3BlobStore {
    client: Client,
    config: S3Config,
}

impl S3BlobStore {
    /// Builds an S3-compatible store using the standard AWS credential-provider chain.
    ///
    /// # Errors
    ///
    /// Rejects ambiguous or insecure endpoints, invalid bucket/prefix values, undersized
    /// multipart parts, missing limits, and a non-absolute spool directory.
    pub async fn new(config: S3Config) -> Result<Self, StorageError> {
        config.validate()?;
        let timeout = TimeoutConfig::builder()
            .connect_timeout(config.connect_timeout)
            .operation_attempt_timeout(config.attempt_timeout)
            .operation_timeout(config.request_timeout)
            .build();
        let shared = aws_config::defaults(BehaviorVersion::latest())
            .region(Region::new(config.region.clone()))
            .endpoint_url(config.endpoint.clone())
            .timeout_config(timeout)
            .load()
            .await;
        let client_config = ClientConfig::from(&shared)
            .force_path_style(config.path_style)
            .build();
        Ok(Self {
            client: Client::from_conf(client_config),
            config,
        })
    }

    fn tenant_prefix(&self, tenant_id: &str) -> Result<String, StorageError> {
        validate_tenant(tenant_id)?;
        let tenant = if tenant_id == "standalone" {
            None
        } else {
            Some(format!(
                "tenants/{:x}",
                Sha256::digest(tenant_id.as_bytes())
            ))
        };
        let mut parts = Vec::new();
        if !self.config.prefix.is_empty() {
            parts.push(self.config.prefix.as_str());
        }
        if let Some(tenant) = tenant.as_deref() {
            parts.push(tenant);
        }
        parts.push("objects");
        Ok(format!("{}/", parts.join("/")))
    }

    fn object_key(&self, tenant_id: &str, blob_id: &str) -> Result<String, StorageError> {
        validate_digest(blob_id)?;
        Ok(format!(
            "{}{}/{}",
            self.tenant_prefix(tenant_id)?,
            &blob_id[..2],
            blob_id
        ))
    }

    fn spool_root(&self, tenant_id: &str) -> Result<PathBuf, StorageError> {
        validate_tenant(tenant_id)?;
        if tenant_id == "standalone" {
            Ok(self.config.spool_root.clone())
        } else {
            Ok(self
                .config
                .spool_root
                .join("tenants")
                .join(format!("{:x}", Sha256::digest(tenant_id.as_bytes()))))
        }
    }

    async fn publish(&self, key: &str, digest: &str, content: Vec<u8>) -> Result<(), StorageError> {
        let size = i64::try_from(content.len()).map_err(|_| StorageError::ObjectTooLarge)?;
        if content.len() <= self.config.part_size {
            let request = self
                .apply_put_encryption(self.client.put_object())
                .bucket(&self.config.bucket)
                .key(key)
                .metadata("robine-sha256", digest)
                .body(ByteStream::from(content));
            request
                .send()
                .await
                .map_err(|_| StorageError::Unavailable)?;
        } else {
            self.publish_multipart(key, digest, &content).await?;
        }
        let head = self
            .client
            .head_object()
            .bucket(&self.config.bucket)
            .key(key)
            .send()
            .await
            .map_err(|_| StorageError::Unavailable)?;
        if head.content_length() != Some(size)
            || head
                .metadata()
                .and_then(|metadata| metadata.get("robine-sha256"))
                != Some(&digest.to_owned())
        {
            return Err(StorageError::DigestMismatch);
        }
        Ok(())
    }

    async fn publish_multipart(
        &self,
        key: &str,
        digest: &str,
        content: &[u8],
    ) -> Result<(), StorageError> {
        let create = self
            .apply_create_encryption(self.client.create_multipart_upload())
            .bucket(&self.config.bucket)
            .key(key)
            .metadata("robine-sha256", digest)
            .send()
            .await
            .map_err(|_| StorageError::Unavailable)?;
        let upload_id = create
            .upload_id()
            .ok_or(StorageError::Unavailable)?
            .to_owned();
        let result = self.upload_parts(key, &upload_id, content).await;
        let parts = match result {
            Ok(parts) => parts,
            Err(error) => {
                let _ = self.abort_multipart(key, &upload_id).await;
                return Err(error);
            }
        };
        let upload = CompletedMultipartUpload::builder()
            .set_parts(Some(parts))
            .build();
        if self
            .client
            .complete_multipart_upload()
            .bucket(&self.config.bucket)
            .key(key)
            .upload_id(&upload_id)
            .multipart_upload(upload)
            .send()
            .await
            .is_err()
        {
            let _ = self.abort_multipart(key, &upload_id).await;
            return Err(StorageError::Unavailable);
        }
        Ok(())
    }

    async fn upload_parts(
        &self,
        key: &str,
        upload_id: &str,
        content: &[u8],
    ) -> Result<Vec<CompletedPart>, StorageError> {
        let mut parts = Vec::new();
        for (index, chunk) in content.chunks(self.config.part_size).enumerate() {
            let part_number = i32::try_from(index + 1).map_err(|_| StorageError::ObjectTooLarge)?;
            let uploaded = self
                .client
                .upload_part()
                .bucket(&self.config.bucket)
                .key(key)
                .upload_id(upload_id)
                .part_number(part_number)
                .body(ByteStream::from(chunk.to_vec()))
                .send()
                .await
                .map_err(|_| StorageError::Unavailable)?;
            let etag = uploaded.e_tag().ok_or(StorageError::Unavailable)?;
            parts.push(
                CompletedPart::builder()
                    .part_number(part_number)
                    .e_tag(etag)
                    .build(),
            );
        }
        Ok(parts)
    }

    async fn abort_multipart(&self, key: &str, upload_id: &str) -> Result<(), StorageError> {
        self.client
            .abort_multipart_upload()
            .bucket(&self.config.bucket)
            .key(key)
            .upload_id(upload_id)
            .send()
            .await
            .map_err(|_| StorageError::Unavailable)?;
        Ok(())
    }

    fn apply_put_encryption(
        &self,
        builder: aws_sdk_s3::operation::put_object::builders::PutObjectFluentBuilder,
    ) -> aws_sdk_s3::operation::put_object::builders::PutObjectFluentBuilder {
        match &self.config.encryption {
            S3Encryption::None => builder,
            S3Encryption::Aes256 => builder.server_side_encryption(ServerSideEncryption::Aes256),
            S3Encryption::Kms { key_id } => builder
                .server_side_encryption(ServerSideEncryption::AwsKms)
                .ssekms_key_id(key_id),
        }
    }

    fn apply_create_encryption(
        &self,
        builder: aws_sdk_s3::operation::create_multipart_upload::builders::CreateMultipartUploadFluentBuilder,
    ) -> aws_sdk_s3::operation::create_multipart_upload::builders::CreateMultipartUploadFluentBuilder
    {
        match &self.config.encryption {
            S3Encryption::None => builder,
            S3Encryption::Aes256 => builder.server_side_encryption(ServerSideEncryption::Aes256),
            S3Encryption::Kms { key_id } => builder
                .server_side_encryption(ServerSideEncryption::AwsKms)
                .ssekms_key_id(key_id),
        }
    }
}

#[async_trait]
impl BlobStore for S3BlobStore {
    async fn put(&self, tenant_id: &str, content: Vec<u8>) -> Result<StoredObject, StorageError> {
        if content.len() > self.config.max_object_bytes {
            return Err(StorageError::ObjectTooLarge);
        }
        let digest = format!("{:x}", Sha256::digest(&content));
        let key = self.object_key(tenant_id, &digest)?;
        self.publish(&key, &digest, content.clone()).await?;
        Ok(StoredObject {
            blob_id: digest.clone(),
            digest,
            size: i64::try_from(content.len()).map_err(|_| StorageError::ObjectTooLarge)?,
        })
    }

    async fn get(&self, tenant_id: &str, object: &StoredObject) -> Result<Vec<u8>, StorageError> {
        if object.blob_id != object.digest || object.size < 0 {
            return Err(StorageError::InvalidInput);
        }
        let key = self.object_key(tenant_id, &object.blob_id)?;
        let response = self
            .client
            .get_object()
            .bucket(&self.config.bucket)
            .key(key)
            .send()
            .await
            .map_err(|error| {
                if error
                    .as_service_error()
                    .is_some_and(|error| error.is_no_such_key())
                {
                    StorageError::NotFound
                } else {
                    StorageError::Unavailable
                }
            })?;
        if response.content_length().is_some_and(|size| {
            size < 0
                || usize::try_from(size).map_or(true, |size| size > self.config.max_object_bytes)
        }) {
            return Err(StorageError::ObjectTooLarge);
        }
        let content = response
            .body
            .collect()
            .await
            .map_err(|_| StorageError::Unavailable)?
            .into_bytes()
            .to_vec();
        if content.len() > self.config.max_object_bytes
            || i64::try_from(content.len()).ok() != Some(object.size)
            || format!("{:x}", Sha256::digest(&content)) != object.digest
        {
            return Err(StorageError::DigestMismatch);
        }
        Ok(content)
    }

    async fn delete(&self, tenant_id: &str, blob_id: &str) -> Result<(), StorageError> {
        let key = self.object_key(tenant_id, blob_id)?;
        self.client
            .delete_object()
            .bucket(&self.config.bucket)
            .key(key)
            .send()
            .await
            .map_err(|_| StorageError::Unavailable)?;
        Ok(())
    }

    async fn inventory(&self, tenant_id: &str) -> Result<BlobInventory, StorageError> {
        let prefix = self.tenant_prefix(tenant_id)?;
        let mut continuation = None;
        let mut inventory = BlobInventory::default();
        loop {
            let page = self
                .client
                .list_objects_v2()
                .bucket(&self.config.bucket)
                .prefix(&prefix)
                .set_continuation_token(continuation)
                .send()
                .await
                .map_err(|_| StorageError::Unavailable)?;
            for object in page.contents() {
                let valid = object.key().and_then(|key| blob_id_from_key(&prefix, key));
                if let Some(blob_id) = valid {
                    inventory.objects.push(InventoryObject {
                        blob_id,
                        size: object.size().ok_or(StorageError::Unavailable)?,
                    });
                } else {
                    inventory.unsafe_objects = inventory.unsafe_objects.saturating_add(1);
                }
            }
            if page.is_truncated() != Some(true) {
                break;
            }
            continuation = Some(
                page.next_continuation_token()
                    .ok_or(StorageError::Unavailable)?
                    .to_owned(),
            );
        }
        inventory
            .objects
            .sort_by(|left, right| left.blob_id.cmp(&right.blob_id));
        Ok(inventory)
    }

    async fn delete_temporary_before(
        &self,
        tenant_id: &str,
        cutoff: DateTime<Utc>,
    ) -> Result<u64, StorageError> {
        let root = self.spool_root(tenant_id)?;
        tokio::task::spawn_blocking(move || delete_temporary_local(&root, cutoff))
            .await
            .map_err(|_| StorageError::Unavailable)?
    }
}

fn validate_digest(digest: &str) -> Result<(), StorageError> {
    if digest.len() == 64
        && digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(StorageError::InvalidInput)
    }
}

fn validate_tenant(tenant_id: &str) -> Result<(), StorageError> {
    if tenant_id.is_empty() || tenant_id.contains('\0') {
        Err(StorageError::InvalidInput)
    } else {
        Ok(())
    }
}

fn valid_bucket(bucket: &str) -> bool {
    (3..=63).contains(&bucket.len())
        && bucket
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || b".-".contains(&byte))
        && bucket
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        && bucket
            .bytes()
            .last()
            .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
}

fn valid_prefix(prefix: &str) -> bool {
    prefix.trim_matches('/') == prefix
        && !prefix.contains("..")
        && !prefix.contains("//")
        && !prefix.contains('\\')
}

fn blob_id_from_key(prefix: &str, key: &str) -> Option<String> {
    let suffix = key.strip_prefix(prefix)?;
    let (shard, digest) = suffix.split_once('/')?;
    if shard.len() == 2
        && shard == &digest[..digest.len().min(2)]
        && validate_digest(digest).is_ok()
    {
        Some(digest.to_owned())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(endpoint: &str) -> S3Config {
        S3Config {
            endpoint: endpoint.into(),
            region: "us-east-1".into(),
            bucket: "robine-ci-test".into(),
            prefix: "control-plane".into(),
            path_style: true,
            allow_http_loopback: false,
            max_object_bytes: 10 * 1_024 * 1_024,
            part_size: MINIMUM_PART_SIZE,
            request_timeout: Duration::from_secs(60),
            attempt_timeout: Duration::from_secs(20),
            connect_timeout: Duration::from_secs(5),
            spool_root: std::env::temp_dir().join("robine-s3-spool"),
            encryption: S3Encryption::None,
        }
    }

    #[test]
    fn configuration_rejects_ambiguous_or_insecure_namespaces() {
        assert_eq!(config("https://s3.example.test").validate(), Ok(()));
        for endpoint in [
            "http://s3.example.test",
            "https://user:secret@s3.example.test",
            "https://s3.example.test/path",
            "https://s3.example.test?bucket=other",
        ] {
            assert_eq!(config(endpoint).validate(), Err(StorageError::InvalidInput));
        }
        let mut loopback = config("http://127.0.0.1:9000");
        loopback.allow_http_loopback = true;
        assert_eq!(loopback.validate(), Ok(()));
    }

    #[test]
    fn object_keys_accept_only_exact_content_addressed_shape() {
        let digest = "a".repeat(64);
        let prefix = "deployment/objects/";
        assert_eq!(
            blob_id_from_key(prefix, &format!("{prefix}aa/{digest}")),
            Some(digest)
        );
        assert_eq!(
            blob_id_from_key(prefix, "deployment/objects/ab/not-a-digest"),
            None
        );
    }
}
