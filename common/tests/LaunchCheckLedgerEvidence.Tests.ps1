BeforeAll {
    $script:commonRoot = Split-Path -Parent $PSScriptRoot
    $script:repoRoot = Split-Path -Parent $script:commonRoot
    $script:ledgerModule = Import-Module (Join-Path $script:commonRoot 'src/Compatibility/FullCompatibilityLedger.psm1') -Force -PassThru
}

Describe 'LaunchCheck exact-target evidence promotion' {
    It 'promotes only a schema-valid ready preflight for its exact target' {
        $universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
        $families = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
        $targetId = 'Fabric@1.20.1'
        $baseLedger = & $script:ledgerModule { param($u,$f) New-MmtlFullCompatibilityLedger -Universe $u -FamilyManifest $f -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z') } $universe $families
        $target = $universe.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1
        $ledgerTarget = $baseLedger.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1
        $loaderVersion = @($target.loaderVersionCandidates | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.version) { [string]$_.version } else { [string]$_.loaderVersion } })[0]
        $evidenceRoot = Join-Path $TestDrive 'launch-check-evidence'
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $evidencePath = Join-Path $evidenceRoot 'fabric-1.20.1-launch-check.json'
        $evidence = [pscustomobject][ordered]@{
            schemaVersion = 1
            targetId = $targetId
            minecraftId = [string]$target.minecraftId
            loaderId = [string]$target.loaderId
            loaderVersion = $loaderVersion
            targetSpecHash = [string]$ledgerTarget.targetSpecHash
            status = 'Ready'
            observedAt = '2026-10-15T00:00:00Z'
            executionPlanDigest = 'sha256:' + ('a' * 64)
            profileMode = 'Single'
            buildReady = $true
            launchReady = $true
            buildJavaStatus = 'Resolved'
            runtimeJavaStatus = 'Resolved'
            runtimeBindingMode = 'Direct'
            blockingReasonCodes = @()
            platform = [pscustomobject][ordered]@{ os = 'Windows'; arch = 'x64' }
        }
        [IO.File]::WriteAllText($evidencePath,($evidence | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $index = [pscustomobject][ordered]@{
            schemaVersion = 1
            universeHash = [string]$universe.catalogHash
            entries = @([pscustomobject][ordered]@{
                targetId = $targetId
                dimension = 'LaunchCheck'
                targetSpecHash = [string]$ledgerTarget.targetSpecHash
                evidencePath = 'fabric-1.20.1-launch-check.json'
                evidenceSha256 = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }

        $ledger = & $script:ledgerModule { param($u,$f,$i,$root) New-MmtlFullCompatibilityLedger -Universe $u -FamilyManifest $f -TargetEvidenceIndex $i -EvidenceRoot $root -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z') } $universe $families $index $evidenceRoot
        $verified = $ledger.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1

        $verified.dimensions.LaunchCheck.status | Should -BeExactly 'Supported'
        $verified.dimensions.LaunchCheck.evidenceRefs | Should -Contain "launch-check-evidence-sha256:$($index.entries[0].evidenceSha256)"
    }

    It 'rejects a ready claim whose execution plan has unresolved launch gates at schema validation' {
        $universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
        $families = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
        $targetId = 'Fabric@1.20.1'
        $baseLedger = & $script:ledgerModule { param($u,$f) New-MmtlFullCompatibilityLedger -Universe $u -FamilyManifest $f -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z') } $universe $families
        $target = $universe.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1
        $ledgerTarget = $baseLedger.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1
        $loaderVersion = @($target.loaderVersionCandidates | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.version) { [string]$_.version } else { [string]$_.loaderVersion } })[0]
        $evidenceRoot = Join-Path $TestDrive 'blocked-launch-check-evidence'
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        $evidencePath = Join-Path $evidenceRoot 'fabric-1.20.1-launch-check.json'
        $evidence = [pscustomobject][ordered]@{
            schemaVersion = 1; targetId = $targetId; minecraftId = [string]$target.minecraftId; loaderId = [string]$target.loaderId; loaderVersion = $loaderVersion
            targetSpecHash = [string]$ledgerTarget.targetSpecHash; status = 'Ready'; observedAt = '2026-10-15T00:00:00Z'; executionPlanDigest = 'sha256:' + ('a' * 64)
            profileMode = 'Single'; buildReady = $true; launchReady = $false; buildJavaStatus = 'Resolved'; runtimeJavaStatus = 'Resolved'; runtimeBindingMode = 'Direct'
            blockingReasonCodes = @('RUNTIME_LAUNCH_BLOCKED'); platform = [pscustomobject][ordered]@{ os = 'Windows'; arch = 'x64' }
        }
        [IO.File]::WriteAllText($evidencePath,($evidence | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $index = [pscustomobject][ordered]@{schemaVersion=1;universeHash=[string]$universe.catalogHash;entries=@([pscustomobject][ordered]@{targetId=$targetId;dimension='LaunchCheck';targetSpecHash=[string]$ledgerTarget.targetSpecHash;evidencePath='fabric-1.20.1-launch-check.json';evidenceSha256=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()})}

        {
            & $script:ledgerModule { param($u,$f,$i,$root) New-MmtlFullCompatibilityLedger -Universe $u -FamilyManifest $f -TargetEvidenceIndex $i -EvidenceRoot $root -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z') } $universe $families $index $evidenceRoot
        } | Should -Throw '*TARGET_EVIDENCE_RUN_SCHEMA_INVALID*'
    }
}
