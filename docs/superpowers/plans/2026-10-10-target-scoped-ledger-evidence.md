# Target-Scoped Ledger Evidence Implementation Plan

> Implementation is authorized by the active MMTL all Loader × all Minecraft version compatibility Goal. Preserve the existing worktree and do not commit or push during this continuation.

**Goal:** Import exact-target MMTL validation evidence into only the matching Ledger dimension.

**Architecture:** Keep family capabilities as explicit family-level claims and add a separate universe-bound evidence index for exact target claims. The importer verifies the referenced result file, target identity, target spec hash, artifact freshness, logs, and content hashes before applying supported dimensions.

**Tech Stack:** PowerShell 7, JSON Schema draft-07, Pester via `.github/scripts/Invoke-MmtlPester.ps1`.

**Spec:** `docs/superpowers/specs/2026-10-10-target-scoped-ledger-evidence.md`

## Constraints

- No evidence may expand beyond its exact target ID.
- All paths must remain within the evidence root and reject reparse points.
- Only schema-valid, successful MMTL Runner evidence may support BuildVerified.
- Preserve all pre-existing dirty changes, branches, and test outputs.

## Tasks

### Task 1: Exact-target evidence importer

**Files:** `common/src/Compatibility/FullCompatibilityLedger.psm1`, `common/tests/FullCompatibilityLedger.Tests.ps1`

- [x] Write a regression using real Forge@1.8.9 evidence; assert sibling target stays pending.
- [x] Verify the test fails because the importer interface is absent.
- [x] Add evidence-index validation and BuildVerified claim validation.
- [x] Add tamper, duplicate, stale universe/spec, target mismatch, and unsafe path rejection tests.
- [x] Run focused Ledger Pester tests through the standard repository entry: 26 passed / 0 failed / 0 skipped.

### Task 2: Schema, generator, and durable evidence

**Files:** `common/schemas/target-validation-evidence-index.schema.json`, `tools/Generate-FullCompatibilityLedger.ps1`, `compatibility/target-validation-evidence.json`, `compatibility/evidence/build/Forge-1.8.9-Windows-x64.json`, `compatibility/ledger-template.json`

- [x] Add the index schema and exact Runner result fixture.
- [x] Pass the validated index and repository root through the generator.
- [x] Regenerate the full Ledger and validate schema, target count, summary, and exact-target isolation.

### Task 3: Verification and checkpoint

- [x] Run focused tests and the Ledger generation/schema checks.
- [x] Run `git diff --check` and inspect only files changed by this task.
- [x] Record evidence digest, changed Ledger row, remaining pending dimensions, and next work in the compatibility checkpoint.
