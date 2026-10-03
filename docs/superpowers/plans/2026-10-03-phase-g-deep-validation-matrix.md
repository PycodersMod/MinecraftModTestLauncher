# Phase G Deep Validation Matrix Implementation Plan

> **For agentic workers:** Implement this plan task-by-task in the existing `codex/phase-g-deep-validation` worktree. Preserve user data and never edit Mod business sources.

**Goal:** Build an auditable, evidence-driven validation framework and obtain representative Phase G build/runtime evidence without weakening trust or authentication boundaries.

**Architecture:** Add focused PowerShell modules under `src/Validation/` for target planning, safe execution, immutable run evidence, aggregation, and CLI dispatch. Keep validation evidence under Runtime Root; keep only concise reports and matrix snapshots under local `HANDOVER/`. Build actions use trusted Gradle wrappers and allowlisted tasks, with serial/low concurrency.

**Tech Stack:** PowerShell 7, Pester, JSON Schema Draft 7, GitHub Actions, Gradle Wrapper, GitHub CLI.

**Spec:** User-provided Phase G task, attachment `58c691ad-179f-4fc2-8b9e-b78460b01c73`.

## Global Constraints

- Phase F coverage remains 103 official releases × 11 loader/mode records; no real build is inferred from catalog or availability.
- Do not build all 1,133 combinations, download all client distributions, execute untrusted historical binaries, bypass authentication, or accept a new EULA.
- Do not modify user Mod business sources or delete Gradle caches / user build outputs.
- Only execute explicit validation commands and trusted/pinned official fixtures; historical unknown binaries stay blocked.
- Distinguish RESOLVED, BUILD_VERIFIED, SERVER_VERIFIED, CLIENT_LAUNCH_VERIFIED, and INTEGRATION_VERIFIED with non-transferable evidence.
- Keep PR required CI lightweight; deep validation remains manual/scheduled and uploads bounded redacted evidence only.
- Never commit local runtime evidence, secrets, Minecraft assets, personal absolute paths, or the final local HANDOVER reports.
- Preserve GitHub/GCM identity `ZYQ-2020`; do not alter other workspaces' `Kite-P` account selection.

## Review Focus

- A forged or partial process signal must not become SERVER_VERIFIED; tests require ready marker, process identity, listening port, and safe stop.
- A Gradle task start must not become CLIENT_LAUNCH_VERIFIED; tests require a real version/loader tolerant initialization marker.
- Metadata strings must never become arbitrary shell commands; tests reject untrusted fixture sources and non-allowlisted tasks.
- Interrupted/repeated runs must preserve immutable old evidence and write distinct run IDs.
- Logs and reports must redact credentials and omit personal absolute paths before persistence or upload.

---

### Task 1: Establish portfolio and platform baselines

**Files:** No product changes. Local findings go to the Phase G handover draft only after the model exists.

- [x] Confirm Phase F SHA, clean MMTL baseline, 186-test Pester baseline, required CI, ten repository worktrees, and GitHub identity.
- [x] Run ProjectDetector/Adapter v2 against each of the ten nested English project roots and record project identity, wrapper, toolchain, and Java requirements.
- [x] Run each clean Mod repository's Windows `clean build` serially only after rechecking its tracked worktree is clean; capture output and artifact hashes without editing sources.
- [x] Inspect WSL Ubuntu, Linux JDK paths, local EULA preauthorization, launcher runtime/session APIs, all CI workflow names, and macOS runner architecture availability.

### Task 2: Define validation contracts and schemas

**Files:**
- Create: `schemas/validation-matrix.schema.json`
- Create: `schemas/validation-evidence.schema.json` if the matrix and immutable run record need separate schemas.
- Create: `src/Validation/Contracts.psm1`
- Test: `tests/ValidationMatrix.Tests.ps1`, `tests/ValidationSchema.Tests.ps1`

- [ ] Define stable target/run IDs, source trust classes, validation levels, failure taxonomy, platform identity, observed Java, fixture provenance, artifact hashes, timestamps, and evidence paths.
- [ ] Validate required fields and forbid claims above the actually supplied evidence level.
- [ ] Add schema tests for valid rows, missing/null fields, unsafe trust escalation, mismatched target identity, and rejected personal paths in publishable output.

### Task 3: Implement deterministic planning and safe fixture resolution

**Files:**
- Create: `src/Validation/ValidationPlan.psm1`
- Create: `src/Validation/FixtureCatalog.psm1`
- Test: `tests/ValidationPlan.Tests.ps1`, `tests/ValidationSafety.Tests.ps1`

- [ ] Generate Tier 0 metadata-only scope and bounded Tier 1/2/3 target plans without Cartesian expansion.
- [ ] Resolve official fixture manifests only when source, pinned commit/tag, license, trust, toolchain, and allowlisted wrapper tasks are explicit.
- [ ] Reject unknown source, mutable/unpinned source, arbitrary command/task, wrong Java, path escape, and historical binary execution.
- [ ] Add dynamic CurrentStable target selection from Mojang Catalog and exact P0 anchors.

### Task 4: Implement immutable evidence and matrix aggregation

**Files:**
- Create: `src/Validation/ValidationEvidence.psm1`
- Create: `src/Validation/ValidationMatrix.psm1`
- Test: `tests/ValidationEvidence.Tests.ps1`, `tests/ValidationMatrix.Tests.ps1`

- [ ] Write each execution into a new `RuntimeRoot/validation/<targetId>/<runId>/` directory using atomic JSON writes.
- [ ] Record redacted logs, source provenance, actual toolchain/Gradle/Java/platform, duration, artifact path/size/SHA-256, process identity, markers, and classification.
- [ ] Never mutate a completed run; aggregate latest trustworthy run while retaining history.
- [ ] Add tests for redaction, hash mismatch, partial evidence, repeat run, interrupted output, and imported historical provenance.

### Task 5: Implement bounded runner, server/client markers, and CLI

**Files:**
- Create: `src/Validation/ValidationRunner.psm1`
- Create: `src/Validation/ValidationCli.psm1`
- Modify: `launcher.ps1`, `src/Architecture/Contracts.psm1`
- Test: `tests/ValidationRunner.Tests.ps1`, `tests/ValidationCli.Tests.ps1`, `tests/ValidationSafety.Tests.ps1`

- [ ] Implement explicit plan-only and execution modes, serial/low concurrency, per-target timeout, process identity tracking, safe stop, and typed failure classification.
- [ ] Build verification requires exit 0 plus expected artifact and hash; server requires ready marker + matching live process + listening port + safe stop; client requires a researched real initialization marker.
- [ ] Add `--validation-plan`, explicit `--validate-matrix`, `--validation-summary`, `--validation-version`, and `--validation-loader`; ordinary `--validate` must remain non-executing.
- [ ] Never attempt Microsoft login, fabricate sessions, auto-accept EULA, kill unrelated Java, or pass metadata through a shell.

### Task 6: Execute representative Windows evidence

**Files:** Runtime evidence outside Git; local report under `HANDOVER/`.

- [ ] Complete the ten-project Windows build audit and classify every outcome.
- [ ] Build trusted official/generated fixtures for Forge 1.12.2, Forge 1.16.5/1.20.1, Fabric 1.16.5/1.20.1/1.21.1, NeoForge 1.20.1 transition/1.21.1, Quilt 1.18.2/1.20.1/1.21.1 where official source is reliable, and one CurrentStable mainstream loader.
- [ ] Reproduce and bound the NeoForge 1.21.1 Windows/WSL behavior; at 20 minutes without output diagnose and cap total target at about 30 minutes.
- [ ] Attempt Windows client launch only for existing authorized offline development profiles, two different mainstream loaders, using researched markers and tracked process cleanup.
- [ ] Run Dedicated Server only if current preauthorization/config permits; otherwise record `SKIPPED_EULA_NOT_PREAUTHORIZED`.

### Task 7: Add real Gradle deep-validation CI and run Linux/macOS evidence

**Files:**
- Create: `.github/workflows/deep-validation.yml`
- Modify: required workflow only if needed, preserving light PR scope
- Create/Modify: `docs/superpowers/plans` fixture manifests and CI fixture definitions

- [ ] Add manual `workflow_dispatch` scope selection and low-cost scheduled representative coverage; use pinned official fixtures, Gradle cache, bounded artifact retention, and redacted result JSON/logs.
- [ ] Obtain actual Ubuntu hosted fixture builds for Fabric and Forge/NeoForge.
- [ ] Obtain macOS ARM64 builds for Fabric/Quilt class and Forge/NeoForge class, plus macOS Intel modern-loader build; classify native/toolchain-specific failures precisely.
- [ ] Run local WSL Forge, Fabric, NeoForge, and Quilt representative builds with absolute JDK paths; never modify global Java environment.
- [ ] Keep GUI claims off hosted CI and WSL.

### Task 8: Audit historical gaps and guard Phase F invariants

**Files:** `src/Catalog/Providers/*` only if authoritative evidence supports a correction; related tests and local evidence.

- [ ] Retry Legacy Fabric official metadata/source a bounded number of times and preserve provider outage if still unavailable.
- [ ] Investigate three `0.25w14craftmine.*-beta` and `47.1.82` NeoForge gaps; only exact official evidence may remap/reclassify them.
- [ ] Regenerate 1,133-record coverage audit and verify reason/provenance/state/trust invariants did not regress.
- [ ] Keep unsafe historical binary boundaries intact for LiteLoader HTTP artifacts, Rift binaries, ModLoader/ModLoaderMP binaries, and JarMod patch execution.

### Task 9: Documentation, final reports, hygiene, commits, CI, and synchronization

**Files:**
- Modify: `README.md`, `docs/architecture-v2.md`
- Create: `docs/validation.md`
- Local only: `HANDOVER/MMTL_Phase_G_Deep_Validation_Matrix_Report.md`, `HANDOVER/MMTL_Phase_G_Validation_Matrix.json`, `HANDOVER/MMTL_Phase_G_Validation_Gaps.json`

- [ ] Document validation levels, plan/query/execute commands, trust boundaries, and Phase E/F/G completion accurately.
- [ ] Generate local final matrix/gaps and portfolio/launch reports without account data or absolute personal paths.
- [ ] Run full Pester (at least 186 tests, no reductions), focused WSL suites, schema checks, `git diff --check`, secret/private-path scans, and Phase F coverage invariants.
- [ ] Commit coherent slices, push feature branch, open PR, wait for required checks, fix CI failures, merge only with green required checks, then verify local/origin/GitHub `main` equality and final CI.

## Execution Notes

- User explicitly supplied both the design scope and execution authorization; proceed without routine approval pauses.
- The feature branch is `codex/phase-g-deep-validation` in `.worktrees/phase-g-deep-validation`.
- Phase G passes only if the task's evidence floors, required CI, truthful failures, safety boundaries, and coverage no-regression gate all hold; otherwise report an evidence-backed blocker.
