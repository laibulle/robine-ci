#!/bin/bash
set -euo pipefail

repository="laibulle/robine-ci"
api_url="https://api.github.com/repos/${repository}/releases/latest"
install_dir="${RBE_INSTALL_DIR:-${HOME}/.local/bin}"
config_path="${RBE_CONFIG_PATH:-}"
server_url="${RBE_SERVER_URL:-}"
skip_service_install="${RBE_SKIP_SERVICE_INSTALL:-0}"
temporary_dir=""
temporary_destination=""

cleanup() {
  if [[ -n "${temporary_destination}" ]]; then
    rm -f "${temporary_destination}"
  fi

  if [[ -n "${temporary_dir}" ]]; then
    rm -rf "${temporary_dir}"
  fi
}

fail() {
  printf 'rbe installer: %s\n' "$1" >&2
  exit 1
}

trap cleanup EXIT HUP INT TERM

case "$(uname -s)" in
  Darwin)
    platform="macOS"
    asset_platform="macos"
    binary_platform="darwin"
    profile_path="${HOME}/.zprofile"
    ;;
  Linux)
    platform="Linux"
    asset_platform="linux"
    binary_platform="linux"
    profile_path="${HOME}/.profile"
    ;;
  *)
    fail "unsupported operating system: $(uname -s)"
    ;;
esac

asset_name="robine-runner-${asset_platform}-multiarch.tar.gz"

case "$(uname -m)" in
  arm64|aarch64)
    architecture="arm64"
    ;;
  x86_64|amd64)
    architecture="amd64"
    ;;
  *)
    fail "unsupported architecture: $(uname -m)"
    ;;
esac

[[ "${install_dir}" == /* ]] || fail "RBE_INSTALL_DIR must be an absolute path"
if [[ -n "${config_path}" && "${config_path}" != /* ]]; then
  fail "RBE_CONFIG_PATH must be an absolute path"
fi
case "${skip_service_install}" in
  0|1)
    ;;
  *)
    fail "RBE_SKIP_SERVICE_INSTALL must be 0 or 1"
    ;;
esac
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/rbe-install.XXXXXX")
metadata_path="${temporary_dir}/release.json"
archive_path="${temporary_dir}/${asset_name}"

curl --proto '=https' --tlsv1.2 -fsSL \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "${api_url}" \
  -o "${metadata_path}"

tag=$(sed -n 's/^[[:space:]]*"tag_name": "\([^"]*\)",/\1/p' "${metadata_path}")

if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
  fail "GitHub returned an invalid latest release tag: ${tag:-missing}"
fi

expected_sha256=$(awk -v asset="${asset_name}" '
  index($0, "\"name\": \"" asset "\"") { matching_asset = 1 }
  matching_asset && index($0, "\"digest\": \"sha256:") {
    digest = $0
    sub(/^.*"digest": "sha256:/, "", digest)
    sub(/".*$/, "", digest)
    print digest
    exit
  }
' "${metadata_path}")

if [[ ! "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
  fail "the latest GitHub release does not publish a valid SHA-256 digest for ${asset_name}"
fi

asset_url="https://github.com/${repository}/releases/download/${tag}/${asset_name}"
printf 'Downloading rbe %s for %s %s...\n' "${tag#v}" "${platform}" "${architecture}"
curl --proto '=https' --tlsv1.2 -fL "${asset_url}" -o "${archive_path}"

actual_sha256=$(sha256_file "${archive_path}")
[[ "${actual_sha256}" == "${expected_sha256}" ]] || fail "SHA-256 verification failed"

version="${tag#v}"
relative_binary="dist/runner-go/${asset_platform}/robine-runner-${version}-${binary_platform}-${architecture}"
source_binary="${temporary_dir}/${relative_binary}"
tar -xzf "${archive_path}" -C "${temporary_dir}" -- "${relative_binary}"

if [[ ! -f "${source_binary}" || -L "${source_binary}" ]]; then
  fail "the release archive does not contain the expected regular ${architecture} binary"
fi

chmod 0755 "${source_binary}"
released_version=$("${source_binary}" version)
[[ "${released_version}" == "robine-runner ${version}" ]] || fail "the downloaded runner reported an unexpected version"

mkdir -p "${install_dir}"
temporary_destination=$(mktemp "${install_dir}/.rbe-install.XXXXXX")
install -m 0755 "${source_binary}" "${temporary_destination}"
mv -f "${temporary_destination}" "${install_dir}/rbe"
temporary_destination=""

installed_version=$("${install_dir}/rbe" version)
printf 'Installed %s at %s/rbe\n' "${installed_version}" "${install_dir}"

default_config_path="${HOME}/.config/robine-runner/config.json"
install_service=false
install_arguments=(install)
if [[ -n "${config_path}" ]]; then
  install_arguments+=(--config "${config_path}")
  install_service=true
elif [[ -f "${default_config_path}" ]]; then
  install_service=true
fi
if [[ -n "${server_url}" ]]; then
  install_arguments+=(--server "${server_url}")
fi

if [[ "${skip_service_install}" == 1 ]]; then
  printf 'Service installation deferred until enrollment completes.\n'
elif [[ "${install_service}" == true ]]; then
  "${install_dir}/rbe" "${install_arguments[@]}"
else
  printf 'No runner config exists yet. Enroll the runner, then run:\n'
  printf '  %s/rbe install --config /absolute/path/to/config.json --server https://ci.example.com\n' "${install_dir}"
fi

case ":${PATH}:" in
  *":${install_dir}:"*)
    ;;
  *)
    printf 'Add %s to PATH, for example:\n  echo '\''export PATH="%s:$PATH"'\'' >> %s\n' \
      "${install_dir}" "${install_dir}" "${profile_path}"
    ;;
esac
