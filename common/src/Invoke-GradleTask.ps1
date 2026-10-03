param([Parameter(Mandatory)][string]$LaunchPlanB64)
$ErrorActionPreference='Stop'
$exitCode=1
$failure=$null
$plan=$null
try{
    $json=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LaunchPlanB64))
    $plan=$json|ConvertFrom-Json -ErrorAction Stop
    $root=[IO.Path]::GetFullPath([string]$plan.projectRoot)
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    $platform=Get-MmtlPlatformProvider
    $wrapper=Join-Path $root $platform.GradleWrapper
    if(-not(Test-Path -LiteralPath $wrapper -PathType Leaf)){throw "项目缺少 Gradle Wrapper：$wrapper"}
    Push-Location -LiteralPath $root
    try{
        $gradleArgs=[string[]]$plan.arguments
        if($platform.OS -eq 'Windows'){& $wrapper @gradleArgs}
        else{
            $mode=(Get-Item -LiteralPath $wrapper).UnixFileMode
            if(($mode -band [IO.UnixFileMode]::UserExecute) -eq 0 -and ($mode -band [IO.UnixFileMode]::GroupExecute) -eq 0 -and ($mode -band [IO.UnixFileMode]::OtherExecute) -eq 0){& sh $wrapper @gradleArgs}
            else{& (Join-Path '.' $platform.GradleWrapper) @gradleArgs}
        }
        $exitCode=$LASTEXITCODE
    }finally{Pop-Location}
}catch{
    [Console]::Error.WriteLine($_.Exception.Message)
    $failure=$_.Exception.Message
    $exitCode=1
}finally{
    if($plan -and $plan.runtimeLinkPath){
        try{
            $root=[IO.Path]::GetFullPath([string]$plan.projectRoot);$link=[IO.Path]::GetFullPath([string]$plan.runtimeLinkPath);$target=[IO.Path]::GetFullPath([string]$plan.runtimeTargetPath)
            $prefix=$root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $link.StartsWith($prefix,$platform.PathComparison)){throw 'Fabric Runtime link 越出项目目录。'}
            if($platform.OS -ne 'Windows'){throw '当前平台不支持清理 Fabric Runtime 链接。'}
            if(Test-Path -LiteralPath $link){
                $item=Get-Item -LiteralPath $link -Force
                if(-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -ne 'Junction' -or [IO.Path]::GetFullPath([string]@($item.Target)[0]) -ne $target){throw 'Fabric Runtime junction 身份不符，拒绝清理。'}
                Remove-Item -LiteralPath $link -Force
            }
        }catch{[Console]::Error.WriteLine("无法清理 Fabric Runtime junction：$($_.Exception.Message)");if($exitCode -eq 0){$exitCode=1}}
    }
    if($plan -and $plan.sessionPath){
        try{$statusPath=Join-Path ([IO.Path]::GetFullPath([string]$plan.sessionPath)) "process-$PID.exit.json";$record=[pscustomobject]@{PID=$PID;ExitCode=$exitCode;FinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');Error=$failure};[IO.File]::WriteAllText($statusPath,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}catch{[Console]::Error.WriteLine("无法写入 Session 退出状态：$($_.Exception.Message)")}
    }
}
exit $exitCode
