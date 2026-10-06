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

function Repair-MmtlProjectRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[switch]$ConfirmBackup)
    if(-not $ConfirmBackup.IsPresent){throw 'PROJECT_REGISTRY_RECOVERY_CONFIRMATION_REQUIRED'}
    $root=Initialize-MmtlProjectRegistryRoot -RuntimeRoot $RuntimeRoot
    Assert-MmtlNoReparsePath -Path $root|Out-Null
    $path=Get-MmtlProjectRegistryPath -RuntimeRoot $root
    if(-not(Test-Path -LiteralPath $path)){throw 'PROJECT_REGISTRY_NOT_FOUND'}
    Assert-MmtlNoReparsePath -Path $path|Out-Null
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'PROJECT_REGISTRY_PATH_INVALID'}
    $lock=New-MmtlSessionLock -LockPath (Join-Path $root '.project-registry.lock') -AllowedRoot $root
    try{
        try{$null=Read-MmtlProjectRegistryDocument -Path $path;throw 'PROJECT_REGISTRY_NOT_CORRUPT'}
        catch{if([string]$_.Exception.Message -cne 'PROJECT_REGISTRY_CORRUPT'){throw}}
        $stamp=[DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ',[Globalization.CultureInfo]::InvariantCulture)
        $backup=Join-Path $root ("project-registry.corrupt-$stamp-"+[guid]::NewGuid().ToString('N')+'.json')
        Assert-MmtlNoReparsePath -Path $backup|Out-Null
        [IO.File]::Move($path,$backup)
        try{
            Write-MmtlAtomicTextFile -Path $path -Content "{`"schemaVersion`":1,`"projects`":[]}`n"
            $recovered=Read-MmtlProjectRegistryDocument -Path $path
            if(@($recovered.projects).Count -ne 0){throw 'PROJECT_REGISTRY_RECOVERY_VERIFY_FAILED'}
            return [pscustomobject][ordered]@{status='Recovered';registryPath=$path;backupPath=$backup;projectCount=0}
        }catch{
            if(Test-Path -LiteralPath $path -PathType Leaf){[IO.File]::Delete($path)}
            if((Test-Path -LiteralPath $backup -PathType Leaf) -and -not(Test-Path -LiteralPath $path)){[IO.File]::Move($backup,$path)}
            throw
        }
    }finally{Remove-MmtlSessionLock -Lock $lock}
}

function Remove-MmtlProjectRegistryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][guid]$ProjectId)
    return Invoke-MmtlProjectRegistryTransaction -RuntimeRoot $RuntimeRoot -Operation Remove -ProjectId $ProjectId.ToString('D')
}

function Get-MmtlProjectModMetadata {
    param([Parameter(Mandatory)]$Project,[string]$PrimaryModId)
    $resources = Join-Path ([string]$Project.ProjectRoot) 'src/main/resources'
    $modIds = [Collections.Generic.List[string]]::new()
    $modNames = [Collections.Generic.List[string]]::new()
    $entrypoints = [Collections.Generic.List[string]]::new()
    $mixinConfigs = [Collections.Generic.List[string]]::new()
    $metadataErrors = [Collections.Generic.List[string]]::new()
    $packageCandidates = [Collections.Generic.List[object]]::new()
    $seenPackages = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $addPackage = {
        param([string]$ClassName,[string]$Source,[string]$EvidencePath,[string]$Confidence)
        if ($ClassName -notmatch '^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)+$') { return }
        $packageName = $ClassName.Substring(0,$ClassName.LastIndexOf('.'))
        $key = "$Source`n$packageName"
        if ($seenPackages.Add($key)) { $packageCandidates.Add([pscustomobject][ordered]@{packageName=$packageName;source=$Source;evidencePath=$EvidencePath;confidence=$Confidence}) }
    }
    if (Test-Path -LiteralPath $resources -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $resources -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -in @('fabric.mod.json','quilt.mod.json')) {
                try {
                    $metadata = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                    $metadataId = $null
                    if ($metadata.PSObject.Properties['id'] -and $metadata.id) { $metadataId = [string]$metadata.id }
                    elseif ($metadata.PSObject.Properties['quilt_loader'] -and $metadata.quilt_loader.PSObject.Properties['id']) { $metadataId = [string]$metadata.quilt_loader.id }
                    if ($metadataId -and -not $modIds.Contains($metadataId)) { $modIds.Add($metadataId) }
                    if ($metadata.PSObject.Properties['name'] -and $metadata.name) { $modNames.Add([string]$metadata.name) }
                    elseif ($metadata.PSObject.Properties['quilt_loader'] -and $metadata.quilt_loader.metadata -and $metadata.quilt_loader.metadata.name) { $modNames.Add([string]$metadata.quilt_loader.metadata.name) }
                    foreach ($property in @('entrypoints','languageAdapters')) {
                        $section = if ($metadata.PSObject.Properties[$property]) { $metadata.$property } else { $null }
                        if ($null -eq $section -and $metadata.PSObject.Properties['quilt_loader'] -and $metadata.quilt_loader.PSObject.Properties[$property]) { $section = $metadata.quilt_loader.$property }
                        if ($null -eq $section) { continue }
                        foreach ($value in @($section.PSObject.Properties | ForEach-Object { $_.Value })) {
                            foreach ($item in @($value)) {
                                if ($item -is [string] -and $item.Contains('.')) { $entrypoints.Add($item); & $addPackage $item 'Entrypoint' $file.FullName 'High' }
                                elseif ($item -is [psobject] -and $item.PSObject.Properties['value'] -and [string]$item.value -match '^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)+$') { $entrypoints.Add([string]$item.value); & $addPackage ([string]$item.value) 'Entrypoint' $file.FullName 'High' }
                            }
                        }
                    }
                    if ($metadata.PSObject.Properties['mixins']) { foreach ($mixin in @($metadata.mixins)) { if ($mixin -is [string]) { $mixinConfigs.Add($mixin) } elseif ($mixin.config) { $mixinConfigs.Add([string]$mixin.config) } } }
                    if ($metadata.PSObject.Properties['quilt_loader'] -and $metadata.quilt_loader.PSObject.Properties['mixins']) { foreach ($mixin in @($metadata.quilt_loader.mixins)) { if ($mixin -is [string]) { $mixinConfigs.Add($mixin) } elseif ($mixin.config) { $mixinConfigs.Add([string]$mixin.config) } } }
                } catch { $metadataErrors.Add("$($file.Name):INVALID_JSON") }
            } elseif ($file.Name -in @('mods.toml','neoforge.mods.toml')) {
                $text = Get-Content -LiteralPath $file.FullName -Raw
                $sections = [regex]::Matches($text,'(?ms)^\s*\[\[mods\]\]\s*(.*?)(?=^\s*\[\[|\z)')
                if (-not $sections.Count) { $metadataErrors.Add("$($file.Name):INVALID_TOML") }
                foreach ($section in $sections) {
                    $idMatch = [regex]::Match($section.Groups[1].Value,'(?m)^\s*modId\s*=\s*["'']([^"'']+)["'']')
                    if ($idMatch.Success -and -not $modIds.Contains($idMatch.Groups[1].Value)) { $modIds.Add($idMatch.Groups[1].Value) }
                    elseif (-not $idMatch.Success) { $metadataErrors.Add("$($file.Name):MOD_ID_MISSING") }
                    $nameMatch = [regex]::Match($section.Groups[1].Value,'(?m)^\s*displayName\s*=\s*["'']([^"'']+)["'']')
                    if ($nameMatch.Success) { $modNames.Add($nameMatch.Groups[1].Value) }
                }
            }
        }
    }
    $sourceRoot = Join-Path ([string]$Project.ProjectRoot) 'src/main'
    if (Test-Path -LiteralPath $sourceRoot -PathType Container) {
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Include '*.java','*.kt' -ErrorAction SilentlyContinue)) {
            $sourceText = Get-Content -LiteralPath $sourceFile.FullName -Raw -ErrorAction SilentlyContinue
            $packageMatch = [regex]::Match($sourceText,'(?m)^\s*package\s+([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+)\s*;?')
            if ($packageMatch.Success) { & $addPackage ($packageMatch.Groups[1].Value + '.PackageMarker') 'SourceScan' $sourceFile.FullName 'Medium' }
        }
    }
    foreach ($mixinConfig in @($mixinConfigs | Select-Object -Unique)) {
        $mixinPath = Join-Path $resources ($mixinConfig -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $mixinPath -PathType Leaf)) { continue }
        try {
            $mixin = Get-Content -LiteralPath $mixinPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($mixin.package) { & $addPackage ([string]$mixin.package + '.MixinMarker') 'Mixin' $mixinPath 'High' }
        } catch { $metadataErrors.Add("$mixinConfig`:INVALID_MIXIN_JSON") }
    }
    $artifactRoot = Join-Path ([string]$Project.ProjectRoot) 'build/libs'
    $artifactNames = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $artifactRoot -PathType Container) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($artifact in @(Get-ChildItem -LiteralPath $artifactRoot -Filter '*.jar' -File -ErrorAction SilentlyContinue)) {
            if($artifact.BaseName -notmatch '(?i)-(sources|javadoc)$' -and -not $artifactNames.Contains($artifact.Name)){$artifactNames.Add($artifact.Name)}
            try {
                $archive = [IO.Compression.ZipFile]::OpenRead($artifact.FullName)
                try {
                    foreach ($entry in $archive.Entries) {
                        if ($entry.FullName -match '^(?<package>(?:[A-Za-z_$][\w$]*/)+)[^/]+\.class$' -and $entry.FullName -notmatch '^META-INF/') {
                            & $addPackage ($Matches.package.TrimEnd('/').Replace('/','.')) 'Artifact' $artifact.Name 'Low'
                        }
                    }
                } finally { $archive.Dispose() }
            } catch { $metadataErrors.Add("$($artifact.Name):INVALID_ARTIFACT") }
        }
    }
    if ($Project.ModId -and -not $modIds.Contains([string]$Project.ModId)) { $modIds.Add([string]$Project.ModId) }
    $primaryStatus = if ($modIds.Count -gt 1) { 'AMBIGUOUS_PRIMARY_MOD' } elseif ($modIds.Count -eq 1) { 'Resolved' } else { 'Unknown' }
    $primary = if ($PrimaryModId) { $PrimaryModId } elseif ($modIds.Count -eq 1) { [string]$modIds[0] } else { $null }
    if ($PrimaryModId -and -not $modIds.Contains($PrimaryModId)) { throw 'PRIMARY_MOD_ID_NOT_FOUND' }
    if ($PrimaryModId) { $primaryStatus = 'ResolvedByProfile' }
    return [pscustomobject][ordered]@{
        modIds = @($modIds | Select-Object -Unique)
        modNames = @($modNames | Select-Object -Unique)
        entrypointClasses = @($entrypoints | Select-Object -Unique)
        mixinConfigs = @($mixinConfigs | Select-Object -Unique)
        artifactNames = @($artifactNames | Select-Object -Unique)
        packageCandidates = @($packageCandidates | Sort-Object @{Expression={switch($_.source){'Entrypoint'{0}'SourceScan'{1}'Mixin'{2}'Artifact'{3}default{4}}}},packageName -Unique)
        metadataErrors = @($metadataErrors | Select-Object -Unique)
        primaryModId = $primary
        primaryModStatus = $primaryStatus
    }
}

function Import-MmtlProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$RuntimeRoot,[string]$PrimaryModId)
    $importRoot = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $importRoot -PathType Container)) { throw 'PROJECT_ROOT_INVALID' }
    $discovered = @(Find-MmtlGradleProjects -Path $importRoot)
    if (-not $discovered.Count) { throw '没有发现 Gradle 项目。' }
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($project in $discovered) {
        $metadata = Get-MmtlProjectModMetadata -Project $project
        if ($PrimaryModId -and $metadata.modIds -contains $PrimaryModId) {
            $metadata.primaryModId = $PrimaryModId
            $metadata.primaryModStatus = 'ResolvedByProfile'
        }
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
            mixinConfigs = @($metadata.mixinConfigs)
            artifactNames = @($metadata.artifactNames)
            packageCandidates = @($metadata.packageCandidates)
            metadataErrors = @($metadata.metadataErrors)
            primaryModId = $metadata.primaryModId
            primaryModStatus = $metadata.primaryModStatus
        })
    }
    if ($PrimaryModId -and -not @($targets | Where-Object { $_.modIds -contains $PrimaryModId }).Count) { throw 'PRIMARY_MOD_ID_NOT_FOUND' }
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

Export-ModuleMember -Function Get-MmtlProjectRegistry,Remove-MmtlProjectRegistryEntry,Repair-MmtlProjectRegistry,Import-MmtlProject,Get-MmtlProjectModMetadata
