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
        $sourceRoots = @('common/src','windows/src','linux/src','macos/src') | ForEach-Object { Join-Path $script:repositoryRoot $_ }
        foreach ($sourceRoot in $sourceRoots) {
            if (-not (Test-Path -LiteralPath $sourceRoot)) { continue }
            foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Include *.ps1,*.psm1) {
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
    }
}
