# Build and verify a server release

Build the production assets, OTP release, license payload, compressed archive, and SHA-256 manifest with:

```bash
mix robine.server_release --output dist/server
```

The task selects `MIX_ENV=prod` automatically and refuses to overwrite an existing versioned archive. It produces `robine-server-<version>-<architecture>.tar.gz` and `SHA256SUMS`. Publish both files together. The archive includes the complete AGPL license and locked third-party inventory.

Verify before extraction:

```bash
cd dist/server
sha256sum --check SHA256SUMS
tar -tzf robine-server-*.tar.gz >/dev/null
```

Extract into a new versioned directory, preserve the prior artifact for rollback, configure runtime secrets through the environment or secret files, run `bin/robine eval 'Robine.Runtime.Release.migrate()'`, and then start `bin/robine start`. Never copy secrets into the release archive.

The checksum proves integrity relative to the published manifest; it does not establish publisher identity. A future signing policy may add Sigstore or GPG without changing the archive format.
