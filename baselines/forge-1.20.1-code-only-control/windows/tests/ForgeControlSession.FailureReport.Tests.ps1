BeforeAll {
    $script:repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repositoryRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
    $script:sessionModule = Import-Module (Join-Path $script:repositoryRoot 'windows/src/ForgeControl/ForgeControlSession.psm1') -Force -PassThru
}

Describe 'Forge Control startup failure reporting' {
    It 'captures a Java-style stderr version banner without treating it as a terminating error' {
        InModuleScope $script:sessionModule.Name {
            $capture = Invoke-MmtlForgeProcessCapture -ExecutablePath $env:ComSpec -Arguments '/d /c echo java version "17.0.19" 1>&2'
            $capture.exitCode | Should -Be 0
            ($capture.standardError + $capture.standardOutput) | Should -Match 'java version "17\.0\.19"'
        }
    }

    It 'labels an authenticated Guest login disconnect as a world-entry failure' {
        InModuleScope $script:sessionModule.Name {
            Mock Wait-MmtlAgentClientReady { [pscustomobject]@{ready=$true} }
            Mock Wait-MmtlAgentWorldJoined { throw 'GUEST_LOGIN_DISCONNECTED: Guest login disconnected: Timed out' }
            $client=[pscustomobject]@{eventPath='guest.jsonl';playerName='Dev_1';processId=51002;processIdentity='test-start';state='Starting'}
            try {
                Wait-MmtlForgeAgentClient -Client $client -SessionPath (Join-Path $TestDrive 'session') -SessionId 'session_a' -NonceHash ('a'*64) -Role Guest
                throw 'EXPECTED_FAILURE_NOT_THROWN'
            } catch {
                $_.Exception.Message | Should -Match 'GUEST_LOGIN_DISCONNECTED'
                $_.Exception.Data['mmtlFailureStage'] | Should -BeExactly 'waiting-guest-world:Dev_1'
            }
        }
    }

    It 'retains the original failure, partial LAN assertions, stop outcomes and copies JSON plus Markdown' {
        $fixtureRoot = Join-Path $TestDrive 'failure-report'
        InModuleScope $script:sessionModule.Name -Parameters @{ FixtureRoot = $fixtureRoot } {
            Mock Get-MmtlForgeAvailableMemoryMb { 24000 }
            Mock Invoke-MmtlForgeProcessCapture { [pscustomobject]@{exitCode=0;standardOutput='';standardError='java version "17.0.19"'} }
            Mock Register-MmtlWindowsPlatform {}
            Mock Get-MmtlAgentProviderStatus { [pscustomobject]@{ status = 'Supported' } }
            Mock Get-MmtlForgeLoopbackPort { 25432 }
            Mock New-MmtlSession {
                param($RuntimeRoot, $Name, $Metadata)
                $sessionId = 'session-failure-001'
                $sessionPath = Join-Path $FixtureRoot "sessions/$sessionId"
                New-Item -ItemType Directory -Path (Join-Path $sessionPath 'agent-events') -Force | Out-Null
                $record = [pscustomobject]@{
                    sessionId = $sessionId
                    testIdentities = @(
                        [pscustomobject]@{ username = 'Dev'; processIdentity = $null },
                        [pscustomobject]@{ username = 'Dev_1'; processIdentity = $null }
                    )
                }
                [IO.File]::WriteAllText((Join-Path $sessionPath 'session.json'), ($record | ConvertTo-Json -Depth 10))
                [IO.File]::WriteAllText((Join-Path $sessionPath 'pids.json'), '[]')
                return $sessionPath
            }
            Mock Start-MmtlForgeControlClient {
                param($Config, $SessionPath, $SessionId, $SessionToken, $ProviderRoot, $Role, $PlayerName, $LanPort, $GuestPort)
                $pidValue = if ($Role -eq 'Host') { 51001 } else { 51002 }
                $identity = "test-process-$pidValue"
                $eventName = if ($Role -eq 'Host') { 'host-host-00.jsonl' } else { 'guest-guest-01.jsonl' }
                $eventPath = Join-Path $SessionPath "agent-events/$eventName"
                $nonceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SessionToken))).ToLowerInvariant()
                $records = [Collections.Generic.List[string]]::new()
                $types = if ($Role -eq 'Host') { @('AGENT_STARTED','CLIENT_READY','WORLD_JOINED','LAN_PUBLISHED','PLAYER_JOINED') } else { @('AGENT_STARTED','GUEST_CONNECTING') }
                foreach ($type in $types) {
                    $event = [ordered]@{
                        schemaVersion = 1; sessionId = $SessionId; role = $Role; eventId = [guid]::NewGuid().ToString()
                        eventType = $type; timestampUtc = [DateTimeOffset]::UtcNow.ToString('o'); sessionNonceHash = $nonceHash; summary = $type
                    }
                    if ($type -eq 'LAN_PUBLISHED') { $event.port = $LanPort; $event.bindAddress = '127.0.0.1' }
                    if ($type -eq 'PLAYER_JOINED') { $event.playerName = 'Dev' }
                    $records.Add(($event | ConvertTo-Json -Compress))
                }
                [IO.File]::WriteAllLines($eventPath, $records, [Text.UTF8Encoding]::new($false))
                $registryPath = Join-Path $SessionPath 'pids.json'
                $registry = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json)
                $registry += [pscustomobject]@{
                    PID = $pidValue; Role = $Role; Username = $PlayerName; StartIdentity = $identity
                    LogPath = (Join-Path $SessionPath "logs/$Role-$PlayerName.stdout.log")
                    WorkingDirectory = (Join-Path $SessionPath $PlayerName); CommandLine = "java -Dmmtl.agent.eventSink=$eventPath"
                    StatePath = (Join-Path $SessionPath "process-$pidValue.exit.json")
                }
                [IO.File]::WriteAllText($registryPath, ($registry | ConvertTo-Json -Depth 8))
                return [pscustomobject]@{
                    instanceId = "$Role-$PlayerName"; processId = $pidValue; processIdentity = $identity
                    playerName = $PlayerName; role = $Role; eventPath = $eventPath
                    logPath = (Join-Path $SessionPath "logs/$Role-$PlayerName.stdout.log")
                    gameDirectory = (Join-Path $SessionPath $PlayerName); state = 'Starting'
                }
            }
            Mock Wait-MmtlForgeAgentClient {
                param($Client, $SessionPath, $SessionId, $NonceHash, $Role)
                if ($Role -eq 'Guest') { throw [IO.IOException]::new('The process cannot access guest event JSONL because it is being used by another process.') }
                $Client.state = 'WorldJoined'
            }
            Mock Wait-MmtlAgentIntegratedLanReady {
                [pscustomobject]@{ ready = $true; port = 25432; bindAddress = '127.0.0.1' }
            }
            Mock Stop-MmtlForgeClient {
                param($SessionPath, $Client, $TimeoutSeconds)
                [pscustomobject]@{ processId = $Client.processId; stopped = $true; graceful = $true; method = 'TestStop' }
            }

            New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $FixtureRoot 'java.exe'),'fixture')

            $config = [pscustomobject]@{
                javaPath = (Join-Path $FixtureRoot 'java.exe'); memoryMb = 1024; clientCount = 2
                players = @('Dev','Dev_1'); configPath = 'profile.json'; target = [pscustomobject]@{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
                worldName = 'MMTL-Test'; lanEnabled = $true; runtimeRoot = $FixtureRoot; reportRoot = (Join-Path $FixtureRoot 'reports')
            }

            { Start-MmtlForgeControlSession -Config $config } | Should -Throw '*cannot access guest event JSONL*'
            $sessionPath = Join-Path $FixtureRoot 'sessions/session-failure-001'
            $reportPath = Join-Path $FixtureRoot 'reports/session-failure-001.json'
            $markdownPath = Join-Path $FixtureRoot 'reports/session-failure-001.md'
            Test-Path -LiteralPath $reportPath | Should -BeTrue
            Test-Path -LiteralPath $markdownPath | Should -BeTrue
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $report.failureStage | Should -BeExactly 'waiting-guest-ready:Dev_1'
            $report.originalError.message | Should -Match 'cannot access guest event JSONL'
            $report.processes.Count | Should -Be 2
            $report.gameAssertions.integratedLan | Should -BeTrue
            $report.gameAssertions.hostObservedPlayers | Should -Contain 'Dev'
            $report.stopResults.Count | Should -Be 2
            $report.stopResults | Where-Object { -not $_.stopped } | Should -BeNullOrEmpty
            $report.processes | Where-Object { -not $_.minecraftLogPath -or -not $_.eventPath } | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $markdownPath -Raw) | Should -Match 'waiting-guest-ready:Dev_1'
            (Get-Content -LiteralPath $markdownPath -Raw) | Should -Match '安全停止结果'
            $sessionRecord = Get-Content -LiteralPath (Join-Path $sessionPath 'session.json') -Raw | ConvertFrom-Json
            $sessionRecord.status | Should -BeExactly 'Failed'
            $sessionRecord.processes.Count | Should -Be 2
        }
    }
}
