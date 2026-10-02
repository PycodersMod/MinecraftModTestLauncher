# MMTL Phase F Full Coverage Audit Implementation Plan

> **For agentic workers:** Execute this plan inline task by task. Each task uses test-first steps and ends with a verification result and a small commit.

**Goal:** Audit every formal Mojang release from 1.0 through CurrentStable across mainstream, historical, and manual loader modes, and report explained availability and validation evidence without claiming unperformed builds.

**Architecture:** Keep provider facts in existing provider modules, add a pure audit layer that normalizes those facts into per-release records and invariant gaps, and keep live reports in Runtime Root or HANDOVER. Add explicit Java requirement versus observed build evidence and expose summary, gaps, and per-version views through the existing CLI.

**Tech Stack:** PowerShell 7 modules, Pester 5+, JSON Schema Draft 7, GitHub Actions, Mojang and loader upstream metadata.

**Spec:** `.superpowers/sdd/2026-10-02-phase-f-full-coverage-audit/phase-f-user-spec.txt` (local-only exact copy of user attachment; excluded from Git)

## Global Constraints

- Formal scope is Mojang Java Edition release IDs from 1.0 through `CurrentStable`; derive count and latest ID from live manifest, never hard-code 103 or 26.3.
- Audited loaders are Forge, Fabric, NeoForge, Quilt, LegacyFabric, OrnitheLoader, LiteLoader, Rift, ModLoader, ModLoaderMP, and JarMod Manual mode; Ploceus remains toolchain/ecosystem context.
- Do not add a major loader ecosystem or perform Minecraft GUI, Dedicated Server, account, installer, binary execution, JarMod patch, CurseForge, Modrinth, or Phase G work.
- Provider network failures are isolated; Unknown records require a reason; unexplained Unknown, silent missing rows, contradictions, unsafe trust escalation, and blocker gaps must be zero for PASS.
- Keep live full coverage out of committed source; persist it only under Runtime Root or local HANDOVER. Commit engine, schemas, tests, and accurate docs.
- Do not install packages or Java. Do not modify user Mod source. Never execute historical binaries.
- Build Java requirement, observed build JVM, compiler target, and Mojang Runtime Java are independent facts.
- Required CI remains Windows, Ubuntu, macOS ARM64, and macOS Intel, without live-upstream dependencies.

## Review Focus

- One malformed or timed-out provider must not prevent records for the other ten loader modes or other releases; test isolated partial failure.
- Exact canonical version IDs only: snapshots, prereleases, and NeoForge era formats must not silently map to a different release; test representative boundaries and unmapped entries.
- A curated historical source with no record must not be reported as definitely unsupported unless that upstream index is proven exhaustive; test record-missing semantics per provider.
- `Available` with an empty candidate list, missing provenance, or missing reason/cache/lastChecked must produce an explicit invariant gap; test each contradiction.
- A BuildJava minimum, an actually executed JDK, compiler target, and runtime Java must never be conflated; test evidence with a newer observed JDK and absent runtime metadata.

---

### Task 1: Environment correction and Java evidence contract

**Files:**
- Modify: `src/Architecture/Contracts.psm1`
- Modify: relevant Java/build evidence schema(s) under `schemas/`
- Modify: `src/Catalog/JavaRuntimeResolver.psm1` only if the audit needs a read-only canonical runtime-Java projection
- Test: `tests/Architecture.Tests.ps1`, new `tests/JavaEvidence.Tests.ps1`
- Local-only: append correction to `HANDOVER/MMTL_Phase_E_Historical_Ecosystem_Report.md`

**Interfaces:**
- Preserve the existing `New-MmtlJavaRequirement` fields for compatibility; add `requirementKind` with `Minimum`, `Preferred`, `Exact`, `Unknown` semantics only where existing values can be classified from evidence.
- Define build evidence with `minecraftId`, `loaderId`, `loaderVersion`, `toolchain`, `platform`, `buildJavaRequirement`, `observedBuildJava`, `compilerTarget`, `result`, `artifactSha256`, `verifiedAt`, and fixture provenance.

- [ ] Record test asserting Gradle 9 minimum Java 17 can pair with observed JDK 25 and compiler target 8 without rewriting the requirement.
- [ ] Run the new test and confirm the current model cannot represent the distinction or loses a required field.
- [ ] Implement the smallest backward-compatible contract/schema extension and explicit WSL JDK correction in the local Phase E report.
- [ ] Run Java evidence, Architecture, Schema, and historical tests; validate all five `/opt/java/oracle/jdk-{8,16,17,21,25}` java/javac absolute paths remain unmodified and callable.
- [ ] Commit as `feat: 区分 Java 需求与实测构建证据`.

Expected verification: `Invoke-Pester -Path ./tests/JavaEvidence.Tests.ps1,./tests/Architecture.Tests.ps1,./tests/Schema.Tests.ps1,./tests/HistoricalAdapters.Tests.ps1 -CI` reports zero failures; each WSL Java binary reports its expected major and javac exits 0.

### Task 2: Provider coverage normalization and upstream boundaries

**Files:**
- Modify as evidence requires: `src/Catalog/LoaderAvailability.psm1`, `src/Catalog/HistoricalAvailability.psm1`, `src/Catalog/Providers/{Forge,Fabric,NeoForge,Quilt,HistoricalProviders}.psm1`
- Test: existing provider tests plus new `tests/CoverageProviderMapping.Tests.ps1`
- Fixtures: small synthetic global-index and candidate documents under `tests/fixtures/coverage/`

**Interfaces:**
- Keep source-specific functions unchanged where possible; add a normalized loader/release state projection containing `availability`, `reasonCode`, `source`, `sourceClass`, `cacheStatus`, `lastChecked`, `notes`, and `provenance`.
- Candidate-detail probes are bounded to missing/contradictory cases, earliest/latest, era transitions, required historical anchors, and P0 modern releases; global metadata drives the complete matrix.

- [ ] Add exact-ID mapping tests for stable versus prerelease Fabric, all current NeoForge naming eras including 1.20.1 transition and 26.x, and Quilt candidate-only semantics.
- [ ] Add red tests for “Ornithe game exists but no loader candidate”, Legacy Fabric provider outage aggregation, LiteLoader completeness semantics, Rift original/community distinction, and archive no-record semantics.
- [ ] Verify current official source formats and timestamps live; Legacy Fabric and Ornithe document a full `/v2/versions` database, so prefer one bounded full-index request when usable; pin only source repositories or formats, never a current full-version snapshot.
- [ ] Implement explicit per-provider mapping and reason codes; zero silent NeoForge upstream versions, preserve Legacy Fabric outage as a provider-level gap, and avoid promoting Ploceus to OrnitheLoader.
- [ ] Run provider mapping tests and existing provider tests; document any source that cannot establish exhaustive absence as Unknown/HISTORICAL_SOURCE_NO_RECORD.
- [ ] Commit as `fix: 明确全版本 provider 映射语义`.

Expected verification: `Invoke-Pester -Path ./tests/CoverageProviderMapping.Tests.ps1,./tests/ForgeProvider.Tests.ps1,./tests/FabricProvider.Tests.ps1,./tests/NeoForgeProvider.Tests.ps1,./tests/QuiltProvider.Tests.ps1,./tests/HistoricalProviders.Tests.ps1 -CI` reports zero failures and fixtures prove exact ID matching.

### Task 3: Coverage Audit engine, schema, metrics, and invariant gaps

**Files:**
- Create: `src/Audit/CoverageAudit.psm1`
- Create: `schemas/coverage-audit.schema.json`
- Modify: `src/Architecture/Contracts.psm1` only for centralized coverage reason/severity registries
- Test: `tests/CoverageAudit.Tests.ps1`, `tests/CoverageSchema.Tests.ps1`, `tests/CoverageGap.Tests.ps1`

**Interfaces:**
- `New-MmtlCoverageAudit -Catalog <catalog> -RuntimeRoot <path> [-Offline] [-ProviderInputs <testable inputs>]` returns the complete audit object.
- `Test-MmtlCoverageAudit -Audit <object>` returns explicit invariant gaps; `Get-MmtlCoverageVersion -Audit <object> -MinecraftId <id>` returns one release record.
- Top-level contract includes catalog provenance/hash/range/count, providers, canonical release rows, summary metrics, gaps, warnings, and provenance. Every release contains four mainstream states, six historical states, JarMod manual-mode state, runtime Java, validation evidence, coverage status, and notes.
- Gap severity is `Info`, `Warning`, `Error`, or `Blocker`; reason codes are centralized and stable.

- [ ] Write schema-valid and schema-invalid fixtures, including missing reason, illegal status, missing provenance, and a null release row.
- [ ] Add engine tests for generated records for every catalog release, all eleven modes present, provider-level failure isolation, offline partial cache, summary counts/ranges/gaps, and no fabricated JarMod candidates.
- [ ] Add invariant tests for unexplained Unknown, Available without candidates, candidate/state contradiction, missing provenance/check time, invalid trust, and build evidence without exact target.
- [ ] Run those tests against the current tree and observe the expected failures.
- [ ] Implement pure normalization and aggregation; isolate provider exceptions; persist only optional live output under Runtime Root, never in source data.
- [ ] Run coverage engine/schema/gap plus all existing provider/Java/historical tests.
- [ ] Commit as `feat: 建立全版本 coverage audit 引擎`.

Expected verification: `Invoke-Pester -Path ./tests/CoverageAudit.Tests.ps1,./tests/CoverageSchema.Tests.ps1,./tests/CoverageGap.Tests.ps1,./tests/CoverageProviderMapping.Tests.ps1,./tests/Schema.Tests.ps1 -CI` reports zero failures; generated test audit has exactly `Catalog.entries.Count` release rows and no missing loader mode.

### Task 4: Validation evidence audit and CLI/help consistency

**Files:**
- Modify: `launcher.ps1`
- Create or modify: `src/Audit/ValidationEvidence.psm1` if existing Compatibility Matrix evidence needs normalization
- Modify: `README.md`, `docs/architecture-v2.md`
- Test: `tests/CoverageCli.Tests.ps1`, `tests/ValidationEvidence.Tests.ps1`, `tests/DocumentationConsistency.Tests.ps1`

**Interfaces:**
- Add `--coverage-report` (summary by default; `--json` full report), `--coverage-gaps`, and `--coverage-version <minecraftId>` using `New-MmtlCoverageAudit`.
- Preserve current exit/JSON conventions. Extend `--loader-info` only if it can show availability reason and validation evidence without duplicating a second explanation command.
- Formal CLI options have one tested registry/source used by parser/help/docs consistency checks where feasible; ensure `--provider-status` and `--loader-offline` appear in help.

- [ ] Add tests that enumerate formal options and fail when an implemented option is absent from help or README.
- [ ] Add CLI tests for concise summary, full JSON, gap list, single-version lookup, unknown version rejection, offline cache, and partial provider failure.
- [ ] Add evidence audit tests for `CATALOGUED`, `RESOLVED`, `BUILD_VERIFIED`, `SERVER_VERIFIED`, `CLIENT_LAUNCH_VERIFIED`, and `INTEGRATION_VERIFIED`; require exact target and observed-Java facts for build claims.
- [ ] Update docs to mark A–F state accurately, keep platform/game validation boundaries, and correct Java requirement versus JDK25 observed build claims.
- [ ] Run CLI/evidence/docs tests and the full Pester suite.
- [ ] Commit as `feat: 添加 coverage CLI 与证据审计`.

Expected verification: `Invoke-Pester -Path ./tests/CoverageCli.Tests.ps1,./tests/ValidationEvidence.Tests.ps1,./tests/DocumentationConsistency.Tests.ps1,./tests/Launcher.Tests.ps1 -CI` reports zero failures; help enumeration contains each registered public option.

### Task 5: Full live audit, anchors/P0 review, report, and CI delivery

**Files:**
- Modify: `.github/workflows/test.yml` for fixture-only tests and optional manually triggered live audit only if provider-health versus invariant failures can be reported separately
- Modify: final documentation only where live findings require it
- Create locally only: `HANDOVER/MMTL_Phase_F_Full_Coverage_Audit_Report.md`
- Optionally append local-only correction: Phase E handover report; never rewrite old Phase E commits

- [ ] Run live Mojang refresh and all provider global indexes once with bounded timeouts; create the full audit under Runtime Root or local HANDOVER, not source control.
- [ ] Confirm dynamic catalog minimum, current stable, and release count; reconcile every release row with four mainstream, six historical, and JarMod manual records.
- [ ] Run candidate consistency samples at each provider's earliest/latest coverage, era boundaries, all required historical anchors, and P0 versions; expand only when gaps indicate a contradiction.
- [ ] Review all full-audit invariants; reach zero unexplained Unknown, silent missing, contradictory availability, unsafe trust escalations, and blocker gaps. Preserve explainable upstream failures as provider-level warnings.
- [ ] Verify full report counts/reason codes and ensure no live snapshot or private path enters Git diff.
- [ ] Run full Pester (at least the 147-test baseline), parser checks, `git diff --check`, privacy/secret scan, and Ubuntu/macOS fixture-only test selections.
- [ ] Commit implementation/docs in logical commits; push `main`; inspect all four required CI jobs; repair and repeat if any fail.
- [ ] Verify local HEAD = origin/main = GitHub main, clean worktree, and HANDOVER remains local-only; remove the isolated worktree/branch after completion.

Expected verification: the generated full audit reports the live manifest's actual release count/minimum/current stable; all four required Actions jobs conclude `success`; local, tracking, and API main SHAs are identical; `git status --porcelain` is empty.

## Plan Self-Review

- Spec coverage: tasks cover sections 4–5/19–24 (environment, provider mapping, Java), 6–18/25–33 (audit model, complete coverage, metrics, gaps, schema), 34–44 (CLI and docs consistency), 45–61 (cleanup, live policy, evidence, CI), and 64–68 (PASS criteria and HANDOVER). Excluded functionality is listed in Global Constraints.
- Interface consistency: engine consumes dynamic catalog plus normalized provider inputs; CLI calls the engine; invariants run on its result; live audit writes only to Runtime Root/HANDOVER.
- Review focus is tied to failing tests in Tasks 2–4.
- Execution method: inline/native implementation because shared provider mappings and one audit schema are cross-task interfaces; a single final independent review follows the fix pass.
