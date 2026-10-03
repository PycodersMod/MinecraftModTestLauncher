Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Contracts.psm1') -Force

$script:SafeFixtureTasks = @('tasks', 'clean', 'build', 'test', 'runClient', 'runServer')

function New-MmtlValidationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('P0', 'Portfolio', 'CurrentStable')][string]$Scope,
        [Parameter(Mandatory)][string]$CurrentStable,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CatalogReleaseIds,
        [object[]]$FixtureTargets = @(),
        [object[]]$ProjectTargets = @()
    )

    if ($CurrentStable -notin $CatalogReleaseIds) {
        throw 'CurrentStable 必须是所提供 Mojang 目录中的确切版本 ID。'
    }
    $selected = [Collections.Generic.List[object]]::new()
    switch ($Scope) {
        'P0' {
            foreach ($fixture in $FixtureTargets) {
                if (-not $fixture -or [string]$fixture.tier -notin @('Tier2', 'Tier3')) { continue }
                if (@($fixture.scopes) -notcontains 'P0') { continue }
                if ([string]$fixture.minecraftId -notin $CatalogReleaseIds) { continue }
                if ($fixture.currentStable -eq $true -and [string]$fixture.minecraftId -ne $CurrentStable) { continue }
                $selected.Add($fixture)
            }
        }
        'Portfolio' {
            foreach ($project in $ProjectTargets) {
                if (-not $project -or -not $project.PSObject.Properties['targetId'] -or -not $project.targetId) {
                    throw '每个 Tier 1 项目目标都必须具有稳定的 targetId。'
                }
                if ([string]$project.minecraftId -notin $CatalogReleaseIds) { continue }
                $copy = [ordered]@{}
                foreach ($property in $project.PSObject.Properties) { $copy[$property.Name] = $property.Value }
                $copy['tier'] = 'Tier1'
                $selected.Add([pscustomobject]$copy)
            }
        }
        'CurrentStable' {
            foreach ($fixture in $FixtureTargets) {
                if ([string]$fixture.minecraftId -eq $CurrentStable -and 'CurrentStable' -in @($fixture.scopes)) {
                    $selected.Add($fixture)
                }
            }
        }
    }
    $ids = @($selected | ForEach-Object { [string]$_.targetId })
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
        throw '验证计划中包含重复的目标 ID。'
    }
    [pscustomobject][ordered]@{
        schemaVersion = 1
        generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        scope = $Scope
        currentStable = $CurrentStable
        tier0 = [pscustomobject]@{ releaseCount = @($CatalogReleaseIds).Count; loaderModeCount = 11; recordCount = @($CatalogReleaseIds).Count * 11; catalogOnly = $true }
        targets = @($selected)
    }
}

function Test-MmtlValidationFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedOwners
    )
    foreach ($field in @('type', 'source', 'commit', 'license', 'trust', 'allowedTasks')) {
        if (-not $Fixture.PSObject.Properties[$field] -or $null -eq $Fixture.$field) { throw "Fixture 缺少必需字段：$field" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Fixture.license)) { throw '必须明确记录 Fixture 的许可证。' }
    foreach ($task in @($Fixture.allowedTasks)) {
        if ([string]$task -notin $script:SafeFixtureTasks) { throw "Fixture 包含未列入许可清单的 Gradle 任务：$task" }
    }
    if ([string]$Fixture.type -in @('OfficialFixture', 'GeneratedOfficialFixture')) {
        if ([string]$Fixture.commit -notmatch '^(?i:[0-9a-f]{40})$') { throw 'Fixture 来源必须固定到准确的 40 字符 commit SHA。' }
        if ([string]$Fixture.trust -ne 'TrustedOfficial') { throw '官方 Fixture 的信任级别必须为 TrustedOfficial。' }
        $uri = $null
        if (-not [Uri]::TryCreate([string]$Fixture.source, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com') {
            throw '官方 Fixture 来源必须使用 github.com 的 HTTPS URL。'
        }
        $owner = $uri.AbsolutePath.Trim('/').Split('/')[0]
        if ($owner -notin $AllowedOwners) { throw "Fixture 来源所有者不在许可清单中：$owner" }
    } elseif ([string]$Fixture.type -eq 'OfficialArtifactFixture') {
        if ([string]$Fixture.trust -ne 'TrustedOfficial') { throw '官方产物 Fixture 的信任级别必须为 TrustedOfficial。' }
        $uri = $null
        if (-not [Uri]::TryCreate([string]$Fixture.source, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -notin @('maven.minecraftforge.net', 'files.minecraftforge.net')) { throw '官方产物 Fixture 必须使用许可清单中的 Forge HTTPS 主机。' }
        if ([string]$Fixture.commit -notmatch '^(?i:[0-9a-f]{64})$') { throw '官方产物 Fixture 的 commit 必须是其确切归档 SHA-256。' }
        $checksumLength=switch([string]$Fixture.officialChecksumAlgorithm){'MD5'{32}'SHA1'{40}'SHA256'{64}default{0}}
        if(-not $checksumLength -or [string]$Fixture.officialChecksum -notmatch ("^(?i:[0-9a-f]{$checksumLength})$")){throw '官方归档 Fixture 必须包含匹配的官方校验和及算法。'}
    } elseif ([string]$Fixture.type -eq 'UserProject') {
        if ([string]$Fixture.trust -ne 'UserOwned') { throw '用户项目的信任级别必须为 UserOwned。' }
    } else {
        throw "此验证计划不支持执行该 Fixture 类型：$($Fixture.type)"
    }
    return $true
}

function New-MmtlValidationFixtureTargets {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Fixtures,[Parameter(Mandatory)]$Platform)
    foreach($fixture in $Fixtures){
        if(-not $fixture.scopes){continue}
        $sourceFixture=[ordered]@{type=[string]$fixture.type;source=[string]$fixture.source;commit=[string]$fixture.commit;license=[string]$fixture.license;trust=[string]$fixture.trust;allowedTasks=@($fixture.allowedTasks)}
        if([string]$fixture.type -eq 'OfficialArtifactFixture'){$sourceFixture.archiveSha256=[string]$fixture.commit;foreach($optionalField in @('officialChecksum','officialChecksumAlgorithm')){if($fixture.PSObject.Properties[$optionalField] -and $fixture.$optionalField){$sourceFixture[$optionalField]=$fixture.$optionalField}}}
        [pscustomobject][ordered]@{
            targetId=((([string]$fixture.fixtureId)+'-'+([string]$Platform.os).ToLowerInvariant()+'-'+([string]$Platform.arch).ToLowerInvariant()) -replace '[^a-z0-9._-]+','-')
            fixtureId=[string]$fixture.fixtureId;tier='Tier2';scopes=@($fixture.scopes);currentStable=($fixture.currentStable -eq $true)
            minecraftId=[string]$fixture.minecraftId;loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id=[string]$fixture.loaderId;version=[string]$fixture.loaderVersion};overlays=@()}
            loaderVersion=[string]$fixture.loaderVersion;toolchain=[string]$fixture.toolchain;toolchainVersion=$fixture.toolchainVersion;buildSystem='Gradle'
            platform=[pscustomobject]@{os=[string]$Platform.os;arch=[string]$Platform.arch;isWSL=[bool]$Platform.isWSL}
            java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=[int]$fixture.buildJava};observedBuildJava=$null;compilerTarget=$null;runtimeRequirement=[pscustomobject]@{kind='Minimum';major=[int]$fixture.buildJava};observedRuntimeJava=$null}
            sourceFixture=[pscustomobject]$sourceFixture
            notes=@()
        }
    }
}

Export-ModuleMember -Function New-MmtlValidationPlan, Test-MmtlValidationFixture, New-MmtlValidationFixtureTargets
