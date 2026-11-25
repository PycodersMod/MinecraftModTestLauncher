# MMTL Agent

The Agent has a loader-independent, pure-Java Core, Forge 1.20.1 and 26.3 bridges, and a property-driven Fabric bridge. The Core targets Java 8 APIs; the Forge 1.20.1 bridge targets Java 17. The exact Forge 26.3 bridge uses ForgeGradle 7.0.17, Gradle 9.7.1 and Java 25 (with JDK 8 available to ForgeGradle's remapping step). Its AgentBuild evidence is pinned to Forge `26.3-66.0.9`. Fabric AgentBuild evidence currently covers exact Minecraft targets 1.21.7, 1.21.8, 1.21.11, and 26.3 with Fabric Loader 0.19.5; the first three require Java 21 at runtime and 26.3 requires Java 25. Build evidence does not establish complete launch, injection, LAN, or Dedicated Server compatibility. Neither bridge is part of any imported Mod source tree or user Mod JAR.

## Build and stage

Use JDK 17 and the checked-in Gradle 8.5 wrapper:

```powershell
./gradlew.bat --no-daemon test stageMmtlAgent
```

The `core` Gradle subproject contains session handshake, safe event output, action authorization and LAN policy code, with no Minecraft or Loader dependencies. Its unit tests can also be run alone with `./gradlew.bat -p core test`.

`stageMmtlAgent` builds the Forge bridge against the frozen exact target `1.20.1-47.4.5`, embeds the Core classes, copies the JAR into `providers/forge-1.20.1/`, and writes an `agent-manifest.json` containing the artifact SHA-256 and exact supported Loader version. The JAR is a generated distribution artifact and is ignored by Git. Distribution packaging must include the staged JAR and its manifest together.

The reusable Fabric bridge lives in `bridges/fabric-1.21.11`. Its Minecraft, Loader, minimum-Java, and Loom profile are supplied as exact Gradle properties; each supported profile must have its own pinned dependency-verification inputs and evidence. Build it with the pinned Gradle 9.7.1 wrapper and JDK 25:

```powershell
./gradlew.bat --no-daemon test verifyMmtlAgentJar stageMmtlAgent
```

The current evidence-backed exact profiles use Fabric Loader 0.19.5 and stage into a version-specific provider directory. Each embeds the Java 8 Core. Its current capabilities are limited to a managed Session handshake and nonce-hash event telemetry. It does not claim Mixin injection, LAN hosting, world events, or Dedicated Server support.

The exact Forge 26.3 bridge lives in `bridges/forge-26.3`. Build and stage its pinned Agent provider with JDK 25 and the 9.7.1 wrapper; keep `JAVA8_HOME` available for ForgeGradle's remapping work:

```powershell
./gradlew.bat --no-daemon test verifyMmtlAgentJar stageMmtlAgent
```

It stages `providers/forge-26.3/agent-manifest.json` and the exact `26.3-66.0.9` Agent JAR. The current evidence establishes Agent compilation, packaging and provider hash validation. Real client launch, Mixin injection, LAN play and gameplay assertions still require separate exact-target runtime evidence.

## Safety contract

- Without all MMTL Session properties, the Forge mod registers no observers and writes no events.
- The handshake validates Session ID, role allowlist, nonce hash, and an event sink inside the managed Session directory.
- Agent events contain the nonce hash, never the raw session token. They are appended to the Session event sink.
- The Agent uses offline identities only. It does not access Microsoft authentication or user credentials.
- Event sink failures are best-effort telemetry failures and never stop or crash Minecraft.
- Provider manifests bind a Loader/Minecraft compatibility range, minimum Java major, role allowlist, capabilities, and artifact SHA-256.

The Forge 1.20.1 provider can observe client/Host/Guest joins. Only an authenticated MMTL Host binding with a Session-selected port can switch the integrated server to offline authentication and publish it. A required client Mixin changes that managed listener bind to loopback and suppresses LAN multicast discovery; ordinary unbound Forge sessions retain vanilla behavior. Guest bindings can require an exact loopback endpoint. Dedicated Server role support is not advertised.
