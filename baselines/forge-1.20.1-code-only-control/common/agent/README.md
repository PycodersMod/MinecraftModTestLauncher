# Forge 1.20.1 MMTL Agent

This folder contains the MMTL-owned Forge Agent source, Gradle build, Gradle Wrapper and the staged runtime artifact used by this baseline.

## Build and verify

From the baseline root, run:

```powershell
./common/agent/gradlew.bat -p ./common/agent stageMmtlAgent
```

The `verifyMmtlAgentJar` task checks the reobfuscated artifact, required manifest entries, Mixin config and refmap. `stageMmtlAgent` copies the verified JAR to `providers/forge-1.20.1/` and writes a manifest containing its SHA-256. The runtime provider loader checks that digest before launch. Archive order and timestamps are normalized so repeated builds produce the same JAR hash.

Requirements: an available JDK 17 and network access to the Forge, SpongePowered and Maven Central repositories on first build. Generated `.gradle/`, `build/`, `run/` and `run-server/` data is local and ignored.

The staged JAR is built from the adjacent source tree and is MMTL-owned. It does not include Minecraft, Forge, Mixin or other third-party libraries; Forge supplies those at runtime.
