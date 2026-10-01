# Minecraft Version Catalog and Runtime Java Metadata Implementation Plan

> **For agentic workers:** Implement each task with fixture-first tests and run the listed verification before proceeding.

**Goal:** Add an authoritative Mojang release catalog, integrity-checked lazy version metadata cache, Runtime Java resolver v2, and cross-platform catalog CLI without changing legacy Build Java behavior.

**Architecture:** Keep HTTP, manifest normalization, cache policy, metadata integrity, and Java provenance inside focused Catalog modules. The launcher dispatches catalog commands before project-profile resolution; existing `JavaMajor` remains the legacy Build Java alias. Fixtures cover all deterministic behavior while live Mojang checks remain explicit smoke tests.

**Tech Stack:** PowerShell 7, .NET HTTP/JSON/cryptography APIs, Pester, GitHub Actions, Mojang Version Manifest v2.

**Spec:** User-provided Phase C task and the repository's Phase A/B architecture contracts.

## Global Constraints

- Preserve canonical Minecraft IDs as strings and source ordering; do not use SemVer parsing or sorting.
- Use only `https://piston-meta.mojang.com/mc/game/version_manifest_v2.json` as the authoritative manifest.
- Only report catalog discovery as `CATALOGUED`; it does not mean loader/build/client support.
- Verify per-version JSON against manifest SHA-1 before parsing or caching as authoritative.
- Cache under `<RuntimeRoot>/metadata/mojang/`, atomically; do not commit live cache or personal machine paths.
- Keep Runtime Java separate from Build Java and retain `JavaMajor` compatibility.
- Offline mode must not make network requests; stale fallbacks must be labeled.
- PR tests must be fixture-driven and independent of Mojang availability.
- Do not implement Loader providers, download JARs, launch Minecraft, alter Mods, or retry the NeoForge stall.

## Review Focus

- Non-SemVer and year-based IDs remain exact strings — pin in manifest normalization and CurrentStable tests.
- Corrupted, mismatched, malformed, or wrong-ID metadata is rejected — pin in integrity/cache tests.
- Offline and forced refresh semantics remain distinct — pin with fake HTTP request-count assertions.
- Legacy `JavaMajor` and Build behavior do not inherit Minecraft Runtime Java — pin with detector and project model tests.
- Unknown Java metadata remains Unknown unless an audited fallback applies — pin resolver priority and arbitrary-major contract tests.

---

### Task 1: Mojang Manifest Catalog and HTTP Boundary

**Files:**
- Create: `src/Catalog/MinecraftVersionCatalog.psm1`
- Create: `schemas/minecraft-version-catalog.schema.json`
- Create: `tests/MinecraftVersionCatalog.Tests.ps1`

**Interfaces:**
- Produce manifest fetch/validation/normalization, release filtering from the manifest's `1.0` anchor through `latest.release`, canonical ID lookup, freshness states, atomic manifest cache, and injectable HTTP behavior.

- [ ] Add fixture tests for schema validation, duplicate IDs, anchor lookup, source order, release-only filtering, CurrentStable and year-based IDs.
- [ ] Add cache tests for fresh/stale/offline/corrupt/atomic-write and conditional headers.
- [ ] Implement normalized schema and HTTPS/host validation based on observed official endpoints.
- [ ] Run `Invoke-Pester tests/MinecraftVersionCatalog.Tests.ps1 -CI`.

### Task 2: Lazy Version Metadata, Integrity, and Runtime Java Resolver

**Files:**
- Create: `src/Catalog/JavaRuntimeResolver.psm1`
- Create: `src/Catalog/data/java-runtime-fallback.json`
- Modify: `src/Catalog/MinecraftVersionCatalog.psm1`
- Modify: `tests/MinecraftVersionCatalog.Tests.ps1`
- Create: `tests/JavaRuntimeResolver.Tests.ps1`

**Interfaces:**
- `Get-MmtlMinecraftVersionMetadata -CatalogEntry <entry> -RuntimeRoot <path> [-Offline]` validates SHA-1 and canonical metadata ID before returning parsed metadata.
- `Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId <string> -Catalog <catalog> [-RuntimeOverride <requirement>]` returns major/component/source/confidence/requirementKind/provenance/metadataStatus.

- [ ] Test metadata SHA-1 success/mismatch, malformed JSON, wrong ID, unsafe URL, and cache revalidation.
- [ ] Test authoritative metadata, audited fallback, explicit override, Unknown, and arbitrary Java majors.
- [ ] Add conservative, sourced fallback rules only where supported by official release notes; leave unsupported history Unknown.
- [ ] Run both focused Pester files.

### Task 3: CLI, Project Model Compatibility, Docs, and Cross-platform Fixtures

**Files:**
- Modify: `launcher.ps1`
- Modify: `src/ProjectDetector.psm1`
- Modify: `tests/CrossPlatformCli.Tests.ps1`
- Modify: `tests/JavaResolver.Tests.ps1`
- Modify: `docs/architecture-v2.md`
- Modify: `README.md`
- Modify: `.github/workflows/test.yml` only if required to include the new fixture suites.

- [ ] Add `--list-minecraft-versions`, `--minecraft-info <id>`, `--refresh-catalog`, and `--catalog-offline` before profile/project resolution.
- [ ] Add optional Runtime/Build Java requirement fields while retaining `JavaMajor` and existing build selection behavior.
- [ ] Test command parsing, offline no-network behavior, refresh failure, status display and legacy regression.
- [ ] Document catalog coverage boundaries, cache, CurrentStable, provenance, and Runtime/Build split.
- [ ] Run complete Windows Pester suite; run cross-platform fixture suites in WSL.

### Task 4: Live Smoke, Privacy Review, Commit, CI, and Handover

**Files:**
- Create a local-only Phase C evidence report; keep it out of Git.

- [ ] Fetch manifest and P0 metadata on Windows and WSL; compare CurrentStable, release count, anchor and per-version metadata results.
- [ ] Run all required platform fixture suites and available CI jobs.
- [ ] Run `git diff --check` and scan staged content for credentials, personal paths and live cache.
- [ ] Create conventional Chinese-subject commit, push `main`, and verify local/origin/GitHub HEAD plus all four required CI jobs.
- [ ] Write local HANDOVER evidence and mark Phase C PASS only when every gate is satisfied.
