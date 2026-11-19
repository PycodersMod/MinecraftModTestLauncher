# MMTL Workspace Recovery Checkpoint — 2026-11-19

This document accompanies the `codex/workspace-recovery-20261119` branch. It records the public, cloneable source checkpoint; local test worlds, raw Session logs, third-party dependency JARs, and machine-specific reports are intentionally excluded.

## Current state

- The Forge 1.20.1 / Forge 47.4.23 Windows controller, Agent, configuration profiles, and regression tests are included in this branch.
- Example profiles use `%JAVA_HOME%`, `%APPDATA%`, and `%LOCALAPPDATA%` so they do not contain paths tied to one developer machine.
- The controller's default runtime directory is under the current user's Local AppData.
- The historical Forge 1.20.1 acceptance record is available in the repository's baseline documentation. Its previous failures remain historical evidence; the latest successful rounds do not establish that intermittent failures are impossible.
- The all-loader compatibility work remains **PARTIAL**. The 1,631-target universe and compatibility infrastructure are not proof that all targets have passed real builds or runtime tests.
- MMTL all-version work, XLoader, and XTranslator remain paused unless a later user instruction resumes them.

## Resume

Clone `PycodersMod/MinecraftModTestLauncher` and check out `codex/workspace-recovery-20261119` to restore this exact source checkpoint. To continue from the latest maintained baseline instead, start from `main` and selectively bring over this branch's commits after reviewing their changes.

The repository branch is a recovery point, not a claim that the current changes were fully re-tested during the disk cleanup. Test results must be checked against the current checkout before release.
