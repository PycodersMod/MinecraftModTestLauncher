BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/WindowLayout.psm1') -Force
    $script:originalProvider=$global:MmtlPlatformProvider
}

Describe '窗口布局纯计算预演' {
    BeforeEach {
        $global:MmtlPlatformProvider=[pscustomobject]@{OS='Windows';Arch='x64';PathComparison=[StringComparison]::OrdinalIgnoreCase;DefaultRuntimeRoot=$TestDrive;JavaExecutable='java.exe';JavacExecutable='javac.exe';GradleWrapper='gradlew.bat';WindowManagement='Native';ProcessManagement='Native';FabricRuntimeLink='Native'}
    }
    AfterEach { $global:MmtlPlatformProvider=$script:originalProvider }

    It 'Tile 计算完整、无重叠且不越过屏幕边界' {
        $rectangles=Get-MmtlTileRectangles -Count 5 -ScreenWidth 1920 -ScreenHeight 1080
        $rectangles.Count | Should -Be 5
        foreach($rect in $rectangles){$rect.X | Should -BeGreaterOrEqual 0;$rect.Y | Should -BeGreaterOrEqual 0;($rect.X+$rect.Width) | Should -BeLessOrEqual 1920;($rect.Y+$rect.Height) | Should -BeLessOrEqual 1080}
        for($i=0;$i -lt $rectangles.Count;$i++){for($j=$i+1;$j -lt $rectangles.Count;$j++){$a=$rectangles[$i];$b=$rectangles[$j];$overlap=($a.X -lt ($b.X+$b.Width)) -and (($a.X+$a.Width) -gt $b.X) -and ($a.Y -lt ($b.Y+$b.Height)) -and (($a.Y+$a.Height) -gt $b.Y);$overlap | Should -BeFalse}}
    }

    It 'Cascade 与 Auto 返回有界窗口位置，None 明确跳过' {
        $cascade=Get-MmtlCascadeRectangles -Count 4 -ScreenWidth 1920 -ScreenHeight 1080
        $cascade.Count | Should -Be 4
        foreach($rect in $cascade){$rect.X | Should -BeGreaterOrEqual 0;$rect.Y | Should -BeGreaterOrEqual 0;($rect.X+$rect.Width) | Should -BeLessOrEqual 1920;($rect.Y+$rect.Height) | Should -BeLessOrEqual 1080}
        (Get-MmtlWindowLayout -Mode Auto) | Should -Be 'Available'
        (Get-MmtlWindowLayout -Mode None) | Should -Be 'None'
        $autoRects=Get-MmtlTileRectangles -Count 3 -ScreenWidth 1600 -ScreenHeight 900
        $autoRects.Count | Should -Be 3
    }
}
