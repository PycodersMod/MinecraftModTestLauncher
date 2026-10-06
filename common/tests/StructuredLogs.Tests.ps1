BeforeAll {
    $script:logModule=Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Logs/StructuredLogWorkspace.psm1'
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Observation/RuntimeEventStore.psm1') -Force
    Import-Module $script:logModule -Force
}

Describe 'Session Structured Log Workspace' {
    BeforeEach {
        $script:session=Join-Path $TestDrive ('logs-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:session -Force|Out-Null
        Initialize-MmtlStructuredLogWorkspace -SessionPath $session|Out-Null
    }

    It '保留原始日志并逐行追加结构化角色记录' {
        $source=Join-Path $session 'logs/source/client.log';New-Item -ItemType Directory -Path (Split-Path $source -Parent) -Force|Out-Null
        $line='[12:34:56] [Render thread/ERROR] [com.example.WidgetMod/]: Failed to load widget'
        $first=Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity Iris -SourceFile $source -Line $line -ObservedAtUtc '2026-10-06T04:35:00Z'
        Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity Iris -SourceFile $source -Line '[12:34:57] [Render thread/INFO]: next' -ObservedAtUtc '2026-10-06T04:35:01Z'|Out-Null
        $first.role | Should -Be 'Client';$first.identity | Should -Be 'Iris';$first.level | Should -Be 'ERROR';$first.logger | Should -Be 'com.example.WidgetMod/';$first.message | Should -Be 'Failed to load widget';$first.sourceTimestamp | Should -Be '12:34:56';$first.observedAtUtc | Should -Be '2026-10-06T04:35:00.0000000Z'
        $raw=Get-ChildItem (Join-Path $session 'logs/raw') -File
        $raw.Count | Should -Be 1;(Get-Content $raw[0].FullName).Count | Should -Be 2
        $structured=Get-ChildItem (Join-Path $session 'logs/structured') -File
        @(Get-Content $structured[0].FullName|ForEach-Object{$_|ConvertFrom-Json}).Count | Should -Be 2
        Test-Path (Join-Path $session 'logs/relevant') | Should -BeTrue
        Test-Path (Join-Path $session 'analysis') | Should -BeTrue
    }

    It '合并角色日志、Runtime Event、Agent Event 与 Scenario Event，并保留两类时间戳' {
        $source=Join-Path $session 'logs/source/client.log';New-Item -ItemType Directory -Path (Split-Path $source -Parent) -Force|Out-Null
        $log=Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity Iris -SourceFile $source -Line '[12:00:00] [main/WARN]: mod warning' -ObservedAtUtc '2026-10-06T04:00:02Z'
        $id=[IO.Path]::GetFileName($session)
        $runtime=New-MmtlRuntimeEvent -SessionId $id -Role Host -ProcessId 11 -ProcessIdentity 'host-identity' -SourceType Agent -EventCode AGENT_STARTED -Summary 'agent started' -TimestampUtc '2026-10-06T04:00:01Z'
        Write-MmtlRuntimeEvent -SessionPath $session -Event $runtime|Out-Null
        $agentDir=Join-Path $session 'agent-events';New-Item -ItemType Directory -Path $agentDir -Force|Out-Null
        $agent=[ordered]@{schemaVersion=1;sessionId=$id;role='Guest';eventId='agent-1';eventType='WORLD_JOINED';timestampUtc='2026-10-06T04:00:03Z';sessionNonceHash=('a'*64);summary='guest joined'}
        [IO.File]::WriteAllText((Join-Path $agentDir 'guest.jsonl'),(($agent|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $scenarioDir=Join-Path $session 'scenario-events.jsonl'
        $scenario=[ordered]@{schemaVersion=1;sessionId=$id;sequence=2;eventCode='ROLE_READY';state='Observing';role='Host';observedAtUtc='2026-10-06T04:00:00Z';summary='host ready'}
        [IO.File]::WriteAllText($scenarioDir,(($scenario|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        Export-MmtlSessionTimeline -SessionPath $session|Out-Null
        $timeline=@(Get-MmtlSessionTimeline -SessionPath $session)
        $timeline.Count | Should -Be 4
        $timeline[0].recordType | Should -Be 'ScenarioEvent';$timeline[1].recordType | Should -Be 'RuntimeEvent';$timeline[2].recordType | Should -Be 'StructuredLog';$timeline[3].recordType | Should -Be 'AgentEvent'
        $logEntry=$timeline|Where-Object recordType -eq 'StructuredLog'|Select-Object -First 1
        $logEntry.sourceTimestamp | Should -Be '12:00:00';$logEntry.observedAtUtc | Should -Be '2026-10-06T04:00:02.0000000Z';$logEntry.role | Should -Be 'Client';$logEntry.identity | Should -Be 'Iris'
    }

    It '增量导入普通与轮转日志，忽略空文件并等待未完成尾行' {
        $sourceDir=Join-Path $session 'logs/source';New-Item -ItemType Directory -Path $sourceDir -Force|Out-Null
        $source=Join-Path $sourceDir 'client.log';$rotated=$source+'.1';$empty=Join-Path $sourceDir 'empty.log'
        [IO.File]::WriteAllText($rotated,"[11:59:59] [main/INFO]: rotated`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($source,"[12:00:00] [main/INFO]: first`n[12:00:01] [main/INFO]: tail",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($empty,'',[Text.UTF8Encoding]::new($false))
        @([pscustomobject]@{PID=21;Role='Client';Username='Iris';LogPath=$source})|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $session 'pids.json') -Encoding utf8
        $first=Import-MmtlSessionLogs -SessionPath $session
        @($first.importedLines).Count | Should -Be 2
        [IO.File]::AppendAllText($source,"`n[12:00:02] [main/INFO]: second`n",[Text.UTF8Encoding]::new($false))
        $second=Import-MmtlSessionLogs -SessionPath $session
        @($second.importedLines).Count | Should -Be 2
        $all=@(Get-ChildItem (Join-Path $session 'logs/structured') -File|ForEach-Object{Get-Content $_.FullName|ForEach-Object{$_|ConvertFrom-Json}})
        $all.message | Should -Contain 'rotated';$all.message | Should -Contain 'first';$all.message | Should -Contain 'tail';$all.message | Should -Contain 'second'
        @($all|Where-Object message -eq 'first').Count | Should -Be 1
    }
}
