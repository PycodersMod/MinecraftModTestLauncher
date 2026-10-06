Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../Observation/ObservationSafety.psm1') -Force

function Resolve-MmtlLogPath {
    param([string]$SessionPath,[string]$Path,[switch]$AllowMissing)
    return Resolve-MmtlObserverSafePath -SessionPath $SessionPath -Target $Path -AllowMissing:$AllowMissing.IsPresent
}

function Write-MmtlLogAppend {
    param([string]$Path,[string]$Text)
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text)
    $deadline=[DateTime]::UtcNow.AddSeconds(10);$stream=$null
    do{try{$stream=[IO.File]::Open($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::None)}catch [IO.IOException]{Start-Sleep -Milliseconds 25}}while(-not $stream -and [DateTime]::UtcNow -lt $deadline)
    if(-not $stream){throw 'STRUCTURED_LOG_LOCK_TIMEOUT'}
    try{$stream.Seek(0,[IO.SeekOrigin]::End)|Out-Null;$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

function Initialize-MmtlStructuredLogWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)
    $session=[IO.Path]::GetFullPath($SessionPath)
    if(-not(Test-Path -LiteralPath $session -PathType Container)){throw 'STRUCTURED_LOG_SESSION_MISSING'}
    foreach($relative in @('logs','logs/raw','logs/structured','logs/relevant','analysis')){
        $path=Join-Path $session $relative
        if(Test-Path -LiteralPath $path){$null=Resolve-MmtlLogPath -SessionPath $session -Path $path}
        else{$null=Resolve-MmtlLogPath -SessionPath $session -Path $path -AllowMissing;$null=New-Item -ItemType Directory -Path $path -Force}
    }
    return [pscustomobject]@{sessionId=[IO.Path]::GetFileName($session);rawDirectory=(Join-Path $session 'logs/raw');structuredDirectory=(Join-Path $session 'logs/structured');relevantDirectory=(Join-Path $session 'logs/relevant');analysisDirectory=(Join-Path $session 'analysis')}
}

function ConvertTo-MmtlLogSafeIdentity {
    param([string]$Identity)
    $safe=[regex]::Replace([string]$Identity,'[^A-Za-z0-9_-]','_').Trim('_')
    if(-not $safe){throw 'STRUCTURED_LOG_IDENTITY_INVALID'}
    return $safe.Substring(0,[Math]::Min(48,$safe.Length))
}

function Add-MmtlStructuredLogLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidateSet('Host','Guest','Client','Server','Agent','Build','Launcher','Runtime','Scenario')][string]$Role,[Parameter(Mandatory)][string]$Identity,[Parameter(Mandatory)][string]$SourceFile,[Parameter(Mandatory)][AllowEmptyString()][string]$Line,[string]$ObservedAtUtc=[DateTimeOffset]::UtcNow.ToString('o'))
    $session=[IO.Path]::GetFullPath($SessionPath);$null=Initialize-MmtlStructuredLogWorkspace -SessionPath $session
    $source=Resolve-MmtlLogPath -SessionPath $session -Path $SourceFile -AllowMissing
    $relative=[IO.Path]::GetRelativePath($session,$source).Replace('\','/')
    $identitySafe=ConvertTo-MmtlLogSafeIdentity $Identity
    $key="$Role-$identitySafe";$rawPath=Join-Path $session "logs/raw/$key.log";$structuredPath=Join-Path $session "logs/structured/$key.jsonl"
    $rawPath=Resolve-MmtlLogPath -SessionPath $session -Path $rawPath -AllowMissing;$structuredPath=Resolve-MmtlLogPath -SessionPath $session -Path $structuredPath -AllowMissing
    $observed=[DateTimeOffset]::MinValue;if(-not[DateTimeOffset]::TryParse($ObservedAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$observed)){throw 'STRUCTURED_LOG_OBSERVED_TIME_INVALID'}
    $observedText=$observed.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)
    $sourceTimestamp=$null;$sourceTimestampUtc=$null;$level='UNKNOWN';$logger=$null;$message=$Line
    $match=[regex]::Match($Line,'^\[(?<timestamp>[^\]]+)\]\s+\[(?<context>[^\]]+)\](?:\s+\[(?<logger>[^\]]+)\])?:\s*(?<message>.*)$')
    if($match.Success){
        $sourceTimestamp=$match.Groups['timestamp'].Value;$message=$match.Groups['message'].Value
        $context=$match.Groups['context'].Value;$contextParts=$context -split '/',2
        if($contextParts.Count -eq 2 -and $contextParts[1] -match '^[A-Z]+$'){$level=$contextParts[1]}
        elseif($context -match '^[A-Z]+$'){$level=$context}
        if($match.Groups['logger'].Success){$logger=$match.Groups['logger'].Value}
        $parsed=[DateTimeOffset]::MinValue
        if([DateTimeOffset]::TryParse($sourceTimestamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed) -and $sourceTimestamp -match '\d{4}[-/]\d{2}[-/]\d{2}'){$sourceTimestampUtc=$parsed.ToUniversalTime().ToString('o')}
    }
    Write-MmtlLogAppend -Path $rawPath -Text ($Line+"`n")
    $record=[pscustomobject][ordered]@{schemaVersion=1;sessionId=[IO.Path]::GetFileName($session);role=$Role;identity=$Identity;sourceFile=$relative;sourceTimestamp=$sourceTimestamp;sourceTimestampUtc=$sourceTimestampUtc;observedAtUtc=$observedText;level=$level;logger=$logger;message=$message}
    Write-MmtlLogAppend -Path $structuredPath -Text (($record|ConvertTo-Json -Depth 8 -Compress)+"`n")
    return $record
}

function Save-MmtlLogImportState {
    param([string]$Path,$State)
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temp,($State|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $Path -Force}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}

function Get-MmtlLogSourceRelativePath {
    param([string]$Session,[string]$Path)
    return [IO.Path]::GetRelativePath($Session,$Path).Replace('\','/')
}

function ConvertTo-MmtlTimelineTimestamp {
    param($Value)
    if($Value -is [DateTimeOffset]){return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)}
    if($Value -is [DateTime]){return ([DateTimeOffset]$Value).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)}
    $parsed=[DateTimeOffset]::MinValue
    if([DateTimeOffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)){return $parsed.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)}
    return ''
}

function Import-MmtlSessionLogs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)
    $session=[IO.Path]::GetFullPath($SessionPath);$null=Initialize-MmtlStructuredLogWorkspace -SessionPath $session
    $pidPath=Join-Path $session 'pids.json'
    if(-not(Test-Path -LiteralPath $pidPath -PathType Leaf)){throw 'STRUCTURED_LOG_PROCESS_REGISTRY_MISSING'}
    $null=Resolve-MmtlLogPath -SessionPath $session -Path $pidPath
    $registry=@(Get-Content -LiteralPath $pidPath -Raw|ConvertFrom-Json -ErrorAction Stop)
    $statePath=Join-Path $session 'logs/ingest-state.json';$null=Resolve-MmtlLogPath -SessionPath $session -Path $statePath -AllowMissing
    $state=[ordered]@{schemaVersion=1;sources=[ordered]@{}}
    if(Test-Path -LiteralPath $statePath){try{$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -AsHashtable -ErrorAction Stop;if([int]$state.schemaVersion -ne 1 -or $null -eq $state.sources){throw 'STRUCTURED_LOG_INGEST_STATE_INVALID'}}catch{throw 'STRUCTURED_LOG_INGEST_STATE_INVALID'}}
    $imported=[Collections.Generic.List[object]]::new();$sourceSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $registry){
        if(-not $entry.LogPath){continue}
        $base=Resolve-MmtlLogPath -SessionPath $session -Path ([string]$entry.LogPath) -AllowMissing
        $parent=Split-Path -Parent $base;$baseName=[IO.Path]::GetFileName($base)
        $candidates=@()
        foreach($candidate in @(Get-ChildItem -LiteralPath $parent -File -Filter ($baseName+'*') -ErrorAction SilentlyContinue)){
            $suffix=$candidate.Name.Substring($baseName.Length)
            if($suffix -eq '' -or $suffix -eq '.err' -or $suffix -match '^\.(?:err\.)?\d{1,3}$'){$candidates+= $candidate.FullName}
        }
        $candidates=@($candidates|Sort-Object @{Expression={if($_ -match '\.(?:err\.)?(\d+)$'){ -[int]$Matches[1] }else{0}}},@{Expression={$_}})
        foreach($candidatePath in $candidates){
            $candidate=Resolve-MmtlLogPath -SessionPath $session -Path $candidatePath
            if(-not $sourceSet.Add($candidate)){continue}
            $relative=Get-MmtlLogSourceRelativePath -Session $session -Path $candidate
            $bytes=[IO.File]::ReadAllBytes($candidate);if(-not $bytes.Length){continue}
            $item=$state.sources[$relative];$prefixCount=if($item -and $item.prefixLength){[int]$item.prefixLength}else{[Math]::Min(64,$bytes.Length)}
            if($prefixCount -gt $bytes.Length){$prefixCount=[Math]::Min(64,$bytes.Length)}
            $prefixHash=if($prefixCount){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes[0..($prefixCount-1)])).ToLowerInvariant()}else{''}
            $offset=if($item){[long]$item.offsetBytes}else{0L}
            if($offset -gt $bytes.Length -or ($item -and [string]$item.prefixHash -cne $prefixHash)){$offset=0;$prefixCount=[Math]::Min(64,$bytes.Length);$prefixHash=if($prefixCount){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes[0..($prefixCount-1)])).ToLowerInvariant()}else{''}}
            $start=[int]$offset;$lastNewline=-1;for($i=$start;$i -lt $bytes.Length;$i++){if($bytes[$i] -eq 10){$lastNewline=$i}}
            if($lastNewline -lt $start){$state.sources[$relative]=@{offsetBytes=$offset;prefixHash=$prefixHash;prefixLength=$prefixCount};continue}
            $length=$lastNewline-$start+1;$text=[Text.UTF8Encoding]::new($false).GetString($bytes,$start,$length)
            $role=if($entry.Role){[string]$entry.Role}else{'Client'};$identity=if($entry.Username){[string]$entry.Username}else{$role}
            foreach($line in ($text -split "`n")){$line=$line.TrimEnd("`r").TrimStart([char]0xFEFF);if($line.Length){$imported.Add((Add-MmtlStructuredLogLine -SessionPath $session -Role $role -Identity $identity -SourceFile $candidate -Line $line))}}
            $state.sources[$relative]=@{offsetBytes=($offset+$length);prefixHash=$prefixHash;prefixLength=$prefixCount}
        }
    }
    Save-MmtlLogImportState -Path $statePath -State $state
    $null=Export-MmtlSessionTimeline -SessionPath $session
    return [pscustomobject]@{sessionId=[IO.Path]::GetFileName($session);importedLines=@($imported.ToArray());sourceCount=$sourceSet.Count;timelinePath=(Join-Path $session 'analysis/timeline.jsonl')}
}

function Export-MmtlSessionTimeline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)
    $session=[IO.Path]::GetFullPath($SessionPath);$null=Initialize-MmtlStructuredLogWorkspace -SessionPath $session
    $items=[Collections.Generic.List[object]]::new();$sequence=0
    $structuredRoot=Join-Path $session 'logs/structured'
    foreach($file in @(Get-ChildItem -LiteralPath $structuredRoot -File -Filter '*.jsonl' -ErrorAction SilentlyContinue|Sort-Object Name)){
        $safe=Resolve-MmtlLogPath -SessionPath $session -Path $file.FullName
        foreach($line in [IO.File]::ReadAllLines($safe,[Text.Encoding]::UTF8)){if(-not $line){continue};try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue};$sequence++;$items.Add([pscustomobject]@{sequence=$sequence;recordType='StructuredLog';sessionId=[string]$record.sessionId;observedAtUtc=[string]$record.observedAtUtc;sourceTimestamp=[string]$record.sourceTimestamp;role=[string]$record.role;identity=[string]$record.identity;sourceFile=[string]$record.sourceFile;level=[string]$record.level;logger=[string]$record.logger;eventCode=$null;message=[string]$record.message;metadata=$null})}
    }
    $runtimePath=Join-Path $session 'runtime-events.jsonl'
    if(Test-Path -LiteralPath $runtimePath){$safe=Resolve-MmtlLogPath -SessionPath $session -Path $runtimePath;foreach($line in [IO.File]::ReadAllLines($safe,[Text.Encoding]::UTF8)){try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue};$sequence++;$items.Add([pscustomobject]@{sequence=$sequence;recordType='RuntimeEvent';sessionId=[string]$record.sessionId;observedAtUtc=[string]$record.timestampUtc;sourceTimestamp=$null;role=[string]$record.role;identity=$null;sourceFile='runtime-events.jsonl';level=$null;logger=$null;eventCode=[string]$record.eventCode;message=[string]$record.summary;metadata=$record.metadata})}}
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $session 'agent-events') -File -Filter '*.jsonl' -ErrorAction SilentlyContinue|Sort-Object Name)){ $safe=Resolve-MmtlLogPath -SessionPath $session -Path $file.FullName;foreach($line in [IO.File]::ReadAllLines($safe,[Text.Encoding]::UTF8)){try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue};$sequence++;$items.Add([pscustomobject]@{sequence=$sequence;recordType='AgentEvent';sessionId=[string]$record.sessionId;observedAtUtc=[string]$record.timestampUtc;sourceTimestamp=$null;role=[string]$record.role;identity=$null;sourceFile=(Get-MmtlLogSourceRelativePath $session $safe);level=$null;logger=$null;eventCode=[string]$record.eventType;message=[string]$record.summary;metadata=$(if($record.PSObject.Properties['port']){@{port=[int]$record.port}}else{$null})})}}
    $scenarioPath=Join-Path $session 'scenario-events.jsonl'
    if(Test-Path -LiteralPath $scenarioPath){$safe=Resolve-MmtlLogPath -SessionPath $session -Path $scenarioPath;foreach($line in [IO.File]::ReadAllLines($safe,[Text.Encoding]::UTF8)){try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue};$sequence++;$items.Add([pscustomobject]@{sequence=$sequence;recordType='ScenarioEvent';sessionId=[string]$record.sessionId;observedAtUtc=[string]$record.observedAtUtc;sourceTimestamp=$null;role=[string]$record.role;identity=$null;sourceFile='scenario-events.jsonl';level=$null;logger=$null;eventCode=[string]$record.eventCode;message=[string]$record.summary;metadata=$null})}}
    foreach($item in $items){$item.observedAtUtc=ConvertTo-MmtlTimelineTimestamp $item.observedAtUtc}
    $ordered=@($items|Sort-Object @{Expression={try{[DateTimeOffset]::Parse([string]$_.observedAtUtc).UtcTicks}catch{[long]::MaxValue}}},sequence)
    $timelinePath=Join-Path $session 'analysis/timeline.jsonl';$timelinePath=Resolve-MmtlLogPath -SessionPath $session -Path $timelinePath -AllowMissing
    $content=if($ordered.Count){(($ordered|ForEach-Object{$_|ConvertTo-Json -Depth 12 -Compress}) -join "`n")+"`n"}else{''}
    $temp=$timelinePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp';try{[IO.File]::WriteAllText($temp,$content,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $timelinePath -Force}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
    return [pscustomobject]@{timelinePath=$timelinePath;count=$ordered.Count}
}

function Get-MmtlSessionTimeline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)
    $session=[IO.Path]::GetFullPath($SessionPath);$path=Join-Path $session 'analysis/timeline.jsonl'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return @()}
    $safe=Resolve-MmtlLogPath -SessionPath $session -Path $path
    $result=[Collections.Generic.List[object]]::new();foreach($line in [IO.File]::ReadAllLines($safe,[Text.Encoding]::UTF8)){if(-not $line){continue};try{$record=$line|ConvertFrom-Json -ErrorAction Stop;$record.observedAtUtc=ConvertTo-MmtlTimelineTimestamp $record.observedAtUtc;$result.Add($record)}catch{throw 'STRUCTURED_LOG_TIMELINE_INVALID'}}
    return @($result.ToArray())
}

Export-ModuleMember -Function Initialize-MmtlStructuredLogWorkspace,Add-MmtlStructuredLogLine,Import-MmtlSessionLogs,Export-MmtlSessionTimeline,Get-MmtlSessionTimeline
