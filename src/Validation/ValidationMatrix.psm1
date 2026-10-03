Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Contracts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationEvidence.psm1') -Force

function ConvertTo-MmtlCanonicalBuildSystemId {
    [CmdletBinding()]
    param([AllowNull()][string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
    if ($Id.ToLowerInvariant() -in @('gradle', 'gradlewrapper')) { return 'Gradle' }
    return $Id
}

function ConvertTo-MmtlJavaRequirement {
    [CmdletBinding()]
    param([AllowNull()]$Requirement)
    if ($null -eq $Requirement -or -not $Requirement.PSObject.Properties['kind']) {
        return [pscustomobject]@{ kind = 'Unknown'; major = $null }
    }
    return $Requirement
}

function New-MmtlValidationMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Targets,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,
        [ValidateSet('P0','Portfolio','CurrentStable')][string]$Scope='P0',
        [string]$OutputPath
    )
    $ids=@($Targets|ForEach-Object {[string]$_.targetId})
    if(@($ids|Select-Object -Unique).Count -ne $ids.Count){throw 'Validation target definitions must have unique targetId values.'}
    $allIds=@($Evidence|ForEach-Object {[string]$_.targetId})
    if(@($allIds|Where-Object {$_ -notin $ids}).Count){throw 'Evidence references a target absent from this matrix; cross-target inference is forbidden.'}
    $rows=[Collections.Generic.List[object]]::new();$warnings=[Collections.Generic.List[object]]::new()
    foreach($target in $Targets){
        $targetEvidence=@($Evidence|Where-Object {[string]$_.targetId -ceq [string]$target.targetId})
        $accepted=[Collections.Generic.List[object]]::new();$audited=[Collections.Generic.List[object]]::new()
        foreach($item in $targetEvidence){
            $mismatch=$null
            if(-not $item.PSObject.Properties['minecraftId'] -or [string]$item.minecraftId -cne [string]$target.minecraftId){$mismatch='MINECRAFT_ID_MISMATCH_OR_MISSING'}
            elseif($item.PSObject.Properties['platform'] -and ($item.platform.os -cne $target.platform.os -or $item.platform.arch -cne $target.platform.arch -or [bool]$item.platform.isWSL -ne [bool]$target.platform.isWSL)){$mismatch='PLATFORM_MISMATCH'}
            elseif($item.PSObject.Properties['loaderId'] -and [string]$item.loaderId -cne [string]$target.loaderStack.primary.id){$mismatch='LOADER_MISMATCH'}
            elseif($item.PSObject.Properties['loaderVersion'] -and [string]$item.loaderVersion -cne [string]$target.loaderVersion){$mismatch='LOADER_VERSION_MISMATCH'}
            elseif($item.toolchain.id -cne [string]$target.toolchain){$mismatch='TOOLCHAIN_MISMATCH'}
            elseif((ConvertTo-MmtlCanonicalBuildSystemId ([string]$item.buildSystem.id)) -cne (ConvertTo-MmtlCanonicalBuildSystemId ([string]$target.buildSystem))){$mismatch='BUILD_SYSTEM_MISMATCH'}
            elseif($item.sourceFixture.source -cne [string]$target.sourceFixture.source -or $item.sourceFixture.commit -cne [string]$target.sourceFixture.commit){$mismatch='FIXTURE_MISMATCH'}
            if($mismatch){$warnings.Add([pscustomobject]@{targetId=$target.targetId;runId=$item.runId;reason=$mismatch});continue}
            $audited.Add($item)
            if([string]$item.validationLevel -in @('SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')){
                if(-not (Test-MmtlAdvancedValidationEvidence -Level ([string]$item.validationLevel) -Validation $item).valid){$warnings.Add([pscustomobject]@{targetId=$target.targetId;runId=$item.runId;reason='ADVANCED_LEVEL_MISSING_STAGE_PROOF'});continue}
            }
            if($item.result -eq 'PASSED'){$accepted.Add($item)}
        }
        $hasBuildEvidence=@($accepted|Where-Object validationLevel -eq 'BUILD_VERIFIED').Count -gt 0
        if(-not $hasBuildEvidence){
            $retained=[Collections.Generic.List[object]]::new()
            foreach($item in $accepted){if($item.validationLevel -in @('SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')){$warnings.Add([pscustomobject]@{targetId=$target.targetId;runId=$item.runId;reason='ADVANCED_LEVEL_MISSING_BUILD_EVIDENCE'})}else{$retained.Add($item)}}
            $accepted=$retained
        }
        $rank=@('CATALOGUED','RESOLVED','BUILD_VERIFIED','SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')
        $resolved=if($target.PSObject.Properties['resolved']){[bool]$target.resolved}else{$false}
        $level=if($resolved){'RESOLVED'}else{'CATALOGUED'}
        foreach($item in $accepted){$index=[array]::IndexOf($rank,[string]$item.validationLevel);if($index -gt [array]::IndexOf($rank,$level)){$level=$rank[$index]}}
        $row=[ordered]@{
            targetId=[string]$target.targetId;tier=[string]$target.tier;minecraftId=[string]$target.minecraftId
            loaderStack=$target.loaderStack;loaderVersion=[string]$target.loaderVersion;toolchain=[string]$target.toolchain;toolchainVersion=$target.toolchainVersion;buildSystem=[string]$target.buildSystem
            platform=$target.platform;java=[pscustomobject]@{buildRequirement=(ConvertTo-MmtlJavaRequirement $target.java.buildRequirement);observedBuildJava=if(@($accepted|Where-Object {$_.java.observedBuildJava}).Count){($accepted|Where-Object {$_.java.observedBuildJava}|Select-Object -Last 1 -ExpandProperty java).observedBuildJava}else{$target.java.observedBuildJava};compilerTarget=if(@($accepted|Where-Object {$_.java.compilerTarget}).Count){($accepted|Where-Object {$_.java.compilerTarget}|Select-Object -Last 1 -ExpandProperty java).compilerTarget}else{$target.java.compilerTarget};runtimeRequirement=(ConvertTo-MmtlJavaRequirement $target.java.runtimeRequirement);observedRuntimeJava=if(@($accepted|Where-Object {$_.java.observedRuntimeJava}).Count){($accepted|Where-Object {$_.java.observedRuntimeJava}|Select-Object -Last 1 -ExpandProperty java).observedRuntimeJava}else{$target.java.observedRuntimeJava}};sourceFixture=$target.sourceFixture
            validation=[pscustomobject]@{effectiveLevel=$level;resolved=$resolved -or ($level -ne 'CATALOGUED');build=(@($accepted|Where-Object validationLevel -in @('BUILD_VERIFIED','SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')).Count -gt 0);server=(@($accepted|Where-Object validationLevel -eq 'SERVER_VERIFIED').Count -gt 0);client=(@($accepted|Where-Object validationLevel -eq 'CLIENT_LAUNCH_VERIFIED').Count -gt 0);integration=(@($accepted|Where-Object validationLevel -eq 'INTEGRATION_VERIFIED').Count -gt 0)}
            evidence=[pscustomobject]@{runIds=@($audited|ForEach-Object runId);timestamps=@($audited|ForEach-Object startedAt);logs=@($audited|ForEach-Object {foreach($log in $_.logs){$log.path}});hashes=@($audited|ForEach-Object {foreach($log in $_.logs){$log.sha256};if($_.artifact){$_.artifact.sha256}});artifact=if(@($accepted|Where-Object artifact).Count){($accepted|Where-Object artifact|Select-Object -Last 1 -ExpandProperty artifact|ForEach-Object filename|Select-Object -Last 1)}elseif(@($audited|Where-Object artifact).Count){($audited|Where-Object artifact|Select-Object -Last 1 -ExpandProperty artifact|ForEach-Object filename|Select-Object -Last 1)}else{$null};process=if(@($accepted|Where-Object process).Count){($accepted|Where-Object process|Select-Object -Last 1 -ExpandProperty process)}elseif(@($audited|Where-Object process).Count){($audited|Where-Object process|Select-Object -Last 1 -ExpandProperty process)}else{$null};result=if($accepted.Count){'PASSED'}elseif(@($targetEvidence|Where-Object result -eq 'BLOCKED').Count){'BLOCKED'}elseif(@($targetEvidence|Where-Object result -eq 'FAILED').Count){'FAILED'}else{'UNVERIFIED'}}
            notes=@($target.notes)
        }
        $rows.Add([pscustomobject]$row)
    }
    $matrix=[pscustomobject][ordered]@{schemaVersion=1;generatedAt=[DateTimeOffset]::UtcNow.ToString('o');scope=$Scope;targets=@($rows)}
    $json=$matrix|ConvertTo-Json -Depth 50
    $schema=Join-Path $PSScriptRoot '..\..\schemas\validation-matrix.schema.json'
    if(-not(Test-Json -Json $json -SchemaFile $schema -ErrorAction SilentlyContinue)){throw 'Aggregated validation matrix does not match its schema.'}
    if($OutputPath){
        $full=[IO.Path]::GetFullPath($OutputPath);$parent=Split-Path -Parent $full
        if(-not(Test-Path -LiteralPath $parent -PathType Container)){[void][IO.Directory]::CreateDirectory($parent)}
        [IO.File]::WriteAllText($full,$json,[Text.UTF8Encoding]::new($false))
    }
    [pscustomobject]@{matrix=$matrix;warnings=@($warnings);targetCount=$rows.Count;levelCounts=[pscustomobject]@{catalogued=@($rows|Where-Object {$_.validation.effectiveLevel -eq 'CATALOGUED'}).Count;resolved=@($rows|Where-Object {$_.validation.effectiveLevel -eq 'RESOLVED'}).Count;buildVerified=@($rows|Where-Object {$_.validation.effectiveLevel -eq 'BUILD_VERIFIED'}).Count;serverVerified=@($rows|Where-Object {$_.validation.effectiveLevel -eq 'SERVER_VERIFIED'}).Count;clientLaunchVerified=@($rows|Where-Object {$_.validation.effectiveLevel -eq 'CLIENT_LAUNCH_VERIFIED'}).Count;integrationVerified=@($rows|Where-Object {$_.validation.effectiveLevel -eq 'INTEGRATION_VERIFIED'}).Count}}
}

function Get-MmtlValidationRunEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $base=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'validation';$items=[Collections.Generic.List[object]]::new();$warnings=[Collections.Generic.List[object]]::new()
    if(Test-Path -LiteralPath $base -PathType Container){foreach($file in Get-ChildItem -LiteralPath $base -Filter result.json -File -Recurse){try{$value=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -ErrorAction Stop;$schema=Join-Path $PSScriptRoot '..\..\schemas\validation-evidence.schema.json';$json=$value|ConvertTo-Json -Depth 40;if(Test-Json -Json $json -SchemaFile $schema -ErrorAction SilentlyContinue){$items.Add($value)}else{$warnings.Add([pscustomobject]@{path=$file.FullName;reason='INVALID_SCHEMA'})}}catch{$warnings.Add([pscustomobject]@{path=$file.FullName;reason='INVALID_JSON'})}}}
    [pscustomobject]@{evidence=@($items);warnings=@($warnings)}
}

function Get-MmtlValidationTargetsFromEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence)
    $targets=[Collections.Generic.List[object]]::new();$warnings=[Collections.Generic.List[object]]::new()
    foreach($group in @($Evidence|Group-Object targetId)){
        $identityGroups=@($group.Group|Group-Object {
            ConvertTo-Json -InputObject @(
                [string]$_.minecraftId,[string]$_.loaderId,[string]$_.loaderVersion,
                [string]$_.platform.os,[string]$_.platform.arch,[bool]$_.platform.isWSL,
                [string]$_.toolchain.id,
                (ConvertTo-MmtlCanonicalBuildSystemId ([string]$_.buildSystem.id)),
                [string]$_.sourceFixture.type,[string]$_.sourceFixture.source,[string]$_.sourceFixture.commit
            ) -Compress
        })
        foreach($identityGroup in $identityGroups){
            $records=@($identityGroup.Group|Sort-Object {[DateTimeOffset]::Parse([string]$_.startedAt)} -Descending)
            $latest=$records[0]
            foreach($record in $records){
                if(-not $record.minecraftId -or -not $record.loaderId -or -not $record.loaderVersion){$warnings.Add([pscustomobject]@{targetId=$group.Name;runId=$record.runId;reason='TARGET_METADATA_INCOMPLETE'})}
            }
            if(-not $latest.minecraftId -or -not $latest.loaderId -or -not $latest.loaderVersion -or $latest.toolchain.id -eq 'Unknown'){$warnings.Add([pscustomobject]@{targetId=$group.Name;runId=$latest.runId;reason='LATEST_TARGET_METADATA_INCOMPLETE'});continue}
            $tier=switch([string]$latest.sourceFixture.type){'UserProject'{'Tier1'}'ImportedHistoricalEvidence'{'Tier3'}default{'Tier2'}}
            $targetId=[string]$latest.targetId
            if($identityGroups.Count -gt 1){
                $bytes=[Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$identityGroup.Name))
                $suffix=([Convert]::ToHexString($bytes).Substring(0,10)).ToLowerInvariant()
                $targetId="$targetId-$suffix"
            }
            $notes=if($identityGroups.Count -gt 1){@('Base target ID reused; this row is scoped to the exact source fixture identity.')}else{@()}
            $targets.Add([pscustomobject][ordered]@{
                targetId=$targetId;evidenceTargetId=[string]$latest.targetId;tier=$tier;resolved=([string]$latest.validationLevel -ne 'CATALOGUED');minecraftId=[string]$latest.minecraftId
                loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id=[string]$latest.loaderId;version=[string]$latest.loaderVersion};overlays=@()};loaderVersion=[string]$latest.loaderVersion
                toolchain=[string]$latest.toolchain.id;toolchainVersion=$latest.toolchain.version;buildSystem=(ConvertTo-MmtlCanonicalBuildSystemId ([string]$latest.buildSystem.id));platform=$latest.platform;java=$latest.java
                sourceFixture=[pscustomobject]@{type=[string]$latest.sourceFixture.type;source=[string]$latest.sourceFixture.source;commit=[string]$latest.sourceFixture.commit;license=[string]$latest.sourceFixture.license;trust=[string]$latest.sourceFixture.trust};notes=$notes
            })
        }
    }
    [pscustomobject]@{targets=@($targets);warnings=@($warnings)}
}

Export-ModuleMember -Function New-MmtlValidationMatrix,Get-MmtlValidationRunEvidence,Get-MmtlValidationTargetsFromEvidence
