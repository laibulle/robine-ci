#!/bin/bash
set -euo pipefail

repository="laibulle/robine-ci"
asset_name="robine-runner-macos-multiarch.tar.gz"
api_url="https://api.github.com/repos/${repository}/releases/latest"
install_dir="${RBE_INSTALL_DIR:-${HOME}/.local/bin}"
config_path="${RBE_CONFIG_PATH:-${HOME}/.config/robine-runner/config.json}"
launch_agent_dir="${HOME}/Library/LaunchAgents"
launch_agent_path="${launch_agent_dir}/com.robine.runner.plist"
log_dir="${HOME}/Library/Logs/RobineRunner"
service_label="com.robine.runner"
temporary_dir=""
temporary_destination=""
temporary_launch_agent=""

cleanup() {
  if [[ -n "${temporary_destination}" ]]; then
    rm -f "${temporary_destination}"
  fi

  if [[ -n "${temporary_launch_agent}" ]]; then
    rm -f "${temporary_launch_agent}"
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

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required"

case "$(uname -m)" in
  arm64)
    architecture="arm64"
    ;;
  x86_64)
    architecture="amd64"
    ;;
  *)
    fail "unsupported architecture: $(uname -m)"
    ;;
esac

[[ "${install_dir}" == /* ]] || fail "RBE_INSTALL_DIR must be an absolute path"
[[ "${config_path}" == /* ]] || fail "RBE_CONFIG_PATH must be an absolute path"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v launchctl >/dev/null 2>&1 || fail "launchctl is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

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
printf 'Downloading rbe %s for macOS %s...\n' "${tag#v}" "${architecture}"
curl --proto '=https' --tlsv1.2 -fL "${asset_url}" -o "${archive_path}"

actual_sha256=$(shasum -a 256 "${archive_path}" | awk '{print $1}')
[[ "${actual_sha256}" == "${expected_sha256}" ]] || fail "SHA-256 verification failed"

version="${tag#v}"
relative_binary="dist/runner-go/macos/robine-runner-${version}-darwin-${architecture}"
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

xml_home=$(printf '%s' "${HOME}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
xml_binary=$(printf '%s' "${install_dir}/rbe" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
xml_config=$(printf '%s' "${config_path}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
xml_log_dir=$(printf '%s' "${log_dir}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

mkdir -p "$(dirname "${config_path}")" "${launch_agent_dir}" "${log_dir}"
chmod 0700 "$(dirname "${config_path}")"
temporary_launch_agent=$(mktemp "${launch_agent_dir}/.com.robine.runner.XXXXXX")
cat >"${temporary_launch_agent}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${service_label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>${xml_binary}</string>
      <string>start</string>
      <string>--config</string>
      <string>${xml_config}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${xml_home}</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${xml_home}</string>
      <key>PATH</key>
      <string>${xml_home}/.cargo/bin:${xml_home}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
      <key>SuccessfulExit</key>
      <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${xml_log_dir}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${xml_log_dir}/stderr.log</string>
  </dict>
</plist>
EOF
chmod 0600 "${temporary_launch_agent}"
mv -f "${temporary_launch_agent}" "${launch_agent_path}"
temporary_launch_agent=""
printf 'Installed launchd service definition at %s\n' "${launch_agent_path}"

if [[ -f "${config_path}" ]]; then
  launchctl bootout "gui/$(id -u)/${service_label}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "${launch_agent_path}"
  launchctl kickstart -k "gui/$(id -u)/${service_label}"
  printf 'Started %s\n' "${service_label}"
else
  printf 'The service will be started after runner enrollment creates %s\n' "${config_path}"
fi

case ":${PATH}:" in
  *":${install_dir}:"*)
    ;;
  *)
    printf 'Add %s to PATH, for example:\n  echo '\''export PATH="%s:$PATH"'\'' >> ~/.zprofile\n' \
      "${install_dir}" "${install_dir}"
    ;;
esac
