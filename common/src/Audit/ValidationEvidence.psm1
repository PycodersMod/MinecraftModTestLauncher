Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\Validation\Contracts.psm1') -Force

$script:MmtlValidationLevels=@('CATALOGUED','RESOLVED','BUILD_VERIFIED','SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')

function Get-MmtlValidationEvidenceAudit {
    [CmdletBinding()]
    param([object[]]$Matrices=@(),[string[]]$CatalogReleaseIds=@(),[string]$BuildEvidenceSchemaPath=(Join-Path $PSScriptRoot '..\..\schemas\build-evidence.schema.json'))
    $records=[Collections.Generic.List[object]]::new();$warnings=[Collections.Generic.List[object]]::new()
    foreach($matrix in $Matrices){
        if(-not $matrix -or -not $matrix.PSObject.Properties['minecraft'] -or -not $matrix.minecraft -or -not $matrix.minecraft.PSObject.Properties['id'] -or -not $matrix.PSObject.Properties['loaderStack'] -or -not $matrix.loaderStack -or -not $matrix.loaderStack.PSObject.Properties['primary'] -or -not $matrix.loaderStack.primary -or -not $matrix.loaderStack.primary.PSObject.Properties['id'] -or -not $matrix.PSObject.Properties['validation']){$warnings.Add([pscustomobject]@{reasonCode='COMPATIBILITY_MATRIX_INVALID_STRUCTURE';minecraftId=$null;loaderId=$null;message='兼容性矩阵缺少必需的 Minecraft、主 Loader 或验证结构。'});continue}
        $minecraftId=[string]$matrix.minecraft.id;$loaderId=[string]$matrix.loaderStack.primary.id;$validation=$matrix.validation
        if(-not $validation.PSObject.Properties['level'] -or -not $validation.PSObject.Properties['result'] -or -not $validation.level -or -not $validation.result){$warnings.Add([pscustomobject]@{reasonCode='COMPATIBILITY_MATRIX_INVALID_VALIDATION';minecraftId=$minecraftId;loaderId=$loaderId;message='验证证据缺少 level 或 result。'});continue}
        $claimedLevel=[string]$validation.level;$result=[string]$validation.result
        if($claimedLevel -notin $script:MmtlValidationLevels -or $result -notin @('PASSED','FAILED','UNVERIFIED','STALE')){$warnings.Add([pscustomobject]@{reasonCode='COMPATIBILITY_MATRIX_INVALID_VALIDATION';minecraftId=$minecraftId;loaderId=$loaderId;message='验证证据中的 level 或 result 无法识别。'});continue}
        if(@($CatalogReleaseIds).Count -and $minecraftId -notin $CatalogReleaseIds){$warnings.Add([pscustomobject]@{reasonCode='VALIDATION_VERSION_OUTSIDE_FORMAL_CATALOG';minecraftId=$minecraftId;loaderId=$loaderId;message='兼容性矩阵中的版本不在当前正式版本目录内。'});continue}
        if($loaderId -notin @('Forge','Fabric','NeoForge','Quilt','LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){$warnings.Add([pscustomobject]@{reasonCode='VALIDATION_LOADER_UNKNOWN';minecraftId=$minecraftId;loaderId=$loaderId;message='兼容性矩阵使用了尚未注册的 Loader 标识。'});continue}
        $buildEvidence=if($validation.PSObject.Properties['buildEvidence']){@($validation.buildEvidence)}else{@()};$claimAccepted=$true;$effectiveLevel=$claimedLevel;$reasonCode='VALIDATION_EVIDENCE_ACCEPTED';$notes=@()
        $levelIndex=[array]::IndexOf($script:MmtlValidationLevels,$claimedLevel)
        $buildAccepted=$false
        if($levelIndex -ge 2 -and $result -eq 'PASSED'){
            if(@($buildEvidence).Count -eq 0){$claimAccepted=$false;$effectiveLevel='RESOLVED';$reasonCode='BUILD_VERIFIED_CLAIM_MISSING_EVIDENCE';$notes+='构建验证声明缺少结构化构建证据。'}
            else{
                foreach($build in $buildEvidence){
                    $invalidReason=$null
                    $compiler=if($build -and $build.PSObject.Properties['compilerTarget']){$build.compilerTarget}else{$null};$observed=if($build -and $build.PSObject.Properties['observedBuildJava']){$build.observedBuildJava}else{$null}
                    if(-not $compiler -or -not $compiler.PSObject.Properties['major'] -or [int]$compiler.major -lt 1){$invalidReason='BUILD_EVIDENCE_MISSING_COMPILER_TARGET'}
                    elseif(-not $observed -or -not $observed.PSObject.Properties['major'] -or [int]$observed.major -lt 1 -or -not $observed.PSObject.Properties['exactVersion'] -or [string]::IsNullOrWhiteSpace([string]$observed.exactVersion)){$invalidReason='BUILD_EVIDENCE_MISSING_OBSERVED_JAVA'}
                    else{$json=$build|ConvertTo-Json -Depth 30 -Compress;if(-not (Test-Json -Json $json -SchemaFile $BuildEvidenceSchemaPath -ErrorAction SilentlyContinue)){$invalidReason='BUILD_EVIDENCE_SCHEMA_INVALID'}}
                    if($invalidReason){$claimAccepted=$false;$effectiveLevel='RESOLVED';$reasonCode=$invalidReason;$notes+="构建证据不完整或无效（$invalidReason）。";break}
                }
                if(-not $reasonCode -or $reasonCode -eq 'VALIDATION_EVIDENCE_ACCEPTED'){$buildAccepted=$true}
            }
        }
        if($claimAccepted -and $result -eq 'PASSED' -and $claimedLevel -in @('SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')){
            $advanced=Test-MmtlAdvancedValidationEvidence -Level $claimedLevel -Validation $validation
            if(-not $advanced.valid){$claimAccepted=$false;$effectiveLevel=if($buildAccepted){'BUILD_VERIFIED'}else{'RESOLVED'};$reasonCode=$advanced.reasonCode;$notes+=$advanced.message}
        }
        $lastVerified=if($validation.PSObject.Properties['lastVerified']){$validation.lastVerified}else{$null};$evidenceItems=if($validation.PSObject.Properties['evidence']){@($validation.evidence)}else{@()};$matrixProvenance=if($matrix.PSObject.Properties['provenance']){@($matrix.provenance)}else{@()}
        $record=[pscustomobject][ordered]@{minecraftId=$minecraftId;loaderId=$loaderId;level=$effectiveLevel;claimedLevel=$claimedLevel;result=$result;claimAccepted=$claimAccepted;reasonCode=$reasonCode;lastVerified=$lastVerified;evidence=$evidenceItems;buildEvidence=if($buildAccepted){$buildEvidence}else{@()};serverEvidence=if($validation.PSObject.Properties['serverEvidence']){$validation.serverEvidence}else{$null};clientEvidence=if($validation.PSObject.Properties['clientEvidence']){$validation.clientEvidence}else{$null};integrationEvidence=if($validation.PSObject.Properties['integrationEvidence']){$validation.integrationEvidence}else{$null};provenance=$matrixProvenance;notes=$notes}
        $records.Add($record)
        if(-not $claimAccepted){$warnings.Add([pscustomobject]@{reasonCode=$reasonCode;minecraftId=$minecraftId;loaderId=$loaderId;message=$notes -join '; '})}
    }
    [pscustomobject]@{records=@($records);warnings=@($warnings);matrixCount=@($Matrices).Count;acceptedCount=@($records|Where-Object claimAccepted).Count;rejectedClaimCount=@($records|Where-Object{-not $_.claimAccepted}).Count}
}

function Get-MmtlRuntimeValidationMatrices {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $directories=@((Join-Path $RuntimeRoot 'metadata/compatibility-matrix'),(Join-Path $RuntimeRoot 'evidence/compatibility-matrix'))
    $items=[Collections.Generic.List[object]]::new();$warnings=[Collections.Generic.List[object]]::new()
    foreach($directory in $directories){if(-not (Test-Path -LiteralPath $directory -PathType Container)){continue};foreach($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -Recurse){try{$items.Add((Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -ErrorAction Stop))}catch{$warnings.Add([pscustomobject]@{reasonCode='COMPATIBILITY_MATRIX_INVALID_JSON';path=$file.FullName;message=$_.Exception.Message})}}}
    [pscustomobject]@{matrices=@($items);warnings=@($warnings);sourceDirectories=$directories}
}

Export-ModuleMember -Function Get-MmtlValidationEvidenceAudit,Get-MmtlRuntimeValidationMatrices
