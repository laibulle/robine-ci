use aws_config::{BehaviorVersion, Region};
use aws_sdk_s3::{Client, config::Builder as ClientConfig, primitives::ByteStream};
use chrono::{Duration as ChronoDuration, Utc};
use robine_storage::{BlobStore, S3BlobStore, S3Config, S3Encryption, StorageError};
use std::{path::PathBuf, time::Duration};
use uuid::Uuid;

fn config(endpoint: String, bucket: String, prefix: String) -> S3Config {
    S3Config {
        endpoint,
        region: "us-east-1".into(),
        bucket,
        prefix,
        path_style: true,
        allow_http_loopback: true,
        max_object_bytes: 12 * 1_024 * 1_024,
        part_size: 5 * 1_024 * 1_024,
        request_timeout: Duration::from_secs(60),
        attempt_timeout: Duration::from_secs(30),
        connect_timeout: Duration::from_secs(5),
        spool_root: std::env::temp_dir().join(format!("robine-s3-{}", Uuid::new_v4())),
        encryption: S3Encryption::None,
    }
}

async fn client(config: &S3Config) -> Client {
    let shared = aws_config::defaults(BehaviorVersion::latest())
        .region(Region::new(config.region.clone()))
        .endpoint_url(config.endpoint.clone())
        .load()
        .await;
    Client::from_conf(
        ClientConfig::from(&shared)
            .force_path_style(config.path_style)
            .build(),
    )
}

#[tokio::test]
async fn s3_contract_is_digest_verified_paginated_and_multipart_safe() {
    let Ok(endpoint) = std::env::var("ROBINE_S3_INTEGRATION_ENDPOINT") else {
        return;
    };
    let bucket = format!("robine-rust-{}", Uuid::new_v4().simple());
    let prefix = format!("integration/{}", Uuid::new_v4());
    let config = config(endpoint, bucket.clone(), prefix.clone());
    let raw = client(&config).await;
    raw.create_bucket()
        .bucket(&bucket)
        .send()
        .await
        .expect("create integration bucket");
    let store = S3BlobStore::new(config.clone()).await.expect("S3 store");
    store.health().await.expect("bucket health");
    let tenant = format!("s3-tenant-{}", Uuid::new_v4());

    let content = vec![b'x'; 6 * 1_024 * 1_024];
    let object = store
        .put(&tenant, content.clone())
        .await
        .expect("multipart put");
    assert_eq!(store.get(&tenant, &object).await.expect("verified get"), content);
    assert_eq!(
        store
            .get(
                &tenant,
                &robine_storage::StoredObject {
                    digest: "0".repeat(64),
                    ..object.clone()
                },
            )
            .await,
        Err(StorageError::InvalidInput)
    );

    let tenant_hash = format!("{:x}", sha2::Sha256::digest(tenant.as_bytes()));
    let unsafe_key = format!("{prefix}/tenants/{tenant_hash}/objects/not-content-addressed");
    raw.put_object()
        .bucket(&bucket)
        .key(unsafe_key)
        .body(ByteStream::from_static(b"unsafe"))
        .send()
        .await
        .expect("unsafe inventory fixture");
    let inventory = store.inventory(&tenant).await.expect("complete inventory");
    assert_eq!(inventory.objects.len(), 1);
    assert_eq!(inventory.objects[0].blob_id, object.blob_id);
    assert_eq!(inventory.unsafe_objects, 1);

    let spool = config.spool_root.join("tenants").join(tenant_hash);
    std::fs::create_dir_all(&spool).expect("spool root");
    std::fs::write(spool.join("abandoned"), b"partial").expect("spool fixture");
    assert_eq!(
        store
            .delete_temporary_before(&tenant, Utc::now() + ChronoDuration::seconds(1))
            .await
            .expect("temporary cleanup"),
        1
    );
    store
        .delete(&tenant, &object.blob_id)
        .await
        .expect("first delete");
    store
        .delete(&tenant, &object.blob_id)
        .await
        .expect("idempotent delete");
    assert_eq!(store.get(&tenant, &object).await, Err(StorageError::NotFound));

    raw.delete_object()
        .bucket(&bucket)
        .key(format!(
            "{prefix}/tenants/{}/objects/not-content-addressed",
            format!("{:x}", sha2::Sha256::digest(tenant.as_bytes()))
        ))
        .send()
        .await
        .expect("delete unsafe fixture");
    raw.delete_bucket()
        .bucket(&bucket)
        .send()
        .await
        .expect("delete integration bucket");
    let _ = std::fs::remove_dir_all(PathBuf::from(config.spool_root));
}
