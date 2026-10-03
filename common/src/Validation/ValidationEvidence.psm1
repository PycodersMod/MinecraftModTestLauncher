Set-StrictMode -Version Latest

function ConvertTo-MmtlRedactedValidationText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $redacted = $Text
    $redacted = [regex]::Replace($redacted, '(?i)\bgh[pousr]_[A-Za-z0-9_]{20,}', '[REDACTED_GITHUB_TOKEN]')
    $redacted = [regex]::Replace($redacted, '(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]{12,}', '$1[REDACTED]')
    $redacted = [regex]::Replace($redacted, '(?i)(https?://)[^/@\s:]+:[^/@\s]+@', '$1[REDACTED]@')
    $redacted = [regex]::Replace($redacted, '(?i)\b(token|password|client_secret|access_token)\s*([:=])\s*[^\s,;]+', '$1$2[REDACTED]')
    return $redacted
}

function Write-MmtlValidationRunEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)]$Evidence)

    $targetId = [string]$Evidence.targetId
    $runId = [string]$Evidence.runId
    if ($targetId -notmatch '^[a-z0-9][a-z0-9._-]{2,127}$' -or $runId -notmatch '^[A-Za-z0-9._-]{1,80}$') {
        throw '证据目标或运行标识不安全。'
    }

    $root = [IO.Path]::GetFullPath($RuntimeRoot)
    $validationRoot = [IO.Path]::GetFullPath((Join-Path $root 'validation'))
    $prefix = $validationRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $runDirectory = [IO.Path]::GetFullPath((Join-Path $validationRoot (Join-Path $targetId $runId)))
    if (-not $runDirectory.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '证据目标目录越出了 Runtime Root。' }

    $evidencePath = Join-Path $runDirectory 'result.json'
    if (Test-Path -LiteralPath $evidencePath) { throw '已完成的运行证据不可更改；请创建新的 runId。' }
    $schemaPath = Join-Path $PSScriptRoot '..\..\schemas\validation-evidence.schema.json'
    $json = $Evidence | ConvertTo-Json -Depth 40
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw '验证运行证据不符合不可变证据 Schema。' }

    [void][IO.Directory]::CreateDirectory($runDirectory)
    $temporaryPath = Join-Path $runDirectory ('.result-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $evidencePath)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
    return $evidencePath
}

Export-ModuleMember -Function ConvertTo-MmtlRedactedValidationText, Write-MmtlValidationRunEvidence
