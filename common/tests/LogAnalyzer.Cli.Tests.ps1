BeforeAll {
    $script:pwsh=(Get-Command pwsh -ErrorAction Stop).Source
    $script:launcher=$env:MMTL_PLATFORM_ENTRYPOINT
}

Describe 'Session analysis CLI' {
    It 'emits only valid JSON and writes a report without exposing project paths' {
        if(-not $script:launcher -or -not(Test-Path $script:launcher)){Set-ItResult -Skipped -Because 'Use the repository platform-aware Pester entrypoint';return}
        $runtime=Join-Path $TestDrive 'runtime';$sessionId='20261006T150000Z_analyzer';$session=Join-Path (Join-Path $runtime 'sessions') $sessionId
        $project=Join-Path $TestDrive 'anonymous-project';New-Item -ItemType Directory -Path (Join-Path $project 'src/main/resources') -Force|Out-Null
        Set-Content (Join-Path $project 'build.gradle') '// fixture';Set-Content (Join-Path $project 'gradle.properties') "minecraft_version=1.20.1`nforge_version=47.2.0`nmod_id=fixturemod`njava_version=17"
        [IO.File]::WriteAllText((Join-Path $project 'src/main/resources/fabric.mod.json'),'{"schemaVersion":1,"id":"fixturemod","version":"1","name":"Fixture","entrypoints":{"main":["org.example.fixture.FixtureMod"]}}',[Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Path (Join-Path $session 'logs/structured') -Force|Out-Null
        $manifest=[ordered]@{sessionId=$sessionId;state='Stopped';metadata=[ordered]@{project=$project;loader='Fabric';minecraft='1.20.1';mode='Single'}}
        [IO.File]::WriteAllText((Join-Path $session 'session.json'),($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $record=[ordered]@{sessionId=$sessionId;role='Client';identity='MMTL_C01';sourceFile='logs/client.log';sourceTimestamp='12:00:00';observedAtUtc='2026-10-06T07:00:00Z';level='ERROR';logger='';message='java.lang.NullPointerException: sample';schemaVersion=1}
        $frame=[ordered]@{sessionId=$sessionId;role='Client';identity='MMTL_C01';sourceFile='logs/client.log';sourceTimestamp=$null;observedAtUtc='2026-10-06T07:00:01Z';level='UNKNOWN';logger='';message='    at org.example.fixture.Renderer.render(Renderer.java:5)';schemaVersion=1}
        [IO.File]::WriteAllText((Join-Path $session 'logs/structured/Client-MMTL_C01.jsonl'),(($record|ConvertTo-Json -Compress)+"`n"+($frame|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $config=Join-Path $TestDrive 'launcher.config.json';[IO.File]::WriteAllText($config,(@{configVersion=2;runtimeRoot=$runtime;javaHomes=@{};defaultProfile='fixture';profiles=@{fixture=@{project=$project}}}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $config --analyze-session $sessionId --json 2>&1|Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $json=$output|ConvertFrom-Json -ErrorAction Stop
        $json.findingCount | Should -Be 1;$json.findings[0].attribution | Should -Be 'Direct'
        $output | Should -Not -Match ([regex]::Escape($project))
        Test-Path (Join-Path $session 'analysis/summary.md') | Should -BeTrue
        $report=& $script:pwsh -NoProfile -File $script:launcher --config-file $config --session-report $sessionId --json 2>$null|Out-String
        $LASTEXITCODE | Should -Be 0
        $reportJson=$report|ConvertFrom-Json -ErrorAction Stop
        $reportJson.markdown | Should -Match 'MMTL 测试会话分析'
        $report | Should -Not -Match ([regex]::Escape($project))
    }
}
