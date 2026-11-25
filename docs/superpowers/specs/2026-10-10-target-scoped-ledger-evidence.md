# Exact-target Compatibility Ledger Evidence

## Design

`families.json` remains the source of capabilities shared by explicitly listed exact targets. A separate target evidence index supplies narrowly scoped execution evidence where one target has stronger proof than its family. The index is bound to the frozen Compatibility Universe hash; each entry names one exact `targetId`, one supported dimension, a repository-relative evidence file, and its SHA-256.

The first importer supports only `BuildVerified`. It accepts evidence only when the referenced MMTL validation result is schema-valid, `PASSED`, `BUILD_VERIFIED`, `failureCode=NONE`, exact `targetId` / Minecraft / Loader / Loader version match the Universe, source remained unchanged, artifact is fresh with a SHA-256, and output log hashes are present. Forge claims additionally require `forgeSecurity.pinId` to equal the exact target. It rejects duplicate claims, stale Universe or target spec identity, path traversal/reparse paths, and hash mismatch. No family-wide capability is inferred from a target override.

The generated Ledger retains the evidence file digest and index digest as evidence references. Other dimensions and sibling targets continue to derive from existing family capability rules.

## Acceptance checks

- Forge@1.8.9 receives BuildVerified=Supported from its cold-cache Runner evidence.
- Forge@1.8.8 and Forge@1.9 remain unchanged and PendingImplementation for BuildVerified.
- Tampered evidence, mismatched target identity, duplicate claims, stale Universe, and unsafe paths are rejected.
- The generated 1,631-target Ledger remains schema-valid and summary-consistent.