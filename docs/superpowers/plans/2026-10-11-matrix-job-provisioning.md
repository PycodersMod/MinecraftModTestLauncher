# 全兼容矩阵 Jobs Manifest Provisioning Implementation Plan

> **For agentic workers:** execute steps with the repository standard Pester entrypoint and preserve all existing worktree changes.

**Goal:** Generate a runner-valid Jobs manifest for every frozen matrix target from an explicit, exact-target provisioning manifest, without inventing Loader versions or fixture/build instructions.

**Architecture:** A pure PowerShell module validates the frozen matrix/Universe/Ledger identities and an explicit provisioning record for each target, then derives project and cache identity fields from authoritative inputs. A CLI reads JSON manifests, invokes the module and atomically writes the existing Jobs schema. No build or game process is launched.

**Tech Stack:** PowerShell 7, JSON Schema, Pester.

**Spec:** `docs/superpowers/plans/2026-10-10-full-compatibility-matrix-orchestrator.md`, Task 9 and the existing `validation-matrix-job-manifest.schema.json`.

## Global Constraints

- Preserve the frozen Compatibility Universe and its exact target IDs.
- Every Available matrix target must have exactly one explicit provisioning record; no synthesized project path, task, Loader version, or source fixture.
- Validate exact Loader/Minecraft/Loader-version binding against the frozen Universe; validate cache identity against the Ledger.
- Reject duplicate, missing, unexpected, unavailable, malformed, or unsafe project roots before writing output.
- Generate only metadata; never launch Gradle, Minecraft, or Dedicated Server.
- Keep local paths in the private generated manifest; do not publish provisioning data or runtime files.

## Review Focus

- Missing/duplicate/unexpected targets must fail before output creation.
- Loader versions outside the frozen candidate set must be rejected.
- Project roots must exist and must not be reparse points.
- `sourceFixture.allowedTasks` must include the exact requested task.
- Generated cache identities must use exact universe/source/toolchain/targetSpec hashes.

### Task 1: Exact-target provisioning contract and generator

**Files:** create `common/schemas/validation-matrix-provisioning-manifest.schema.json`, `common/src/Validation/ValidationMatrixJobs.psm1`, `tools/New-ValidationMatrixJobs.ps1`, and `common/tests/ValidationMatrixJobs.Tests.ps1`.

**Interface:** `New-MmtlValidationMatrixJobs -MatrixManifest <object> -Universe <object> -Ledger <object> -FamilyManifest <object> -ProvisioningManifest <object> -ProvisioningRoot <string>` returns `{schemaVersion,manifestHash,jobs}` matching `validation-matrix-job-manifest.schema.json`.

- [x] Write failing tests for complete exact-target generation, hash derivation, and schema validity.
- [x] Write failing tests for missing/duplicate/unexpected targets, unpinned Loader versions, disallowed tasks, and unsafe project roots.
- [x] Implement the provisioning schema and generator using only explicit target records; derive canonical project/target/cache fields from Universe and Ledger.
- [x] Add CLI atomic output and path-relative resolution against the provisioning manifest directory.
- [x] Run the focused suite through `.github/scripts/Invoke-MmtlPester.ps1` (6 passed), then run related matrix CLI/shard/coordinator regressions (24 passed).
- [x] Confirm schema validity and `git diff --check`; no builds were run. An ordinal-order assertion caught and then verified the fix for locale-dependent `Sort-Object` output.

## Remaining Scope

This generator does not supply the 1,631 real project recipes. The Goal still requires authoritative fixture/provisioning recipes, complete matrix execution, cross-platform CI, Agent/Launch/Live evidence, security/privacy gates, and final delivery review.
