# Full Compatibility Matrix Orchestrator Implementation Plan

> **For agentic workers:** execute this plan task-by-task; preserve existing worktree changes and use the repository standard Pester entrypoint.

**Goal:** Add a resumable top-level runner that executes every validated matrix shard with bounded concurrency and retains each shard's existing recovery state.

**Architecture:** Reuse `New-CompatibilityMatrixChunks.ps1` output and `Invoke-CompatibilityMatrixShard.ps1` as the only worker. A coordinator starts hidden PowerShell child processes with argument arrays, stores per-shard stdout/stderr/summary files, and writes an atomic aggregate summary. Worker state remains authoritative for resume; the coordinator does not reinterpret target evidence.

**Tech Stack:** PowerShell 7, .NET `ProcessStartInfo`, Pester, existing MMTL shard runner and schemas.

**Spec:** `docs/superpowers/plans/2026-10-07-full-loader-version-compatibility.md`, Task 9.

## Global Constraints

- Preserve the frozen Universe, manifest hashes, existing RuntimeRoot and per-shard state.
- Launch non-interactive child PowerShell with `UseShellExecute=false`, `CreateNoWindow=true`, redirected streams and bounded concurrency.
- Do not terminate processes that were not started by this coordinator.
- Return nonzero when a shard fails or is incomplete; never summarize incomplete work as passed.
- Keep target-specific build/launch logic in the existing shard runner.

## Review Focus

- Invalid shard count or duplicate/missing job: reject before any child process starts.
- Child exits nonzero or emits invalid JSON: preserve logs, mark that shard failed, and continue collecting other completed shards.
- Coordinator interruption: stop only its recorded child processes; retain worker run-state files for resume.
- Concurrent shards: require unique summary/log paths and avoid overlapping shard target sets.
- Paths with spaces and non-ASCII characters: pass as discrete `ArgumentList` entries.

### Task 1: Bounded shard coordinator

**Files:** create `common/src/Validation/FullCompatibilityMatrixRunner.psm1`, `tools/Invoke-FullCompatibilityMatrix.ps1`, and focused tests in `common/tests/FullCompatibilityMatrixRunner.Tests.ps1`.

**Interfaces:** `Invoke-MmtlFullCompatibilityMatrix` accepts matrix/jobs paths, shard count, concurrency limit, RuntimeRoot, output directory and the existing worker path; returns schemaVersion, manifestHash, shard summaries, counts and overall status.

- [x] Write tests for hidden child launch, discrete argument preservation, a successful child exit, failed/incomplete aggregate states, empty shard input and aggregate schema acceptance.
- [x] Run focused tests and confirm the missing coordinator fails as expected.
- [x] Implement preflight, bounded child scheduling, atomic aggregate output, per-shard process/log identity, and redacted output without changing shard build semantics.
- [x] Run focused tests (4 passed) and matrix chunk/CLI regressions (9 + 1 passed) through `.github/scripts/Invoke-MmtlPester.ps1`.
- [x] Run PowerShell parser checks, JSON schema parsing and `git diff --check`.
- [x] Add an end-to-end coordinator test using the complete frozen 1,631-target manifest/job set and two controlled workers; verify hidden process execution, exact target preflight, one-at-a-time scheduling, summaries, log hashes and local-path redaction without running builds.
- [x] On exceptional coordinator exit, terminate/reap only its owned worker process tree and preserve drained/redacted logs; focused helper regression passes.
- [x] Exercise interruption/resume with an active worker holding target leases and a persisted Running target; coordinator interruption stops the worker, preserves logs/state, and the next run recovers the target without overlapping the live owner (also covered by the cross-process lease regression).
- [ ] Execute the full frozen matrix from a complete, validated job manifest; verify aggregate result and cross-platform CI workflow. These are still required by Task 9 and the full Goal.

### Task 2: Cross-process target leases for safe recovery

**Files:** modify `common/src/Validation/ValidationMatrixRunState.psm1` and `common/src/Validation/ValidationMatrixShardRunner.psm1`; test in `common/tests/ValidationMatrix.RunState.Tests.ps1`.

**Interfaces:** Acquire exclusive OS file leases for every exact `targetId` in ordinal order before a shard reads or resets its run-state; hold them until the shard exits. Release all acquired leases on every exception path. A concurrent worker owning any overlapping target must fail before it can classify `Running` as interrupted.

- [x] Add a cross-process regression: a second PowerShell worker cannot acquire a held target lease; after the owner exits/releases it, a new worker can acquire it.
- [x] Run the regression first and confirm it fails because leases are absent.
- [x] Implement exact-target lock files under RuntimeRoot with process identity metadata and ordered multi-target acquisition.
- [x] Wrap the shard lifecycle in lease acquisition/finally-release; verify same-manifest and changed-shard-count overlap are both rejected.
- [x] Run run-state/shard runner/coordinator suites and update the full compatibility checkpoint.
