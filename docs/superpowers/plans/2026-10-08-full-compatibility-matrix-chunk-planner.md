# Full Compatibility Matrix Chunk Planner Implementation Plan

> **For agentic workers:** Implement inline with test driven development. This is one independently testable task.

**Goal:** Produce deterministic, bounded exact-target chunks from the frozen Compatibility Universe and validated Ledger for later CI execution.

**Architecture:** Add a pure PowerShell module under `common/src/Validation` that validates the input Ledger against Universe and family manifest before grouping targets by family. Sort exact target IDs ordinally, split each family into bounded chunks, and include only frozen target identity/hash fields needed by runners.

**Tech Stack:** PowerShell 7, Pester 5, existing FullCompatibilityLedger validator.

**Spec:** User goal attachment, full compatibility matrix workflow requirements; current repository Compatibility Universe, family manifest, and Ledger.

## Global Constraints

- Include every exact `Available` target exactly once.
- Never infer or synthesize Minecraft/loader targets.
- Reject unknown, duplicate, missing, or unassigned targets and Universe hash mismatch.
- Bound each chunk by a caller-supplied positive chunk size.
- Do not run builds, launch Minecraft, modify Universe, or change compatibility capability statuses.
- No push or PR before global PASS/PASS_WITH_EXTERNAL_BLOCKERS.

## Review Focus

- Ledger and Universe drift: reject before producing chunks.
- Empty/unassigned family: fail closed.
- Chunk boundary and ordering: stable and duplicate-free across runs.
- Missing hashes/target identity: rely on the existing strict Ledger validator.
- Oversized or invalid chunk size: reject before allocating output.

---

### Task 1: Deterministic family-bounded chunk manifest

**Files:**
- Create: `common/src/Validation/ValidationMatrixChunks.psm1`
- Create: `common/tests/ValidationMatrix.Chunks.Tests.ps1`
- Create: this plan file

**Interfaces:**
- Consumes: `Test-MmtlFullCompatibilityLedger` from `common/src/Compatibility/FullCompatibilityLedger.psm1`.
- Produces: `New-MmtlValidationMatrixChunks -Ledger <object> -Universe <object> -FamilyManifest <object> -ChunkSize <int>` returning `schemaVersion`, `universeHash`, `manifestHash`, `targetCount`, `chunkSize`, `chunkCount`, and stable `chunks`; each chunk carries `chunkId`, `loaderId`, `familyId`, `ordinal`, `targetCount`, `chunkHash`, and exact `targets` with `targetId`, `minecraftId`, `loaderVersionCandidates`, source hashes, and `targetSpecHash`. `Test-MmtlValidationMatrixChunkManifest` re-derives the expected manifest and rejects altered or incomplete data.
- Produces: `tools/New-CompatibilityMatrixChunks.ps1 -OutputPath <path> [-ChunkSize 1..100]` to generate a JSON artifact from repository inputs.

- [x] Write tests for exact coverage, family grouping, bounded sizes, deterministic IDs/hashes, rejection of invalid size or tampered Ledger, manifest tampering, and CLI generation.
- [x] Run the new Pester file and confirm expected failures while the module/CLI are absent.
- [x] Implement the chunk planner and CLI generator.
- [x] Run the focused Pester file (7 passed) and full Windows Pester suite (553 passed, 0 failed, 2 skipped); PowerShell Parser and `git diff --check` pass.
- [x] Regenerate the manifest into ignored `.codex/` scratch and verify all exact targets once, bounded to 64 per chunk, with manifest revalidation.
- [x] Record evidence in HANDOVER and create a local checkpoint commit; do not push or open a PR.
