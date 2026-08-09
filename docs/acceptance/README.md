# MVP external acceptance

Two MVP claims require evidence from outside the automated test suite: a fresh operator reaching a green GitHub check within ten measured minutes, and an unfamiliar developer completing the core journeys with a screen reader. These protocols make those sessions repeatable without pretending that a generated local fixture is external proof.

Use copies of the JSON templates in this directory. Keep completed evidence out of the public repository when it contains tester-identifying notes or private repository names; store it with restricted release records instead. A release reviewer verifies both files with:

```bash
mix robine.verify_acceptance \
  --first-pipeline /secure/release-evidence/first-pipeline.json \
  --accessibility /secure/release-evidence/accessibility.json \
  --artifact-manifest /secure/release-evidence/SHA256SUMS
```

The command validates schema, supported host, timestamps, permitted exclusions, GitHub check URL shape, complete accessibility journeys, tester independence, issue disposition, the SHA-256 binding to the retained manifest, and that the manifest contains exactly one target-specific Robine 0.1.0 server archive. It intentionally does not make network requests or prove that a human attestation is truthful. The reviewer must open the recorded GitHub check and confirm the named session occurred before checking the corresponding specification criteria.

- [Fresh-host first-pipeline protocol](first-pipeline.md)
- [Manual accessibility protocol](accessibility.md)
