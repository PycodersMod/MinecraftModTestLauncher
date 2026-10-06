# MMTL Agent

The Agent is a separately built Forge 1.20.1 mod. It is not part of any imported Mod source tree or user Mod JAR.

## Build and stage

Use JDK 17 and the checked-in Gradle 8.5 wrapper:

```powershell
./gradlew.bat --no-daemon test stageMmtlAgent
```

`stageMmtlAgent` copies the built JAR into `providers/forge-1.20.1/` and writes an `agent-manifest.json` containing the artifact SHA-256. The JAR is a generated distribution artifact and is ignored by Git. Distribution packaging must include the staged JAR and its manifest together.

## Safety contract

- Without all MMTL Session properties, the Forge mod registers no observers and writes no events.
- The handshake validates Session ID, role allowlist, nonce hash, and an event sink inside the managed Session directory.
- Agent events contain the nonce hash, never the raw session token. They are appended to the Session event sink.
- The Agent uses offline identities only. It does not access Microsoft authentication or user credentials.
- Event sink failures are best-effort telemetry failures and never stop or crash Minecraft.
- Provider manifests bind a Loader/Minecraft compatibility range, minimum Java major, role allowlist, capabilities, and artifact SHA-256.

The Forge 1.20.1 provider can observe client/Host/Guest joins. Only an authenticated MMTL Host binding with a Session-selected port can switch the integrated server to offline authentication and publish it. A required client Mixin changes that managed listener bind to loopback and suppresses LAN multicast discovery; ordinary unbound Forge sessions retain vanilla behavior. Guest bindings can require an exact loopback endpoint. Dedicated Server role support is not advertised.
