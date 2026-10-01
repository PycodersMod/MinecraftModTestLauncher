# Phase D — Mainstream Loader Providers and Adapter Contract v2 Plan

## Goal and constraints

Implement official metadata discovery for Forge, Fabric, NeoForge, and Quilt; isolated caches and tri-state availability; evidence-based project resolution and LoaderStack/Toolchain/BuildJava; safe CLI discovery; representative project/build evidence; four-platform fixture CI. Preserve Phase C, never promote upstream availability into MMTL validation, do not execute installers or project Gradle during probing, do not modify Mod source, and defer Phase E.

## Baseline

- Required base: `bca5d12314f6a76ef2f92b1049f3809f6d1d4a2a` on clean `main`.
- Windows Pester baseline: 84/84 PASS.
- Final report: local-only `HANDOVER/MMTL_Phase_D_Mainstream_Loader_Providers_Report.md`.

## Tasks

1. **Provider contracts and common metadata transport** — add injectable HTTPS transport with per-provider host allowlists, redirect validation before following, safe XML parsing, atomic cache envelopes, TTL/conditional metadata and explicit Fresh/Stale/OfflineCache/Unavailable status. Add contract, malicious XML, redirect and cache isolation fixtures first.
2. **Official providers** — implement Forge promotions + Maven versions, Fabric v2 game/loader, Quilt v3 game/loader/detail, NeoForge `neoforge` and 1.20.1 transition `forge` Maven families. Preserve upstream order/fields, map exact canonical Minecraft IDs, and implement provider-specific preferred policies. Fixture tests precede each provider.
3. **Availability index** — combine Phase C release catalog and provider game/version indexes without N×4 detail requests. Isolate provider errors; keep Available/Unavailable/Unknown distinct and emit schema/cache provenance. Test partial failures and offline/stale states.
4. **Adapter v2 and project resolution** — establish common Probe/Resolve/BuildPlan/ValidateCombination output; add QuiltLoom. Probe static project evidence only, preserve conflicts as Ambiguous, select strongest evidence, distinguish NeoForge transition artifact, and resolve Toolchain/BuildSystem/BuildJava with provenance. Remove Java version inference from ProjectDetector into audited compatibility data.
5. **CLI, fixtures, and CI** — add `--list-loaders`, `--loader-info`, provider status/offline behavior, schema and cross-platform deterministic tests; keep live upstream calls out of PR jobs. Preserve all existing tests and Phase C CLI.
6. **Live and representative validation** — run the specified P0 matrix against official endpoints; resolve/build SharecodeChest Forge and CarpetPlayerAddition Fabric on Windows; validate CreateProbabilityTuning NeoForge on Windows and diagnose bounded WSL stall; use only an official Quilt fixture pinned to a commit for resolve/build, then clean it or keep it outside the repository.
7. **Docs, review, commit, CI, handover** — accurately document current evidence and boundaries, run complete Windows/WSL fixtures and privacy scans, commit Chinese Conventional subjects, push `main`, wait for Windows/Ubuntu/macOS ARM64/Intel CI, verify remote SHA, and write the local-only final report. Phase D PASS only if every task gate is satisfied; otherwise report the exact blocker.

## Verification rules

- For every fixture contract, see the test fail before implementation and pass after.
- Run targeted Pester after each subsystem and the complete Windows suite at the end; Linux/macOS deterministic suites run in CI.
- Verify no provider network request occurs in offline tests and no live endpoint is needed by PR CI.
- Before commit: PowerShell AST parse, `git diff --check`, secret/path/cache scan, and unchanged Mod tree.
- Do not claim complete until all four required CI jobs succeed and local/origin/GitHub `main` match.
