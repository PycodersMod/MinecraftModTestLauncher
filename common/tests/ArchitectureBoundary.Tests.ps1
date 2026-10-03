Describe '严格跨平台目录边界' {
    BeforeAll { $script:commonRoot = Split-Path -Parent $PSScriptRoot; $script:repositoryRoot = Split-Path -Parent $script:commonRoot }

    It '根目录不得包含业务代码目录与启动实现' {
        foreach ($name in @('src','tests','schemas','fixtures','launcher.ps1','launcher.cmd','launcher.sh')) {
            Test-Path -LiteralPath (Join-Path $script:repositoryRoot $name) | Should -BeFalse -Because "根目录不应包含 $name"
        }
    }

    It '必须提供四个目标层并保留仓库文档和 GitHub 配置' {
        foreach ($name in @('common','windows','linux','macos','docs','.github')) {
            Test-Path -LiteralPath (Join-Path $script:repositoryRoot $name) | Should -BeTrue
        }
    }

    It 'common 和各平台不得跨越允许的依赖方向' {
        $sourceFiles = foreach ($sourceRoot in @('common/src','windows/src','linux/src','macos/src')) {
            Get-ChildItem -LiteralPath (Join-Path $script:repositoryRoot $sourceRoot) -Recurse -File -Include *.ps1,*.psm1,*.sh,*.cmd
        }
        $sourceFiles += Get-Item -LiteralPath (Join-Path $script:repositoryRoot 'common/launcher-posix.sh')
        foreach ($file in $sourceFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            if ($file.FullName -match '[\\/]common[\\/]') {
                $content | Should -Not -Match '(?i)(windows|linux|macos)[\\/](src|launcher)'
            } elseif ($file.FullName -match '[\\/]windows[\\/]') {
                $content | Should -Not -Match '(?i)(linux|macos)[\\/](src|launcher)'
            } elseif ($file.FullName -match '[\\/]linux[\\/]') {
                $content | Should -Not -Match '(?i)(windows|macos)[\\/](src|launcher)'
            } elseif ($file.FullName -match '[\\/]macos[\\/]') {
                $content | Should -Not -Match '(?i)(windows|linux)[\\/](src|launcher)'
            }
        }
    }

    It '不会在不同平台目录复制相同的业务源码' {
        $files = foreach ($platform in @('windows','linux','macos')) {
            $sourceRoot = Join-Path $script:repositoryRoot $platform
            Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Include *.ps1,*.psm1,*.sh,*.cmd |
                Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' }
        }
        $duplicates = @($files | Get-FileHash -Algorithm SHA256 | Group-Object Hash | Where-Object { $_.Count -gt 1 })
        $duplicates | Should -BeNullOrEmpty
    }
}
