Set-StrictMode -Version Latest

function Get-MmtlPlanProperty {
    param([Parameter(Mandatory)][AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if($null -eq $InputObject){return $null}
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { if ([string]$key -ceq $Name) { return $InputObject[$key] } }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-MmtlCanonicalValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $canonical = [ordered]@{}
        $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $canonical[$key] = ConvertTo-MmtlCanonicalValue -Value $Value[$key] }
        return $canonical
    }
    if ($Value -is [pscustomobject]) {
        $canonical = [ordered]@{}
        $properties = @($Value.PSObject.Properties)
        $names = [string[]]@($properties | ForEach-Object Name)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        foreach ($name in $names) { $property = $Value.PSObject.Properties[$name]; $canonical[$name] = ConvertTo-MmtlCanonicalValue -Value $property.Value }
        return $canonical
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-MmtlCanonicalValue -Value $item)) }
        return ,@($items.ToArray())
    }
    return [string]$Value
}

function ConvertTo-MmtlSemanticArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return $null }
    return [regex]::Replace($Value, '(?i)(?:[a-z]:[\\/][^\s";]+|\\\\[^\\\s]+\\[^\\\s]+[^\s";]*|/(?:[^\s/:";]+/)*[^\s/:";]+)', '<LOCAL_PATH>')
}

function Get-MmtlExecutionPlanSemanticProjection {
    param([Parameter(Mandatory)]$Plan)
    $platform = Get-MmtlPlanProperty $Plan 'platform'
    $repository = Get-MmtlPlanProperty $Plan 'repository'
    $project = Get-MmtlPlanProperty $Plan 'project'
    $buildJava = Get-MmtlPlanProperty $Plan 'buildJava'
    $runtimeJava = Get-MmtlPlanProperty $Plan 'runtimeJava'
    $profile = Get-MmtlPlanProperty $Plan 'profile'
    $build = Get-MmtlPlanProperty $Plan 'build'
    $runtime = Get-MmtlPlanProperty $Plan 'runtime'
    $network = Get-MmtlPlanProperty $Plan 'network'
    $session = Get-MmtlPlanProperty $Plan 'session'
    $capabilities = Get-MmtlPlanProperty $platform 'capabilities'
    $buildRequirement = Get-MmtlPlanProperty $buildJava 'requirement'
    $runtimeRequirement = Get-MmtlPlanProperty $runtimeJava 'requirement'
    $runtimeDirs = @((Get-MmtlPlanProperty $runtime 'runtimeDirectories') | ForEach-Object {
        [ordered]@{ role=(Get-MmtlPlanProperty $_ 'role'); relativePath=(Get-MmtlPlanProperty $_ 'relativePath') }
    })
    $buildSemantic = [ordered]@{}
    foreach ($name in @('major','minimumMajor','preferredMajor','exactMajor','requirementKind','source','confidence','component')) {
        $value = Get-MmtlPlanProperty $buildRequirement $name
        if ($null -ne $value) { $buildSemantic[$name] = $value }
    }
    $runtimeSemantic = [ordered]@{}
    foreach ($name in @('major','minimumMajor','preferredMajor','exactMajor','requirementKind','source','confidence','component')) {
        $value = Get-MmtlPlanProperty $runtimeRequirement $name
        if ($null -ne $value) { $runtimeSemantic[$name] = $value }
    }
    $profileSemantic = [ordered]@{}
    foreach ($name in @('name','mode','players','hostUsername','clientPrefix','hostCheats','clientPermissionLevel','gameMode','difficulty','worldName','seed','newWorld','resetWorld','memoryMb','hostMemoryMb','clientMemoryMb','serverMemoryMb','acceptEula','resolution','guiScale','windowLayout','autoBuild','cleanBuild','port')) {
        $value = Get-MmtlPlanProperty $profile $name
        if ($null -ne $value) { $profileSemantic[$name] = $value }
    }
    foreach ($name in @('jvmArgs','gameArgs')) {
        $items = Get-MmtlPlanProperty $profile $name
        if ($null -ne $items) { $profileSemantic[$name] = @($items | ForEach-Object { ConvertTo-MmtlSemanticArgument ([string]$_) }) }
    }
    $runtimeSemanticData = [ordered]@{ roles=@(Get-MmtlPlanProperty $runtime 'roles');runtimeDirectories=$runtimeDirs;memory=(Get-MmtlPlanProperty $runtime 'memory');jvmArgs=@((Get-MmtlPlanProperty $runtime 'jvmArgs') | ForEach-Object { ConvertTo-MmtlSemanticArgument ([string]$_) });gameArgs=@((Get-MmtlPlanProperty $runtime 'gameArgs') | ForEach-Object { ConvertTo-MmtlSemanticArgument ([string]$_) }) }
    $stack = @((Get-MmtlPlanProperty $project 'loaderStack') | ForEach-Object {
        [ordered]@{id=(Get-MmtlPlanProperty $_ 'id');version=(Get-MmtlPlanProperty $_ 'version');role=(Get-MmtlPlanProperty $_ 'role')}
    })
    $projectSemantic = [ordered]@{
        minecraftId=(Get-MmtlPlanProperty $project 'minecraftId')
        loader=(Get-MmtlPlanProperty $project 'loader')
        loaderStack=$stack
        toolchain=(Get-MmtlPlanProperty $project 'toolchain')
        buildSystem=(Get-MmtlPlanProperty $project 'buildSystem')
        modId=(Get-MmtlPlanProperty $project 'modId')
    }
    $semantic = [ordered]@{
        platform=[ordered]@{os=(Get-MmtlPlanProperty $platform 'os');arch=(Get-MmtlPlanProperty $platform 'arch');isWSL=(Get-MmtlPlanProperty $platform 'isWSL');capabilities=$capabilities}
        repositoryIdentity=(Get-MmtlPlanProperty $repository 'identity')
        project=$projectSemantic
        buildJava=[ordered]@{requirement=$buildSemantic}
        runtimeJava=[ordered]@{requirement=$runtimeSemantic;bindingMode=(Get-MmtlPlanProperty $runtimeJava 'bindingMode')}
        profile=$profileSemantic
        build=[ordered]@{required=(Get-MmtlPlanProperty $build 'required');clean=(Get-MmtlPlanProperty $build 'clean');task=(Get-MmtlPlanProperty $build 'task');artifactExpectation=(Get-MmtlPlanProperty $build 'artifactExpectation')}
        runtime=$runtimeSemanticData
        network=$network
        session=[ordered]@{intendedMode=(Get-MmtlPlanProperty $session 'intendedMode')}
    }
    return ConvertTo-MmtlCanonicalValue -Value $semantic
}

function Get-MmtlExecutionPlanSemanticDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    $semantic = Get-MmtlExecutionPlanSemanticProjection -Plan $Plan
    $canonicalJson = ConvertTo-Json -InputObject $semantic -Depth 100 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($canonicalJson)
    $sha = [Security.Cryptography.SHA256]::HashData($bytes)
    return 'sha256:' + [Convert]::ToHexString($sha).ToLowerInvariant()
}

function Test-MmtlExecutionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [string]$SchemaPath=(Join-Path $PSScriptRoot '../../schemas/execution-plan.schema.json'))
    $errors = [Collections.Generic.List[string]]::new()
    try { $json = ConvertTo-Json -InputObject $Plan -Depth 100 -Compress } catch { $json = ''; $errors.Add('PLAN_JSON_INVALID') }
    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) { $errors.Add('PLAN_SCHEMA_NOT_FOUND') }
    elseif (-not (Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) { $errors.Add('PLAN_SCHEMA_INVALID') }

    $storedDigest = [string](Get-MmtlPlanProperty $Plan 'semanticDigest')
    if ($storedDigest -match '^sha256:[0-9a-f]{64}$' -and $storedDigest -cne (Get-MmtlExecutionPlanSemanticDigest -Plan $Plan)) { $errors.Add('PLAN_DIGEST_MISMATCH') }
    elseif ($storedDigest -notmatch '^sha256:[0-9a-f]{64}$') { $errors.Add('PLAN_DIGEST_INVALID') }

    $buildJava = Get-MmtlPlanProperty $Plan 'buildJava'
    $buildRequirement = Get-MmtlPlanProperty $buildJava 'requirement'
    $buildResolution = Get-MmtlPlanProperty $buildJava 'resolution'
    $buildMinimum = Get-MmtlPlanProperty $buildRequirement 'minimumMajor'
    $buildExact = Get-MmtlPlanProperty $buildRequirement 'exactMajor'
    $buildActual = Get-MmtlPlanProperty $buildResolution 'actualMajor'
    $buildStatus=Get-MmtlPlanProperty $buildResolution 'status'
    if ($buildStatus -eq 'Resolved' -and $buildMinimum -and $buildActual -and [int]$buildActual -lt [int]$buildMinimum) { $errors.Add('BUILD_JAVA_RESOLUTION_INCONSISTENT') }
    if ($buildStatus -eq 'Resolved' -and $buildExact -and $buildActual -and [int]$buildActual -ne [int]$buildExact) { $errors.Add('BUILD_JAVA_RESOLUTION_INCONSISTENT') }

    $runtimeJava = Get-MmtlPlanProperty $Plan 'runtimeJava'
    $runtimeRequirement = Get-MmtlPlanProperty $runtimeJava 'requirement'
    $runtimeResolution = Get-MmtlPlanProperty $runtimeJava 'resolution'
    $runtimeMajor = Get-MmtlPlanProperty $runtimeRequirement 'major'
    $runtimeStatus=Get-MmtlPlanProperty $runtimeResolution 'status';$runtimeActual=Get-MmtlPlanProperty $runtimeResolution 'actualMajor';$runtimeKind=Get-MmtlPlanProperty $runtimeRequirement 'requirementKind'
    if ($runtimeStatus -eq 'Resolved' -and $runtimeMajor -and $runtimeActual -and $runtimeKind -ne 'Minimum' -and [int]$runtimeActual -ne [int]$runtimeMajor) { $errors.Add('RUNTIME_JAVA_RESOLUTION_INCONSISTENT') }
    if ($runtimeStatus -eq 'Resolved' -and $runtimeMajor -and $runtimeActual -and $runtimeKind -eq 'Minimum' -and [int]$runtimeActual -lt [int]$runtimeMajor) { $errors.Add('RUNTIME_JAVA_RESOLUTION_INCONSISTENT') }

    $profile = Get-MmtlPlanProperty $Plan 'profile'
    $session = Get-MmtlPlanProperty $Plan 'session'
    if ((Get-MmtlPlanProperty $profile 'mode') -cne (Get-MmtlPlanProperty $session 'intendedMode')) { $errors.Add('PLAN_SESSION_MODE_MISMATCH') }
    $gates=Get-MmtlPlanProperty $Plan 'capabilityGates';$buildReady=[bool](Get-MmtlPlanProperty $gates 'buildReady');$launchReady=[bool](Get-MmtlPlanProperty $gates 'launchReady')
    $expectedStatus=if($launchReady){'Ready'}elseif($buildReady){'BuildReadyLaunchBlocked'}else{'Blocked'}
    if((Get-MmtlPlanProperty $Plan 'status') -cne $expectedStatus){$errors.Add('PLAN_STATUS_INCONSISTENT')}
    [pscustomobject][ordered]@{valid=($errors.Count -eq 0);errors=@($errors.ToArray())}
}

function Compare-MmtlExecutionPlanSemantic {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)
    [pscustomobject]@{same=( (Get-MmtlExecutionPlanSemanticDigest $Left) -ceq (Get-MmtlExecutionPlanSemanticDigest $Right) );leftDigest=(Get-MmtlExecutionPlanSemanticDigest $Left);rightDigest=(Get-MmtlExecutionPlanSemanticDigest $Right)}
}

Export-ModuleMember -Function Get-MmtlExecutionPlanSemanticDigest,Test-MmtlExecutionPlan,Compare-MmtlExecutionPlanSemantic
