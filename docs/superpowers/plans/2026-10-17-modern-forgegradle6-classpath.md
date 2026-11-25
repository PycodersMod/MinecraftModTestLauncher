# Modern ForgeGradle 6 Build Classpath Plan

> **For agentic workers:** Execute this plan task by task. Keep the full 1,631-target Goal unchanged. Do not start a new Gradle Build while the preserved Gradle worker is alive.

**Goal:** Represent the five verified modern ForgeGradle 6 MDK build classpath inputs without weakening the existing Forge@1.16.5 catalog contract.

**Architecture:** Extend the existing ForgeGradle 6 classpath schema and resolver with a versioned modern-target profile. Bind each exact target to official MDK SHA-256, Gradle Wrapper URL/checksum, Java 17, ForgeGradle 6.0.54, and its Foojay marker version. Reuse only hash-pinned common ForgeGradle artifacts; create target catalogs from the exact captured source facts. Do not call a source-derived catalog BuildVerified until the exact Wrapper Build succeeds.

**Tech Stack:** PowerShell, JSON Schema 2020-12, Pester via `.github/scripts/Invoke-MmtlPester.ps1`.

**Spec:** Approved MMTL v0.3 / Plan 02; current Goal continuation checkpoint and D-drive Foojay closure report.

## Global Constraints

- Preserve schema v1 Forge@1.16.5 behavior and exact pins.
- Modern targets are Forge@1.18.2, 1.19.2, 1.19.4, 1.20, and 1.20.1; Java major is 17.
- ForgeGradle selector is `[6.0,6.2)` and selected version is 6.0.54.
- Forge@1.20 uses Gradle 8.1.1 / Foojay 0.5.0; the other four use Gradle 8.8 / Foojay 0.7.0.
- Preserve POM/JAR URL, size and SHA-256 checks. Do not treat catalog or Pester success as Build/Game compatibility evidence.
- Do not stop or restart PID 4240/38276/37728/47200; do not commit, push, clean caches, or change branches.

## Review Focus

- v1 catalog remains byte-for-byte contract-compatible and rejects altered identity.
- v2 rejects a valid hash with mismatched target, Forge, Wrapper, or Foojay mapping.
- Foojay marker, direct dependency, POM, JAR and target source pins agree.
- Wrapper SHA-256 binds the exact distribution version and URL.
- A future actual Gradle resolution may show additional/different artifacts; no source-derived candidate may be labeled BuildVerified.

---

### Task 1: Add failing modern profile tests

**Files:** `common/tests/ForgeBuildClasspathArtifactCatalog.Tests.ps1`

- [x] Construct a schema v2 synthetic catalog for each of the five targets from the hash-pinned v1 shared closure, substituting the separately captured Foojay 0.5.0 pins for Forge@1.20.
- [x] Assert resolver and schema accept the exact MDK, Wrapper, Gradle, Foojay, and Forge identity mapping.
- [x] Assert a wrong Wrapper checksum or Foojay/target pairing is rejected.
- [x] Ran the targeted suite through `.github/scripts/Invoke-MmtlPester.ps1` (RED observed before implementation).

### Task 2: Implement v2 schema and resolver

**Files:** `common/schemas/forge-gradle6-build-classpath.schema.json`, `common/src/Adapters/ForgeSecureBuild.psm1`

- [x] Keep the v1 generic target contract and exact dependency/artifact closure intact.
- [x] Add exact v2 modern-target identity mapping, MDK SHA-256, Wrapper URL/checksum, Java, ForgeGradle, and Foojay constraints.
- [x] Include all v2 provenance fields in catalogHash computation and reject identity mismatch before mirror writes.
- [x] Re-ran targeted tests through the repository harness.

### Task 3: Generate source-pinned candidate catalogs

**Files:** `compatibility/forge-gradle6-build-classpath-artifacts/Forge-<version>.json`

- [x] Derived from the existing 6.0.54 closure only where artifact coordinates and hashes match.
- [x] Replaced Foojay 0.5.0 metadata for Forge@1.20 with captured exact bytes/hashes/URLs.
- [x] Validated all five catalogs with schema and resolver.
- [x] Recorded the closure as a candidate; exact Wrapper Build verification remains pending.

### Task 4: Regression and checkpoint

- [x] Ran all four relevant ForgeGradle 6 Pester files through the standard harness (98 passed).
- [x] Recorded TDD, provenance, candidate hashes, Worker state, and remaining Build evidence in the D-drive report/checkpoint.
- [ ] Preserve Goal status Active and the full 1,631-target acceptance scope.
