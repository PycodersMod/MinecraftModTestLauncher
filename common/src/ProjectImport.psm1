Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ProjectDetector.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AtomicFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SessionLock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RuntimeManager.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1') -Force

function Get-MmtlProjectRegistryPath {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $root = [IO.Path]::GetFullPath($RuntimeRoot)
    return Join-Path $root 'project-registry.json'
}

function Initialize-MmtlProjectRegistryRoot {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $root = [IO.Path]::GetFullPath($RuntimeRoot)
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Assert-MmtlNoReparsePath -Path $root | Out-Null
    return $root
}

function Read-MmtlProjectRegistryDocument {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ schemaVersion = 1; projects = @() }
    }
    try {
        $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
        if ([int]$document.schemaVersion -ne 1 -or $null -eq $document.projects) { throw 'invalid schema' }
        return $document
    } catch {
        throw 'PROJECT_REGISTRY_CORRUPT'
    }
}

function Invoke-MmtlProjectRegistryTransaction {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][ValidateSet('Read','Upsert','Remove')][string]$Operation,
        [psobject]$Entry,
        [string]$ProjectId
    )
    $root = Initialize-MmtlProjectRegistryRoot -RuntimeRoot $RuntimeRoot
    $path = Get-MmtlProjectRegistryPath -RuntimeRoot $root
    $lock = New-MmtlSessionLock -LockPath (Join-Path $root '.project-registry.lock') -AllowedRoot $root
    try {
        $registry = Read-MmtlProjectRegistryDocument -Path $path
        $projects = @($registry.projects)
        switch ($Operation) {
            'Read' { return $registry }
            'Upsert' {
                $platform = Get-MmtlPlatformProvider -Path $root
                $existing = $projects | Where-Object {
                    [IO.Path]::GetFullPath([string]$_.importRoot).Equals(
                        [IO.Path]::GetFullPath([string]$Entry.importRoot),
                        [StringComparison]$platform.PathComparison
                    )
                } | Select-Object -First 1
                if ($existing) {
                    $Entry.projectId = [string]$existing.projectId
                    $Entry.importedAtUtc = [string]$existing.importedAtUtc
                    $projects = @($projects | Where-Object { [string]$_.projectId -cne [string]$existing.projectId })
                } elseif (-not $Entry.projectId) {
                    $Entry.projectId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
                }
                $Entry.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                if (-not $Entry.importedAtUtc) { $Entry.importedAtUtc = [string]$Entry.updatedAtUtc }
                $projects += $Entry
                $next = [pscustomobject][ordered]@{ schemaVersion = 1; projects = @($projects) }
                Write-MmtlAtomicTextFile -Path $path -Content (($next | ConvertTo-Json -Depth 40) + "`n")
                return $Entry
            }
            'Remove' {
                $existing = @($projects | Where-Object { [string]$_.projectId -ceq $ProjectId })
                if (-not $existing.Count) { return $false }
                $nextProjects = @($projects | Where-Object { [string]$_.projectId -cne $ProjectId })
                $next = [pscustomobject][ordered]@{ schemaVersion = 1; projects = @($nextProjects) }
                Write-MmtlAtomicTextFile -Path $path -Content (($next | ConvertTo-Json -Depth 40) + "`n")
                return $true
            }
        }
    } finally {
        Remove-MmtlSessionLock -Lock $lock
    }
}

function Get-MmtlProjectRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $root = [IO.Path]::GetFullPath($RuntimeRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return [pscustomobject][ordered]@{ schemaVersion = 1; projects = @() }
    }
    Assert-MmtlNoReparsePath -Path $root | Out-Null
    $path = Get-MmtlProjectRegistryPath -RuntimeRoot $root
    return Read-MmtlProjectRegistryDocument -Path $path
}

function Remove-MmtlProjectRegistryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][guid]$ProjectId)
    return Invoke-MmtlProjectRegistryTransaction -RuntimeRoot $RuntimeRoot -Operation Remove -ProjectId $ProjectId.ToString('D')
}

function Get-MmtlProjectModMetadata {
    param([Parameter(Mandatory)]$Project)
    $resources = Join-Path ([string]$Project.ProjectRoot) 'src/main/resources'
    $modIds = [Collections.Generic.List[string]]::new()
    $modNames = [Collections.Generic.List[string]]::new()
    $entrypoints = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $resources -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $resources -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -in @('fabric.mod.json','quilt.mod.json')) {
                try {
                    $metadata = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                    if ($metadata.id -and -not $modIds.Contains([string]$metadata.id)) { $modIds.Add([string]$metadata.id) }
                    if ($metadata.name) { $modNames.Add([string]$metadata.name) }
                    foreach ($property in @('entrypoints','languageAdapters')) {
                        $section = $metadata.$property
                        if ($null -eq $section) { continue }
                        foreach ($value in @($section.PSObject.Properties | ForEach-Object { $_.Value })) {
                            foreach ($item in @($value)) {
                                if ($item -is [string] -and $item.Contains('.')) { $entrypoints.Add($item) }
                                elseif ($item.PSObject.Properties['value'] -and [string]$item.value -match '^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)+$') { $entrypoints.Add([string]$item.value) }
                            }
                        }
                    }
                } catch { }
            } elseif ($file.Name -in @('mods.toml','neoforge.mods.toml')) {
                $text = Get-Content -LiteralPath $file.FullName -Raw
                foreach ($section in [regex]::Matches($text,'(?ms)^\s*\[\[mods\]\]\s*(.*?)(?=^\s*\[\[|\z)')) {
                    $idMatch = [regex]::Match($section.Groups[1].Value,'(?m)^\s*modId\s*=\s*["'']([^"'']+)["'']')
                    if ($idMatch.Success -and -not $modIds.Contains($idMatch.Groups[1].Value)) { $modIds.Add($idMatch.Groups[1].Value) }
                    $nameMatch = [regex]::Match($section.Groups[1].Value,'(?m)^\s*displayName\s*=\s*["'']([^"'']+)["'']')
                    if ($nameMatch.Success) { $modNames.Add($nameMatch.Groups[1].Value) }
                }
            }
        }
    }
    if ($Project.ModId -and -not $modIds.Contains([string]$Project.ModId)) { $modIds.Add([string]$Project.ModId) }
    return [pscustomobject][ordered]@{
        modIds = @($modIds | Select-Object -Unique)
        modNames = @($modNames | Select-Object -Unique)
        entrypointClasses = @($entrypoints | Select-Object -Unique)
        primaryModId = if ($modIds.Count -eq 1) { [string]$modIds[0] } else { $null }
        primaryModStatus = if ($modIds.Count -gt 1) { 'AMBIGUOUS_PRIMARY_MOD' } elseif ($modIds.Count -eq 1) { 'Resolved' } else { 'Unknown' }
    }
}

function Import-MmtlProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$RuntimeRoot)
    $importRoot = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $importRoot -PathType Container)) { throw 'PROJECT_ROOT_INVALID' }
    $discovered = @(Find-MmtlGradleProjects -Path $importRoot)
    if (-not $discovered.Count) { throw '没有发现 Gradle 项目。' }
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($project in $discovered) {
        $metadata = Get-MmtlProjectModMetadata -Project $project
        $targets.Add([pscustomobject][ordered]@{
            projectRoot = [IO.Path]::GetFullPath([string]$project.ProjectRoot)
            repositoryRoot = [IO.Path]::GetFullPath([string]$project.RepositoryRoot)
            loaderId = [string]$project.Loader
            loaderVersion = $project.LoaderVersion
            minecraftVersion = $project.MinecraftVersion
            toolchain = [string]$project.Toolchain.id
            buildJavaRequirement = $project.BuildJavaRequirement
            detectionStatus = [string]$project.DetectionStatus
            modIds = @($metadata.modIds)
            modNames = @($metadata.modNames)
            entrypointClasses = @($metadata.entrypointClasses)
            primaryModId = $metadata.primaryModId
            primaryModStatus = $metadata.primaryModStatus
        })
    }
    $entry = [pscustomobject][ordered]@{
        projectId = $null
        importRoot = [IO.Path]::GetFullPath($importRoot)
        importedAtUtc = $null
        updatedAtUtc = $null
        targetCount = $targets.Count
        targets = @($targets)
    }
    $stored = Invoke-MmtlProjectRegistryTransaction -RuntimeRoot $RuntimeRoot -Operation Upsert -Entry $entry
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        status = 'Imported'
        projectId = [string]$stored.projectId
        importedAtUtc = [string]$stored.importedAtUtc
        updatedAtUtc = [string]$stored.updatedAtUtc
        targetCount = [int]$stored.targetCount
        targets = @($stored.targets)
    }
}

Export-ModuleMember -Function Get-MmtlProjectRegistry,Remove-MmtlProjectRegistryEntry,Import-MmtlProject
