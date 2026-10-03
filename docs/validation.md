# Deep validation

The Mojang release catalogue and Loader availability audit describe metadata. They do not say that a project resolved, compiled, launched a dedicated server, or initialized a client. MMTL stores those claims as per-target evidence.

## Validation levels

| Level | Required evidence |
| --- | --- |
| `CATALOGUED` | Minecraft release is present in the official release catalogue. |
| `RESOLVED` | Project detector and Adapter identify the project stack and produce a safe build plan. |
| `BUILD_VERIFIED` | The Gradle wrapper exits successfully, exactly one primary Mod JAR is present, and its SHA-256 is recorded. |
| `SERVER_VERIFIED` | A real ready marker is observed while the matching process is alive, a server port listens, a supported stop is sent, and the process and port both exit. |
| `CLIENT_LAUNCH_VERIFIED` | A Minecraft initialization marker is observed from the matching client process. Starting `runClient` alone is insufficient. |
| `INTEGRATION_VERIFIED` | A named end-to-end scenario completes and its explicit assertions pass. |

Evidence is scoped to the exact fixture, Minecraft version, Loader/toolchain, Java, OS, and architecture. A build result is not copied to another platform or version. Unsupported higher-level claims are rejected by the evidence audit.

## Platform and environment provenance

MMTL product OS values are Windows, Linux, and macOS (`MacOS` in the internal enum); CPU architecture is recorded separately. Ubuntu identifies a Linux distribution, WSL/WSL2 identifies a Linux execution environment, and GitHub-hosted runners identify where evidence was produced. These provenance fields do not create additional product platforms. WSL/WSLg and hosted CI do not establish real Ubuntu Desktop or Minecraft GUI client validation.

## Run the bounded official fixture matrix

`fixtures/deep-validation/fixtures.json` pins trusted upstream repositories to immutable commits, records their license and Java requirement, and allowlists only `clean` and `build`. The workflow builds a small matrix on Windows, Ubuntu-hosted Linux, macOS ARM64, and macOS Intel. It runs on demand or twice per month; it is not a pull-request required check. Runner names describe validation environments, not product OS identities.

```text
GitHub Actions → MMTL deep validation → Run workflow
```

Choose `P0` or `CurrentStable`. The workflow uploads only short-retention build logs and schema-validated evidence with artifact/log hashes. It does not upload Minecraft distributions or Gradle caches. The checked-in CurrentStable fixture is pinned to 26.3, the latest official release resolved for this Phase G run; the local `--validation-plan` resolves CurrentStable from the live or cached Mojang catalogue.

## Matrix and local evidence

Schemas are in `schemas/validation-matrix.schema.json` and `schemas/validation-evidence.schema.json`. Runtime run records are immutable and stored below `<RuntimeRoot>/validation/<targetId>/<runId>/result.json`; log contents are redacted before hashing and storage.

To aggregate exact-target evidence, prepare a JSON array of target definitions matching the matrix schema, then run:

```powershell
./launcher.ps1 --validation-matrix ./my-validation-targets.json --validation-output ./validation-matrix.json
```

The CLI reads run records from the configured Runtime Root. It refuses evidence for target IDs outside the supplied definitions and reports invalid evidence separately. The `ValidationRunner` PowerShell module exposes the bounded `Invoke-MmtlValidationBuild` API for trusted fixtures and user projects; arbitrary shell commands and non-allowlisted Gradle tasks are not accepted.

## Dedicated server and client safety

`runServer` evidence requires a real readiness marker, process identity, port listen/release, and a safe stop. Do not create or change an EULA acceptance value to make a test pass. If the current explicit authorization/configuration precondition is absent, record `SKIPPED_EULA_NOT_PREAUTHORIZED`.

Client verification must observe an initialization marker from the actual Minecraft process. Do not treat Gradle task startup, an unauthenticated placeholder session, WSLg, or a build-only runner as client verification. If Microsoft authentication is required, record `AUTH_REQUIRED` and continue other targets.

## Fixture trust

Official fixtures must use HTTPS GitHub sources from an allowlisted Loader organization, an exact commit, explicit license, and `TrustedOfficial` provenance. User projects are accepted as `UserOwned` and remain in their existing repository. Historical binaries, HTTP-only sources, unknown-owner repositories, and arbitrary metadata-generated shell commands are rejected.
