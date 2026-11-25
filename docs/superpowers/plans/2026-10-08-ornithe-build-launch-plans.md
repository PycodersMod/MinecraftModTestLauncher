# Ornithe Build and Launch Plans Implementation Plan

> **For agentic workers:** Implement inline using test driven development.

**Goal:** Add exact-target, non-executable Gradle Build and client Launch plans for the frozen Ornithe/Ploceus family.

**Architecture:** Add a loader-specific adapter that accepts only a detected Ornithe project using Ploceus, a Gradle Wrapper, and an exact candidate pair in the frozen Universe. Extend the family refresh script with evidence references and BuildPlan/LaunchPlan capabilities; keep BuildVerified and LaunchCheck unverified.

**Tech Stack:** PowerShell 7, Pester 5, frozen JSON Compatibility Universe and family manifest.

**Spec:** Active MMTL full compatibility Goal; `compatibility/universe-preview.json`; official Ploceus, Ornithe ModMenu, and Fabric Loom sources.

## Global Constraints

- Every one of the 406 Ornithe exact Available pairs must resolve and produce both plans.
- Plans must remain non-executable and require the trusted validation runner / managed Session copy.
- Exact loader candidate and Universe hash/source provenance are mandatory.
- A BuildPlan/LaunchPlan result does not imply BuildVerified, LaunchCheck, Agent, or runtime capability.
- Do not run game builds, launch Minecraft, modify the Universe, or push/create a PR.

## Review Focus

- Wrong Loader/toolchain/Wrapper: reject.
- Target or candidate mismatch: reject without nearest-version fallback.
- Historical version breadth: generate per-target from frozen exact candidates; cite the Ploceus-to-Loom inheritance as an explicit inference.
- Unsafe plan execution: keep `isExecutablePlan=false` and trusted-runner gate.
- Capability overclaim: change only BuildPlan and LaunchPlan in the Ornithe family.

---

### Task 1: Ornithe exact-target plans and family evidence

**Files:**
- Create: `common/src/Adapters/Ornithe.psm1`
- Create: `common/tests/OrnitheAdapter.Tests.ps1`
- Modify: `tools/Refresh-OrnitheDetectionFamily.ps1`
- Modify: `common/tests/FullCompatibilityLedger.Tests.ps1`
- Modify: `compatibility/families.json` and generated `compatibility/ledger-template.json`
- Create: this plan file

**Interfaces:**
- Produces: `Resolve-MmtlOrnitheAdapterTarget -Project -Universe` and `New-MmtlOrnitheAdapterPlans -Project -Universe` returning exact target evidence, `buildPlan.task=build`, `launchPlan.task=runClient`, managed-session scope, and non-executable gates.

- [x] Write failing tests for all 406 detected target plans, candidate/identity rejection, and Ledger family statuses.
- [x] Run the new focused tests and confirm they fail because the Ornithe planner/capabilities are absent.
- [x] Implement adapter and family evidence refresh; keep BuildVerified and LaunchCheck PendingImplementation.
- [x] Run focused tests, refresh the family and Ledger, validate schema/hash, then run full Windows Pester.
- [x] Update HANDOVER with remaining PendingImplementation count and evidence; create a local checkpoint commit only.
