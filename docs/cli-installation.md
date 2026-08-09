# Install and verify the Robine CLI

The MVP CLI is a versioned Elixir escript. It is platform-neutral but requires a compatible Erlang/OTP runtime on Linux, macOS, or Windows. It does not contact a Robine server or send telemetry by default.

## Build a release bundle

From a verified source checkout:

```sh
mix deps.get
mix robine.release --output dist
```

The release task automatically selects the isolated `MIX_ENV=cli`; this prevents the local escript from loading server-only database, endpoint, or bootstrap-secret requirements. The command creates `dist/robine-<version>.escript` with executable permissions and `dist/SHA256SUMS`. The manifest is sorted by artifact filename and written atomically. Release automation must publish both files from the same build.

## Verify a downloaded release

Place the escript and `SHA256SUMS` in the same directory. On Linux:

```sh
sha256sum --check SHA256SUMS
```

On macOS:

```sh
shasum --algorithm 256 --check SHA256SUMS
```

On PowerShell:

```powershell
Get-Content SHA256SUMS | ForEach-Object {
  $expected, $name = $_ -split '\s+', 2
  $actual = (Get-FileHash $name -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected) { throw "Checksum mismatch: $name" }
}
```

Contributors with the source tree can also run:

```sh
mix robine.verify_checksums --directory dist
```

Do not install or execute the artifact when verification fails. Download both files again from the official release; if the mismatch persists, report it as a release integrity incident.

## Install

After successful verification on Linux or macOS:

```sh
chmod +x robine-<version>.escript
install -m 0755 robine-<version>.escript "$HOME/.local/bin/robine"
robine version
```

On Windows, invoke the escript through the installed Erlang runtime or place an equivalent launcher named `robine` on `PATH`. `robine version` must print the expected release version before use.

## Stable exit-code classes

| Code | Class | Meaning |
|---:|---|---|
| 0 | Success | The requested operation completed or an `init` preview was produced. |
| 2 | Configuration | Workflow validation or requested job/step selection failed. |
| 3 | Prerequisite/infrastructure | A file, Docker, runtime prerequisite, or execution infrastructure operation failed. |
| 4 | Protected mutation | `init` refused to overwrite an existing workflow without explicit force. |
| 5 | Job failure | The reproduced user command or job failed. |
| 64 | Usage | The command line or option combination is invalid. |

Commands print their result to standard output without prompts except where `init` deliberately previews a mutation. Scripts should use `init --yes`, `validate --format json`, and explicit `run` selectors.
