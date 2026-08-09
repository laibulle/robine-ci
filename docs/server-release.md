# Build and verify a server release

Build the production assets, OTP release, license payload, compressed archive, and SHA-256 manifest with:

```bash
mix robine.server_release --output dist/server
```

The task selects `MIX_ENV=prod` automatically and refuses to overwrite an existing versioned archive. It must run on a supported Ubuntu 24.04 or 26.04 target and produces `robine-server-<version>-ubuntu-<version>-<architecture>.tar.gz` plus `SHA256SUMS`. Publish both files together and never relabel an archive for another OS version: its ERTS and native libraries are target-specific. The archive records its target in `RELEASE_PLATFORM` and the installer selects the matching pinned Ubuntu runtime container. It also includes the complete AGPL license, locked third-party inventory, production Compose/Caddy configuration, and a secret-generating installer.

`mix qa` builds this production archive from scratch and verifies its checksum, extraction, exact license payloads, executable version, and disabled Erlang Distribution configuration through `mix robine.server_release_smoke`.

Verify before extraction:

```bash
cd dist/server
sha256sum --check SHA256SUMS
tar -tzf robine-server-*.tar.gz >/dev/null
```

Extract into a new versioned directory, preserve the prior artifact for rollback, configure runtime secrets through the environment or secret files, run `bin/robine eval 'Robine.Runtime.Release.migrate()'`, and then start `bin/robine start`. Never copy secrets into the release archive.

The checksum proves integrity relative to the published manifest; it does not establish publisher identity. A future signing policy may add Sigstore or GPG without changing the archive format.
