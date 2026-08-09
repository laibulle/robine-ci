# Install and verify the Robine CLI

The MVP CLI is a versioned Elixir escript. It is platform-neutral but requires a compatible Erlang/OTP runtime on Linux, macOS, or Windows. It does not contact a Robine server or send telemetry by default.

## Build a release bundle

From a verified source checkout:

```sh
mix deps.get
mix robine.release --output dist
```

The release task automatically selects the isolated `MIX_ENV=cli`; this prevents the local escript from loading server-only database, endpoint, or bootstrap-secret requirements. The command creates `robine-<version>.escript`, three `robine-exile*` native runtime files, and `SHA256SUMS`. All five files are one inseparable bundle and must remain in the same directory. The manifest is sorted and written atomically; release automation must publish every listed file from the same build.

## Verify a downloaded release

Place every bundle file and `SHA256SUMS` in the same directory. On Linux:

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
install -d "$HOME/.local/lib/robine" "$HOME/.local/bin"
install -m 0755 robine-<version>.escript robine-exile-spawner "$HOME/.local/lib/robine/"
install -m 0644 robine-exile.app robine-exile.so "$HOME/.local/lib/robine/"
ln -sfn "$HOME/.local/lib/robine/robine-<version>.escript" "$HOME/.local/bin/robine"
ln -sfn "$HOME/.local/lib/robine/robine-exile.app" "$HOME/.local/bin/robine-exile.app"
ln -sfn "$HOME/.local/lib/robine/robine-exile.so" "$HOME/.local/bin/robine-exile.so"
ln -sfn "$HOME/.local/lib/robine/robine-exile-spawner" "$HOME/.local/bin/robine-exile-spawner"
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

For local-only secrets, add a dedicated file such as `.robine.env` to `.gitignore`, declare each required name in the workflow job, then run `robine run --env-file .robine.env`. Robine refuses files whose ignored status cannot be proven and never downloads server-side secrets.
