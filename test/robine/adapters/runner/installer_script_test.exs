defmodule Robine.Adapters.Runner.InstallerScriptTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @version "9.8.7-alpha1"

  test "the POSIX installer selects and verifies Darwin and Linux release binaries", %{
    tmp_dir: tmp_dir
  } do
    targets = [
      %{
        os: "Darwin",
        platform: "macOS",
        machine: "arm64",
        asset: "macos",
        binary_os: "darwin",
        arch: "arm64"
      },
      %{
        os: "Linux",
        platform: "Linux",
        machine: "x86_64",
        asset: "linux",
        binary_os: "linux",
        arch: "amd64"
      }
    ]

    for target <- targets do
      case_root = Path.join(tmp_dir, String.downcase(target.os))
      fixture = installer_fixture!(case_root, target)

      assert {output, 0} = run_installer(fixture, target)
      assert output =~ "Downloading rbe #{@version} for #{target.platform} #{target.arch}"
      assert output =~ "Installed robine-runner #{@version}"

      installed = Path.join(fixture.install_dir, "rbe")
      assert File.stat!(installed).mode |> Bitwise.band(0o111) != 0
      assert {"robine-runner #{@version}\n", 0} = System.cmd(installed, ["version"])
    end
  end

  test "a digest mismatch leaves an existing installation unchanged", %{tmp_dir: tmp_dir} do
    target = %{
      os: "Linux",
      platform: "Linux",
      machine: "aarch64",
      asset: "linux",
      binary_os: "linux",
      arch: "arm64"
    }

    fixture = installer_fixture!(tmp_dir, target, String.duplicate("0", 64))
    destination = Path.join(fixture.install_dir, "rbe")
    File.mkdir_p!(fixture.install_dir)
    File.write!(destination, "existing runner\n")

    assert {output, status} = run_installer(fixture, target)
    assert status != 0
    assert output =~ "SHA-256 verification failed"
    assert File.read!(destination) == "existing runner\n"
  end

  defp installer_fixture!(root, target, digest_override \\ nil) do
    fake_bin = Path.join(root, "fake-bin")
    home = Path.join(root, "home")
    archive_root = Path.join(root, "archive")
    install_dir = Path.join([home, ".local", "bin"])
    asset_name = "robine-runner-#{target.asset}-multiarch.tar.gz"

    relative_binary =
      "dist/runner-go/#{target.asset}/robine-runner-#{@version}-#{target.binary_os}-#{target.arch}"

    source_binary = Path.join(archive_root, relative_binary)
    archive = Path.join(root, asset_name)
    metadata = Path.join(root, "release.json")

    File.mkdir_p!(Path.dirname(source_binary))
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(home)

    File.write!(source_binary, "#!/bin/sh\nprintf 'robine-runner #{@version}\\n'\n")
    File.chmod!(source_binary, 0o755)
    assert {_, 0} = System.cmd("tar", ["-czf", archive, "-C", archive_root, relative_binary])

    digest = digest_override || sha256(archive)

    File.write!(
      metadata,
      ~s({\n  "tag_name": "v#{@version}",\n  "assets": [\n    {"name": "#{asset_name}", "digest": "sha256:#{digest}"}\n  ]\n}\n)
    )

    write_executable!(
      Path.join(fake_bin, "uname"),
      """
      #!/bin/sh
      case "$1" in
        -s) printf '%s\\n' "$FAKE_UNAME_S" ;;
        -m) printf '%s\\n' "$FAKE_UNAME_M" ;;
        *) exit 2 ;;
      esac
      """
    )

    write_executable!(
      Path.join(fake_bin, "curl"),
      """
      #!/bin/sh
      destination=''
      url=''
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -o) destination=$2; shift 2 ;;
          http*) url=$1; shift ;;
          *) shift ;;
        esac
      done
      case "$url" in
        *api.github.com*) cp "$FAKE_RELEASE_METADATA" "$destination" ;;
        *) cp "$FAKE_RELEASE_ARCHIVE" "$destination" ;;
      esac
      """
    )

    %{
      archive: archive,
      metadata: metadata,
      fake_bin: fake_bin,
      home: home,
      install_dir: install_dir
    }
  end

  defp run_installer(fixture, target) do
    environment = [
      {"HOME", fixture.home},
      {"PATH", fixture.fake_bin <> ":" <> System.fetch_env!("PATH")},
      {"FAKE_UNAME_S", target.os},
      {"FAKE_UNAME_M", target.machine},
      {"FAKE_RELEASE_METADATA", fixture.metadata},
      {"FAKE_RELEASE_ARCHIVE", fixture.archive},
      {"RBE_INSTALL_DIR", fixture.install_dir},
      {"RBE_SKIP_SERVICE_INSTALL", "1"}
    ]

    System.cmd("bash", ["priv/static/install/rbe.sh"],
      env: environment,
      stderr_to_stdout: true
    )
  end

  defp write_executable!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp sha256(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end
end
