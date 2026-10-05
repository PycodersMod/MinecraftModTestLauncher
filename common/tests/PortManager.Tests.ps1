BeforeAll {
    $script:portModule=Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PortManager.psm1'
    Import-Module $script:portModule -Force
}

Describe 'loopback 端口分配与竞态重试' {
    It '消费端报告绑定冲突时自动分配重新选择，固定端口不擅自改号' {
        $state=[hashtable]::Synchronized(@{blocker=$null})
        $action={param($port,$attempt)
            if($attempt -eq 1){$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);$listener.Start();$state.blocker=$listener;throw 'PORT_BIND_CONFLICT: 模拟端口在探测后被占用。'}
            return [pscustomobject]@{accepted=$true;attempt=$attempt}
        }.GetNewClosure()
        try {
            $result=Invoke-MmtlPortAllocation -OnAllocated $action -MaximumAttempts 4
            $result.Attempts | Should -Be 2
            $result.Port | Should -Not -Be $state.blocker.LocalEndpoint.Port
            $result.Value.accepted | Should -BeTrue
            $fixedPort=Get-MmtlPort
            { Invoke-MmtlPortAllocation -Port $fixedPort -OnAllocated {param($candidate,$attempt) throw 'PORT_BIND_CONFLICT: 固定端口冲突'} } | Should -Throw '*PORT_BIND_CONFLICT*'
        } finally {if($state.blocker){$state.blocker.Stop()}}
    }

    It 'Dedicated 日志中的 bind failure 提供稳定 PORT_BIND_CONFLICT 分类' {
        $log=Join-Path $TestDrive 'dedicated-bind-failure.log'
        '**** FAILED TO BIND TO PORT!' | Set-Content -LiteralPath $log
        { Wait-MmtlDedicatedReady -Path $log -TimeoutSeconds 1 -PollMilliseconds 50 } | Should -Throw '*PORT_BIND_CONFLICT*'
    }

    It '多个并发 Session 持有自动分配端口时不冲突并全部释放' {
        $barrier=Join-Path $TestDrive 'port-barrier';New-Item -ItemType Directory -Path $barrier -Force|Out-Null
        $workers=8;$module=$script:portModule
        $jobs=1..$workers|ForEach-Object{Start-Job -ArgumentList $module,$barrier,$workers,$_ -ScriptBlock {
            param($modulePath,$barrierPath,$workerCount,$workerId)
            Import-Module $modulePath -Force
            $ready=Join-Path $barrierPath "ready-$workerId";[IO.File]::WriteAllText($ready,'ready')
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while(@(Get-ChildItem -LiteralPath $barrierPath -Filter 'ready-*').Count -lt $workerCount){if([DateTime]::UtcNow -ge $deadline){throw 'PORT_TEST_BARRIER_TIMEOUT'};Start-Sleep -Milliseconds 20}
            $keepers=[Collections.Generic.List[object]]::new();$ports=[Collections.Generic.List[int]]::new()
            try {
                for($index=0;$index -lt 4;$index++){
                    $action={param($candidate,$attempt)
                        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$candidate)
                        try{$listener.Start()}catch{$listener.Stop();throw 'PORT_BIND_CONFLICT: 并发 Session 已占用候选端口。'}
                        $keepers.Add($listener);return $candidate
                    }.GetNewClosure()
                    $allocation=Invoke-MmtlPortAllocation -OnAllocated $action -MaximumAttempts 8
                    $ports.Add([int]$allocation.Port)
                }
                [IO.File]::WriteAllText((Join-Path $barrierPath "finished-$workerId"),'done')
                while(@(Get-ChildItem -LiteralPath $barrierPath -Filter 'finished-*').Count -lt $workerCount){if([DateTime]::UtcNow -ge $deadline){throw 'PORT_TEST_RELEASE_BARRIER_TIMEOUT'};Start-Sleep -Milliseconds 20}
                return ,@($ports.ToArray())
            } finally {foreach($listener in $keepers){$listener.Stop()}}
        }}
        try {
            $results=@(Receive-Job -Job $jobs -Wait -AutoRemoveJob -ErrorAction Stop)
            $ports=@($results|ForEach-Object{@($_)})
            $ports.Count | Should -Be ($workers*4)
            @($ports|Where-Object{$_ -lt 1 -or $_ -gt 65535}).Count | Should -Be 0
            @($ports|Select-Object -Unique).Count | Should -Be $ports.Count
            foreach($port in $ports){$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,[int]$port);try{$listener.Start()}finally{$listener.Stop()}}
        } finally {$jobs|Remove-Job -Force -ErrorAction SilentlyContinue}
    }
}
