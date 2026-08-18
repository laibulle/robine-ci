//! Bounded, provider-neutral source archive extraction.

use async_trait::async_trait;
use flate2::read::GzDecoder;
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use percent_encoding::{AsciiSet, CONTROLS, utf8_percent_encode};
use reqwest::{Client, redirect::Policy};
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use tar::EntryType;
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroizing;

const PATH_SEGMENT: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'#')
    .add(b'%')
    .add(b'/')
    .add(b'<')
    .add(b'>')
    .add(b'?')
    .add(b'[')
    .add(b'\\')
    .add(b']')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}');

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Provider {
    GitHub,
    GitLab,
    Forgejo,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Repository {
    pub id: Uuid,
    pub provider: Provider,
    pub provider_instance: String,
    pub installation_id: i64,
    pub owner: String,
    pub name: String,
    pub full_name: String,
}

#[async_trait]
pub trait RepositoryStore: Send + Sync {
    async fn find_trusted(
        &self,
        tenant_id: &str,
        repository_id: Uuid,
    ) -> Result<Repository, SourceError>;
}

#[async_trait]
pub trait ArchiveFetcher: Send + Sync {
    async fn fetch_archive(
        &self,
        repository: &Repository,
        commit_sha: &str,
    ) -> Result<Vec<u8>, SourceError>;
}

pub struct HttpArchiveFetcher {
    client: Client,
    github_api_origin: String,
    github_app_id: Option<String>,
    github_private_key: Option<Zeroizing<String>>,
    gitlab_origin: Option<String>,
    gitlab_token: Option<Zeroizing<String>>,
    forgejo_origin: Option<String>,
    forgejo_token: Option<Zeroizing<String>>,
}

impl HttpArchiveFetcher {
    /// Builds a redirect-free provider client with bounded connection and request timeouts.
    ///
    /// # Errors
    ///
    /// Returns provider unavailable when the TLS client cannot be constructed.
    pub fn new(
        github_app_id: Option<String>,
        github_private_key: Option<String>,
        gitlab_origin: Option<String>,
        gitlab_token: Option<String>,
        forgejo_origin: Option<String>,
        forgejo_token: Option<String>,
    ) -> Result<Self, SourceError> {
        let client = Client::builder()
            .redirect(Policy::none())
            .connect_timeout(std::time::Duration::from_secs(5))
            .timeout(std::time::Duration::from_secs(15))
            .user_agent("Robine-CI")
            .build()
            .map_err(|_| SourceError::ProviderUnavailable)?;
        Ok(Self {
            client,
            github_api_origin: "https://api.github.com".into(),
            github_app_id,
            github_private_key: github_private_key.map(Zeroizing::new),
            gitlab_origin: normalize_origin(gitlab_origin)?,
            gitlab_token: gitlab_token.map(Zeroizing::new),
            forgejo_origin: normalize_origin(forgejo_origin)?,
            forgejo_token: forgejo_token.map(Zeroizing::new),
        })
    }

    async fn github_token(&self, installation_id: i64) -> Result<String, SourceError> {
        let app_id = self
            .github_app_id
            .as_deref()
            .filter(|value| !value.is_empty())
            .ok_or(SourceError::ProviderUnavailable)?;
        let private_key = self
            .github_private_key
            .as_deref()
            .ok_or(SourceError::ProviderUnavailable)?;
        let now = chrono::Utc::now().timestamp() - 60;
        let claims = GitHubClaims {
            iat: now,
            exp: now + 540,
            iss: app_id,
        };
        let key = EncodingKey::from_rsa_pem(private_key.as_bytes())
            .map_err(|_| SourceError::ProviderUnavailable)?;
        let jwt = encode(&Header::new(Algorithm::RS256), &claims, &key)
            .map_err(|_| SourceError::ProviderUnavailable)?;
        let response = self
            .client
            .post(format!(
                "{}/app/installations/{installation_id}/access_tokens",
                self.github_api_origin
            ))
            .bearer_auth(jwt)
            .header("accept", "application/vnd.github+json")
            .header("x-github-api-version", "2022-11-28")
            .send()
            .await
            .map_err(|_| SourceError::ProviderUnavailable)?;
        if !response.status().is_success() {
            return Err(SourceError::ProviderUnavailable);
        }
        response
            .json::<GitHubToken>()
            .await
            .map(|body| body.token)
            .map_err(|_| SourceError::ProviderUnavailable)
    }

    async fn bounded_body(&self, mut response: reqwest::Response) -> Result<Vec<u8>, SourceError> {
        if !response.status().is_success()
            || response
                .content_length()
                .is_some_and(|length| length > 100_000_000)
        {
            return Err(SourceError::ProviderUnavailable);
        }
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| SourceError::ProviderUnavailable)?
        {
            if body.len().saturating_add(chunk.len()) > 100_000_000 {
                return Err(SourceError::CompressedLimit);
            }
            body.extend_from_slice(&chunk);
        }
        Ok(body)
    }

    async fn github_archive_response(
        &self,
        repository: &Repository,
        commit_sha: &str,
    ) -> Result<reqwest::Response, SourceError> {
        let token = self.github_token(repository.installation_id).await?;
        let response = self
            .client
            .get(format!(
                "{}/repos/{}/{}/tarball/{commit_sha}",
                self.github_api_origin,
                segment(&repository.owner),
                segment(&repository.name)
            ))
            .bearer_auth(token)
            .header("accept", "application/vnd.github+json")
            .header("x-github-api-version", "2022-11-28")
            .send()
            .await
            .map_err(|_| SourceError::ProviderUnavailable)?;
        if !response.status().is_redirection() {
            return Ok(response);
        }
        let location = response
            .headers()
            .get(reqwest::header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .ok_or(SourceError::ProviderUnavailable)?;
        let target = reqwest::Url::parse(location).map_err(|_| SourceError::ProviderUnavailable)?;
        if target.scheme() != "https"
            || target.host_str() != Some("codeload.github.com")
            || target.username() != ""
            || target.password().is_some()
        {
            return Err(SourceError::ProviderUnavailable);
        }
        self.client
            .get(target)
            .send()
            .await
            .map_err(|_| SourceError::ProviderUnavailable)
    }
}

#[async_trait]
impl ArchiveFetcher for HttpArchiveFetcher {
    async fn fetch_archive(
        &self,
        repository: &Repository,
        commit_sha: &str,
    ) -> Result<Vec<u8>, SourceError> {
        if !valid_commit_sha(commit_sha) {
            return Err(SourceError::InvalidCommit);
        }
        let response = match repository.provider {
            Provider::GitHub => {
                if repository.provider_instance != "https://github.com" {
                    return Err(SourceError::ProviderUnavailable);
                }
                Ok(self.github_archive_response(repository, commit_sha).await?)
            }
            Provider::GitLab => {
                let (origin, token) = configured_provider(
                    &repository.provider_instance,
                    self.gitlab_origin.as_deref(),
                    self.gitlab_token.as_ref().map(|token| token.as_str()),
                )?;
                self.client
                    .get(format!(
                        "{origin}/api/v4/projects/{}/repository/archive.tar.gz",
                        segment(&repository.full_name)
                    ))
                    .query(&[("sha", commit_sha)])
                    .header("private-token", token)
                    .send()
                    .await
                    .map_err(|_| SourceError::ProviderUnavailable)
            }
            Provider::Forgejo => {
                let (origin, token) = configured_provider(
                    &repository.provider_instance,
                    self.forgejo_origin.as_deref(),
                    self.forgejo_token.as_ref().map(|token| token.as_str()),
                )?;
                self.client
                    .get(format!(
                        "{origin}/api/v1/repos/{}/{}/archive/{commit_sha}.tar.gz",
                        segment(&repository.owner),
                        segment(&repository.name)
                    ))
                    .header("authorization", format!("token {token}"))
                    .send()
                    .await
                    .map_err(|_| SourceError::ProviderUnavailable)
            }
        }?;
        self.bounded_body(response).await
    }
}

#[derive(Serialize)]
struct GitHubClaims<'a> {
    iat: i64,
    exp: i64,
    iss: &'a str,
}

#[derive(Deserialize)]
struct GitHubToken {
    token: String,
}

fn segment(value: &str) -> impl std::fmt::Display + '_ {
    utf8_percent_encode(value, PATH_SEGMENT)
}

fn normalize_origin(origin: Option<String>) -> Result<Option<String>, SourceError> {
    origin
        .map(|origin| {
            let parsed =
                reqwest::Url::parse(&origin).map_err(|_| SourceError::ProviderUnavailable)?;
            let loopback_http = parsed.scheme() == "http"
                && matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "::1"));
            if parsed.scheme() != "https" && !loopback_http
                || parsed.host_str().is_none()
                || parsed.username() != ""
                || parsed.password().is_some()
                || parsed.query().is_some()
                || parsed.fragment().is_some()
                || !matches!(parsed.path(), "" | "/")
            {
                return Err(SourceError::ProviderUnavailable);
            }
            Ok(origin.trim_end_matches('/').to_owned())
        })
        .transpose()
}

fn configured_provider<'a>(
    repository_origin: &str,
    configured_origin: Option<&'a str>,
    token: Option<&'a str>,
) -> Result<(&'a str, &'a str), SourceError> {
    let origin = configured_origin.ok_or(SourceError::ProviderUnavailable)?;
    let token = token
        .filter(|value| !value.is_empty())
        .ok_or(SourceError::ProviderUnavailable)?;
    if repository_origin != origin {
        return Err(SourceError::ProviderUnavailable);
    }
    Ok((origin, token))
}

/// The legacy-compatible limits applied before source reaches an executor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ArchiveLimits {
    pub max_compressed_bytes: usize,
    pub max_entries: usize,
    pub max_expanded_bytes: usize,
    pub max_expansion_ratio: usize,
    pub max_path_bytes: usize,
    pub max_duration: std::time::Duration,
}

impl Default for ArchiveLimits {
    fn default() -> Self {
        Self {
            max_compressed_bytes: 100_000_000,
            max_entries: 10_000,
            max_expanded_bytes: 1_000_000_000,
            max_expansion_ratio: 100,
            max_path_bytes: 4_096,
            max_duration: std::time::Duration::from_secs(10),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceFile {
    pub path: PathBuf,
    pub contents: Vec<u8>,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum SourceError {
    #[error("source repository is unavailable or untrusted")]
    RepositoryUnavailable,
    #[error("source commit SHA is invalid")]
    InvalidCommit,
    #[error("source provider is unavailable")]
    ProviderUnavailable,
    #[error("source archive exceeds its compressed size limit")]
    CompressedLimit,
    #[error("source archive is malformed")]
    Malformed,
    #[error("source archive contains too many entries")]
    EntryLimit,
    #[error("source archive exceeds its expanded size limit")]
    ExpandedLimit,
    #[error("source archive exceeds its expansion ratio")]
    ExpansionRatio,
    #[error("source archive contains an unsafe path")]
    UnsafePath,
    #[error("source archive contains an unsupported entry")]
    UnsupportedEntry,
    #[error("source archive has no common root directory")]
    MissingRoot,
    #[error("source archive parsing exceeded its deadline")]
    Timeout,
}

#[must_use]
pub fn valid_commit_sha(value: &str) -> bool {
    value.len() == 40
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Extracts regular files from a gzip-compressed tarball after stripping one common root.
///
/// # Errors
///
/// Rejects malformed, oversized, rootless, traversal-bearing, or special-file archives.
pub fn extract_tar_gz(
    compressed: &[u8],
    limits: ArchiveLimits,
) -> Result<Vec<SourceFile>, SourceError> {
    if compressed.len() > limits.max_compressed_bytes {
        return Err(SourceError::CompressedLimit);
    }
    let decoder = GzDecoder::new(compressed);
    let mut archive = tar::Archive::new(decoder);
    let entries = archive.entries().map_err(|_| SourceError::Malformed)?;
    let mut root: Option<Vec<u8>> = None;
    let mut files = Vec::new();
    let mut entry_count = 0_usize;
    let mut expanded = 0_usize;
    let started = std::time::Instant::now();

    for entry in entries {
        enforce_deadline(started, limits.max_duration)?;
        entry_count = entry_count.checked_add(1).ok_or(SourceError::EntryLimit)?;
        if entry_count > limits.max_entries {
            return Err(SourceError::EntryLimit);
        }
        let mut entry = entry.map_err(|_| SourceError::Malformed)?;
        let entry_type = entry.header().entry_type();
        if entry_type == EntryType::XGlobalHeader {
            expanded = checked_expanded(expanded, entry.size(), compressed.len(), limits)?;
            drain_entry(&mut entry, started, limits.max_duration)?;
            continue;
        }
        if !entry_type.is_file() && !entry_type.is_dir() {
            return Err(SourceError::UnsupportedEntry);
        }
        expanded = checked_expanded(expanded, entry.size(), compressed.len(), limits)?;

        let raw_path = entry.path_bytes();
        if raw_path.is_empty()
            || raw_path.len() > limits.max_path_bytes
            || raw_path.contains(&0)
            || raw_path.starts_with(b"/")
        {
            return Err(SourceError::UnsafePath);
        }
        let path = Path::new(std::str::from_utf8(&raw_path).map_err(|_| SourceError::UnsafePath)?);
        let mut components = path.components();
        let Component::Normal(first) = components.next().ok_or(SourceError::UnsafePath)? else {
            return Err(SourceError::UnsafePath);
        };
        if components
            .clone()
            .any(|component| !matches!(component, Component::Normal(_)))
        {
            return Err(SourceError::UnsafePath);
        }
        let first = first.as_encoded_bytes();
        match &root {
            Some(expected) if expected.as_slice() != first => return Err(SourceError::MissingRoot),
            None => root = Some(first.to_vec()),
            _ => {}
        }
        let relative = components.collect::<PathBuf>();
        if relative.as_os_str().is_empty() {
            if entry_type.is_file() {
                return Err(SourceError::MissingRoot);
            }
            continue;
        }
        if entry_type.is_dir() {
            continue;
        }

        let expected_size =
            usize::try_from(entry.size()).map_err(|_| SourceError::ExpandedLimit)?;
        let contents = read_entry(&mut entry, expected_size, started, limits.max_duration)?;
        if contents.len() != expected_size {
            return Err(SourceError::Malformed);
        }
        files.push(SourceFile {
            path: relative,
            contents,
        });
    }
    root.ok_or(SourceError::MissingRoot)?;
    Ok(files)
}

/// Validates a workspace archive whose paths are already relative to the workspace root.
///
/// # Errors
///
/// Rejects the same malformed, special, traversal-bearing, or oversized entries as source
/// extraction, without requiring or stripping a provider archive root.
pub fn validate_workspace_tar_gz(
    compressed: &[u8],
    limits: ArchiveLimits,
) -> Result<(), SourceError> {
    if compressed.len() > limits.max_compressed_bytes {
        return Err(SourceError::CompressedLimit);
    }
    let decoder = GzDecoder::new(compressed);
    let mut archive = tar::Archive::new(decoder);
    let entries = archive.entries().map_err(|_| SourceError::Malformed)?;
    let mut entry_count = 0_usize;
    let mut expanded = 0_usize;
    let started = std::time::Instant::now();
    for entry in entries {
        enforce_deadline(started, limits.max_duration)?;
        entry_count = entry_count.checked_add(1).ok_or(SourceError::EntryLimit)?;
        if entry_count > limits.max_entries {
            return Err(SourceError::EntryLimit);
        }
        let mut entry = entry.map_err(|_| SourceError::Malformed)?;
        let entry_type = entry.header().entry_type();
        if entry_type == EntryType::XGlobalHeader {
            expanded = checked_expanded(expanded, entry.size(), compressed.len(), limits)?;
            drain_entry(&mut entry, started, limits.max_duration)?;
            continue;
        }
        if !entry_type.is_file() && !entry_type.is_dir() {
            return Err(SourceError::UnsupportedEntry);
        }
        expanded = checked_expanded(expanded, entry.size(), compressed.len(), limits)?;
        let raw_path = entry.path_bytes();
        if raw_path.is_empty()
            || raw_path.len() > limits.max_path_bytes
            || raw_path.contains(&0)
            || raw_path.starts_with(b"/")
        {
            return Err(SourceError::UnsafePath);
        }
        let path = Path::new(std::str::from_utf8(&raw_path).map_err(|_| SourceError::UnsafePath)?);
        if path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
        {
            return Err(SourceError::UnsafePath);
        }
        drain_entry(&mut entry, started, limits.max_duration)?;
    }
    Ok(())
}

fn checked_expanded(
    current: usize,
    added: u64,
    compressed: usize,
    limits: ArchiveLimits,
) -> Result<usize, SourceError> {
    let added = usize::try_from(added).map_err(|_| SourceError::ExpandedLimit)?;
    let expanded = current
        .checked_add(added)
        .ok_or(SourceError::ExpandedLimit)?;
    if expanded > limits.max_expanded_bytes {
        return Err(SourceError::ExpandedLimit);
    }
    let ratio_limit = compressed
        .checked_mul(limits.max_expansion_ratio)
        .ok_or(SourceError::ExpansionRatio)?;
    if expanded > ratio_limit {
        return Err(SourceError::ExpansionRatio);
    }
    Ok(expanded)
}

fn enforce_deadline(
    started: std::time::Instant,
    maximum: std::time::Duration,
) -> Result<(), SourceError> {
    if started.elapsed() > maximum {
        Err(SourceError::Timeout)
    } else {
        Ok(())
    }
}

fn drain_entry(
    reader: &mut impl Read,
    started: std::time::Instant,
    maximum: std::time::Duration,
) -> Result<(), SourceError> {
    let mut buffer = vec![0_u8; 65_536];
    loop {
        enforce_deadline(started, maximum)?;
        if reader
            .read(&mut buffer)
            .map_err(|_| SourceError::Malformed)?
            == 0
        {
            return Ok(());
        }
    }
}

fn read_entry(
    reader: &mut impl Read,
    expected: usize,
    started: std::time::Instant,
    maximum: std::time::Duration,
) -> Result<Vec<u8>, SourceError> {
    let mut content = Vec::with_capacity(expected.min(1_048_576));
    let mut buffer = vec![0_u8; 65_536];
    loop {
        enforce_deadline(started, maximum)?;
        let size = reader
            .read(&mut buffer)
            .map_err(|_| SourceError::Malformed)?;
        if size == 0 {
            return Ok(content);
        }
        content.extend_from_slice(&buffer[..size]);
        if content.len() > expected {
            return Err(SourceError::Malformed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{Compression, write::GzEncoder};

    fn archive(entries: &[(&str, EntryType, &[u8])]) -> Vec<u8> {
        let gzip = GzEncoder::new(Vec::new(), Compression::default());
        let mut builder = tar::Builder::new(gzip);
        for (path, entry_type, contents) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_entry_type(*entry_type);
            header.set_mode(0o644);
            header.set_size(contents.len() as u64);
            header.set_cksum();
            builder.append_data(&mut header, path, *contents).unwrap();
        }
        builder.into_inner().unwrap().finish().unwrap()
    }

    fn archive_with_raw_path(path: &[u8]) -> Vec<u8> {
        let gzip = GzEncoder::new(Vec::new(), Compression::default());
        let mut builder = tar::Builder::new(gzip);
        let mut header = tar::Header::new_gnu();
        header.set_entry_type(EntryType::Regular);
        header.set_mode(0o644);
        header.set_size(1);
        header.as_mut_bytes()[..path.len()].copy_from_slice(path);
        header.set_cksum();
        builder.append(&header, b"x".as_slice()).unwrap();
        builder.into_inner().unwrap().finish().unwrap()
    }

    #[test]
    fn extracts_files_below_one_common_root() {
        let bytes = archive(&[
            ("repo-deadbeef/", EntryType::Directory, b""),
            (
                "repo-deadbeef/src/lib.rs",
                EntryType::Regular,
                b"fn main() {}",
            ),
        ]);
        assert_eq!(
            extract_tar_gz(&bytes, ArchiveLimits::default()).unwrap(),
            vec![SourceFile {
                path: PathBuf::from("src/lib.rs"),
                contents: b"fn main() {}".to_vec(),
            }]
        );
    }

    #[test]
    fn rejects_special_entries_and_multiple_roots() {
        let link = archive(&[("repo/link", EntryType::Symlink, b"")]);
        assert_eq!(
            extract_tar_gz(&link, ArchiveLimits::default()),
            Err(SourceError::UnsupportedEntry)
        );
        let roots = archive(&[
            ("one/file", EntryType::Regular, b"one"),
            ("two/file", EntryType::Regular, b"two"),
        ]);
        assert_eq!(
            extract_tar_gz(&roots, ArchiveLimits::default()),
            Err(SourceError::MissingRoot)
        );
    }

    #[test]
    fn enforces_entry_and_expansion_limits() {
        let bytes = archive(&[("repo/a", EntryType::Regular, &[0; 1_024])]);
        assert_eq!(
            extract_tar_gz(
                &bytes,
                ArchiveLimits {
                    max_entries: 0,
                    ..ArchiveLimits::default()
                }
            ),
            Err(SourceError::EntryLimit)
        );
        assert_eq!(
            extract_tar_gz(
                &bytes,
                ArchiveLimits {
                    max_expanded_bytes: 100,
                    ..ArchiveLimits::default()
                }
            ),
            Err(SourceError::ExpandedLimit)
        );
    }

    #[test]
    fn validates_workspace_archives_without_a_provider_root() {
        let bytes = archive(&[("deps/cache.bin", EntryType::Regular, b"cached")]);
        assert_eq!(
            validate_workspace_tar_gz(&bytes, ArchiveLimits::default()),
            Ok(())
        );
        let traversal = archive_with_raw_path(b"../escape");
        assert_eq!(
            validate_workspace_tar_gz(&traversal, ArchiveLimits::default()),
            Err(SourceError::UnsafePath)
        );
        assert_eq!(
            validate_workspace_tar_gz(
                &bytes,
                ArchiveLimits {
                    max_duration: std::time::Duration::ZERO,
                    ..ArchiveLimits::default()
                }
            ),
            Err(SourceError::Timeout)
        );
    }
}
