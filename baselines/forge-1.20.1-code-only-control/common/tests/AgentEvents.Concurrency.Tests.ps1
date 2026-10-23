BeforeAll {
    $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repositoryRoot 'src/Agent/AgentEvents.psm1') -Force
}

Describe 'Agent JSONL 并发读写' {
    It '在 Windows 写句柄保持打开时读取完整行，并忽略尚未写完的尾行' {
        $path = Join-Path $TestDrive 'guest.jsonl'
        $line = [ordered]@{
            schemaVersion = 1; sessionId = 'session_a'; role = 'Guest'; eventId = 'guest-01-event-1'
            eventType = 'AGENT_STARTED'; timestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
            sessionNonceHash = 'a' * 64; summary = 'writer is active'
        } | ConvertTo-Json -Compress
        $writer = [IO.FileStream]::new($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $streamWriter = [IO.StreamWriter]::new($writer, [Text.UTF8Encoding]::new($false), 1024, $true)
        try {
            $streamWriter.Write($line.Substring(0, 30))
            $streamWriter.Flush()
            { [IO.File]::ReadAllLines($path) } | Should -Throw

            $snapshot = Get-MmtlAgentEventSnapshot -Path $path
            @($snapshot.lines).Count | Should -Be 0

            $streamWriter.WriteLine($line.Substring(30))
            $streamWriter.Flush()
            $snapshot = Get-MmtlAgentEventSnapshot -Path $path
            $snapshot.lines.Count | Should -Be 1
            ($snapshot.lines[0] | ConvertFrom-Json).eventId | Should -BeExactly 'guest-01-event-1'
        }
        finally {
            $streamWriter.Dispose()
            $writer.Dispose()
        }
    }

    It '三个 Guest 并发追加时高频读取各自流并保留独立身份' {
        $sessionPath = Join-Path $TestDrive 'session_a'
        $eventRoot = Join-Path $sessionPath 'agent-events'
        New-Item -ItemType Directory -Path $eventRoot -Force | Out-Null
        $nonceHashes = @(('1' * 64), ('2' * 64), ('3' * 64))
        $eventPaths = @(0..2 | ForEach-Object { Join-Path $eventRoot ("guest-{0:D2}.jsonl" -f ($_ + 1)) })
        foreach ($path in $eventPaths) { [IO.File]::WriteAllText($path, '') }
        $jobs = @()
        try {
            for ($index = 0; $index -lt 3; $index++) {
                $jobs += Start-Job -ArgumentList $eventPaths[$index], $nonceHashes[$index], $index -ScriptBlock {
                    param($Path, $NonceHash, $Index)
                    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 1024, $true)
                    try {
                        for ($eventIndex = 0; $eventIndex -lt 160; $eventIndex++) {
                            $type = if ($eventIndex -eq 159) { 'GUEST_CONNECTED' } else { 'GUEST_CONNECTING' }
                            $event = [ordered]@{
                                schemaVersion = 1; sessionId = 'session_a'; role = 'Guest'
                                eventId = "guest-$Index-event-$eventIndex"; eventType = $type
                                timestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
                                sessionNonceHash = $NonceHash; summary = "guest-$Index event $eventIndex"; port = 25565
                            }
                            $writer.WriteLine(($event | ConvertTo-Json -Compress))
                            $writer.Flush()
                            [Threading.Thread]::Sleep(1)
                        }
                    }
                    finally { $writer.Dispose(); $stream.Dispose() }
                }
            }

            $readCounts = @(0, 0, 0)
            do {
                for ($index = 0; $index -lt 3; $index++) {
                    $snapshot = Get-MmtlAgentEventSnapshot -Path $eventPaths[$index]
                    $snapshot.success | Should -BeTrue
                    foreach ($line in $snapshot.lines) {
                        $event = $line | ConvertFrom-Json -ErrorAction Stop
                        $event.sessionId | Should -BeExactly 'session_a'
                        $event.role | Should -BeExactly 'Guest'
                        $event.sessionNonceHash | Should -BeExactly $nonceHashes[$index]
                        if ($event.eventType -ceq 'GUEST_CONNECTED') { $readCounts[$index]++ }
                    }
                }
                Start-Sleep -Milliseconds 2
                $running = @($jobs | Where-Object State -eq 'Running').Count -gt 0
            } while ($running)

            $jobs | Wait-Job | Out-Null
            foreach ($job in $jobs) { Receive-Job -Job $job -ErrorAction Stop | Out-Null }
            for ($index = 0; $index -lt 3; $index++) {
                $snapshot = Get-MmtlAgentEventSnapshot -Path $eventPaths[$index]
                $events = @($snapshot.lines | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
                $events.Count | Should -Be 160
                $events[-1].eventType | Should -BeExactly 'GUEST_CONNECTED'
                $events[-1].eventId | Should -BeExactly "guest-$index-event-159"
                $events[-1].sessionNonceHash | Should -BeExactly $nonceHashes[$index]
            }
        }
        finally {
            if ($jobs.Count) { $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }
        }
    }
}
