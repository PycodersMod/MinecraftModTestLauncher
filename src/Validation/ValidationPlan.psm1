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
        throw 'CurrentStable must be an exact release ID in the supplied Mojang catalog.'
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
                    throw 'Every Tier 1 project target requires a stable targetId.'
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
        throw 'Validation plan contains duplicate target IDs.'
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
        if (-not $Fixture.PSObject.Properties[$field] -or $null -eq $Fixture.$field) { throw "Fixture is missing required field: $field" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Fixture.license)) { throw 'Fixture license must be explicitly recorded.' }
    foreach ($task in @($Fixture.allowedTasks)) {
        if ([string]$task -notin $script:SafeFixtureTasks) { throw "Fixture contains unallowlisted Gradle task: $task" }
    }
    if ([string]$Fixture.type -in @('OfficialFixture', 'GeneratedOfficialFixture')) {
        if ([string]$Fixture.commit -notmatch '^(?i:[0-9a-f]{40})$') { throw 'Fixture source must be pinned to an exact 40-character commit SHA.' }
        if ([string]$Fixture.trust -ne 'TrustedOfficial') { throw 'Official fixture trust must be TrustedOfficial.' }
        $uri = $null
        if (-not [Uri]::TryCreate([string]$Fixture.source, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com') {
            throw 'Official fixture source must use an HTTPS github.com URL.'
        }
        $owner = $uri.AbsolutePath.Trim('/').Split('/')[0]
        if ($owner -notin $AllowedOwners) { throw "Fixture source owner is not allowlisted: $owner" }
    } elseif ([string]$Fixture.type -eq 'OfficialArtifactFixture') {
        if ([string]$Fixture.trust -ne 'TrustedOfficial') { throw 'Official artifact fixture trust must be TrustedOfficial.' }
        $uri = $null
        if (-not [Uri]::TryCreate([string]$Fixture.source, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -notin @('maven.minecraftforge.net', 'files.minecraftforge.net')) { throw 'Official artifact fixture must use an allowlisted HTTPS Forge host.' }
        if ([string]$Fixture.commit -notmatch '^(?i:[0-9a-f]{64})$') { throw 'Official artifact fixture commit must be its exact archive SHA-256.' }
        $checksumLength=switch([string]$Fixture.officialChecksumAlgorithm){'MD5'{32}'SHA1'{40}'SHA256'{64}default{0}}
        if(-not $checksumLength -or [string]$Fixture.officialChecksum -notmatch ("^(?i:[0-9a-f]{$checksumLength})$")){throw 'Official archive fixture must include the matching official checksum and algorithm.'}
    } elseif ([string]$Fixture.type -eq 'UserProject') {
        if ([string]$Fixture.trust -ne 'UserOwned') { throw 'User project trust must be UserOwned.' }
    } else {
        throw "Fixture type is not executable in this validation plan: $($Fixture.type)"
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
