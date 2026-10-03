Set-StrictMode -Version Latest

function Get-MmtlCoverageCliOptionDefinitions {
    [CmdletBinding()]
    param()
    @(
        [pscustomobject]@{name='--coverage-report';usage='--coverage-report [--json]';description='显示全部正式版覆盖摘要；--json 输出完整报告。'}
        [pscustomobject]@{name='--coverage-gaps';usage='--coverage-gaps';description='显示尚未解决的不变量与提供器缺口。'}
        [pscustomobject]@{name='--coverage-version';usage='--coverage-version <id>';description='显示指定 Minecraft 正式版本的覆盖情况。'}
    )
}

function Invoke-MmtlCoverageCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [switch]$CatalogOffline,
        [switch]$LoaderOffline,
        [switch]$ForceRefresh,
        [scriptblock]$AuditFactory
    )
    $commands=@('--coverage-report','--coverage-gaps','--coverage-version')
    $selected=@($commands|Where-Object{$Arguments -ccontains $_})
    if($selected.Count -gt 1){throw 'COVERAGE_OPTION_CONFLICT: 只能指定一个覆盖率命令。'}
    if(-not $selected.Count){return}
    $command=$selected[0]
    $json=$Arguments -ccontains '--json'
    if($json -and $command -ne '--coverage-report'){throw 'COVERAGE_JSON_OPTION_INVALID: --json 只能与 --coverage-report 一起使用。'}
    if($CatalogOffline -and $ForceRefresh){throw 'CATALOG_OPTION_CONFLICT: --refresh-catalog 不能与 --catalog-offline 同时使用。'}
    $minecraftId=$null
    if($command -eq '--coverage-version'){
        $index=[Array]::IndexOf($Arguments,'--coverage-version')
        if($index+1 -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace([string]$Arguments[$index+1])){throw '--coverage-version 缺少 Minecraft 正式版本 ID。'}
        $minecraftId=[string]$Arguments[$index+1]
    }
    if(-not $AuditFactory){$AuditFactory={param($RuntimeRoot,$CatalogOffline,$LoaderOffline,$ForceRefresh)New-MmtlLiveCoverageAudit -RuntimeRoot $RuntimeRoot -CatalogOffline:$CatalogOffline -LoaderOffline:$LoaderOffline -ForceRefresh:$ForceRefresh}}
    $audit=& $AuditFactory $RuntimeRoot $CatalogOffline.IsPresent $LoaderOffline.IsPresent $ForceRefresh.IsPresent
    if($command -eq '--coverage-report'){
        if($json){$audit|ConvertTo-Json -Depth 60;return}
        $summary=[pscustomobject]@{minecraftCatalog=$audit.minecraftCatalog;coverageStatus=$audit.summary.coverageStatus;stateCounts=$audit.summary.stateCounts;perLoader=$audit.summary.perLoader;providerStatusCounts=$audit.summary.providerStatusCounts;validationLevels=$audit.summary.validationLevels;gapCount=@($audit.gaps).Count;warningCount=@($audit.warnings).Count}
        $summary|ConvertTo-Json -Depth 20;return
    }
    if($command -eq '--coverage-gaps'){
        @($audit.gaps)|ConvertTo-Json -Depth 30;return
    }
    Get-MmtlCoverageVersion -Audit $audit -MinecraftId $minecraftId|ConvertTo-Json -Depth 40
}

Export-ModuleMember -Function Get-MmtlCoverageCliOptionDefinitions,Invoke-MmtlCoverageCli
