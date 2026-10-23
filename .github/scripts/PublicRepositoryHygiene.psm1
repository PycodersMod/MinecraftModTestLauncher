Set-StrictMode -Version Latest

$script:PathFindingCodes = @(
    'WINDOWS_ABSOLUTE_PATH',
    'WINDOWS_UNC_PATH',
    'LINUX_HOME_PATH',
    'MACOS_HOME_PATH',
    'LOCAL_CACHE_RUNTIME_PATH',
    'LOCAL_PROXY_ENDPOINT'
)

function Get-MmtlPublicHygieneIdentityCandidates {
    [CmdletBinding()]
    param(
        [string[]]$SensitiveIdentities = @(),
        [string]$EnvironmentUserName = [Environment]::UserName,
        [string]$MachineName = [Environment]::MachineName,
        [string]$UserProfile = $env:USERPROFILE,
        [switch]$GitHubActions
    )

    $automatic = @($EnvironmentUserName, $MachineName)
    if ($UserProfile) {
        $automatic += [IO.Path]::GetFileName($UserProfile.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    }
    if ($GitHubActions) {
        $genericRunnerIdentities = @('runner', 'runneradmin', 'github-actions', 'github-actions[bot]')
        $automatic = @($automatic | Where-Object { $_ -and $_.ToLowerInvariant() -notin $genericRunnerIdentities })
    }

    @($SensitiveIdentities + $automatic | Where-Object { $_ -and $_.Trim().Length -ge 4 } | Sort-Object -Unique)
}

function Get-MmtlPublicHygieneContentFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$RelativePath,
        [string[]]$SensitiveIdentities = @()
    )

    $cacheNames = @(
        (@('mmtl','temp') -join '-'),
        (@('mmtl','gradle','home') -join '-'),
        (@('mmtl','cleanup','staging') -join '-'),
        (@('mmtl','forge','control','runtime') -join '-')
    )
    $cachePattern = '(?i)(?:^|[\\/])(?:' + (($cacheNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?:[\\/]|$)'
    $rules = @(
        [pscustomobject]@{ Code='WINDOWS_ABSOLUTE_PATH'; Pattern='(?i)(?<![\p{L}\p{N}])[A-Z]:\\[^\s"''<>|?*]+' },
        [pscustomobject]@{ Code='WINDOWS_UNC_PATH'; Pattern='(?i)(?<![A-Za-z0-9:/])(?:\\\\|//)[^\\/\s"''<>|]+(?:\\|/)[^\\/\s"''<>|]+' }, # public-hygiene: allow-generic-platform-location
        [pscustomobject]@{ Code='LINUX_HOME_PATH'; Pattern='(?<![\p{L}\p{N}])/(?:home)/(?!(?:<[^>]+>)(?:/|$))[^/\s"''<>]+' },
        [pscustomobject]@{ Code='MACOS_HOME_PATH'; Pattern='(?<![\p{L}\p{N}])/(?:Users)/(?!(?:<[^>]+>)(?:/|$))[^/\s"''<>]+' },
        [pscustomobject]@{ Code='LOCAL_CACHE_RUNTIME_PATH'; Pattern=$cachePattern },
        [pscustomobject]@{ Code='LOCAL_PROXY_ENDPOINT'; Pattern='(?i)(?:127\.0\.0\.1|localhost)\s*:\s*7897' },
        [pscustomobject]@{ Code='GITHUB_CREDENTIAL'; Pattern='(?i)(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})' },
        [pscustomobject]@{ Code='EMBEDDED_TOKEN_FIELD'; Pattern='(?i)["'']?(?:uploadToken|access_token|refresh_token|oauth_token|id_token)["'']?\s*[:=]\s*["'']?(?!<|REDACTED\b|redacted\b|example\b|placeholder\b|null\b)([A-Za-z0-9._~+/=-]{16,})' },
        [pscustomobject]@{ Code='PRIVATE_KEY_MATERIAL'; Pattern='-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----' },
        [pscustomobject]@{ Code='BEARER_CREDENTIAL'; Pattern='(?i)\bBearer\s+[A-Za-z0-9._~-]{24,}' },
        [pscustomobject]@{ Code='PASSWORD_CREDENTIAL'; Pattern='(?i)\b(?:password|passwd|client_secret|api_key)\s*[:=]\s*[''"]?(?!<|example|placeholder)[A-Za-z0-9/$+=._~-]{8,}' },
        [pscustomobject]@{ Code='URL_CREDENTIAL'; Pattern='(?i)\bhttps?://[^/\s:@''"<>]+:[^/\s@''"<>]{4,}@' }
    )

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lines = $Content -split "`r?`n"
    for ($lineNumber = 0; $lineNumber -lt $lines.Count; $lineNumber++) {
        $line = $lines[$lineNumber]
        $allowFixture = $line -match '(?i)public-hygiene:\s*allow-(?:synthetic-path|generic-platform-location)\b'
        foreach ($rule in $rules) {
            if ($allowFixture -and $rule.Code -in $script:PathFindingCodes) { continue }
            if ([regex]::IsMatch($line, $rule.Pattern)) {
                $key = '{0}|{1}|{2}' -f $RelativePath, $lineNumber, $rule.Code
                if ($seen.Add($key)) {
                    [pscustomobject]@{ Path=$RelativePath; Line=$lineNumber + 1; Code=$rule.Code }
                }
            }
        }
        foreach ($identity in $SensitiveIdentities) {
            if ($identity -and $identity.Trim().Length -ge 4 -and $line.IndexOf($identity.Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $key = '{0}|{1}|SENSITIVE_IDENTITY' -f $RelativePath, $lineNumber
                if ($seen.Add($key)) {
                    [pscustomobject]@{ Path=$RelativePath; Line=$lineNumber + 1; Code='SENSITIVE_IDENTITY' }
                }
                break
            }
        }
    }
}

function Get-MmtlPublicHygieneFileFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [string[]]$SensitiveIdentities = @(),
        [int]$ArchiveDepth = 0
    )

    $all = [Collections.Generic.List[object]]::new()
    $hasUtf16LeBom = $Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE
    $hasUtf16BeBom = $Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF
    $hasNullByte = [Array]::IndexOf($Bytes, [byte]0) -ge 0

    if ($hasUtf16LeBom -or $hasUtf16BeBom) {
        $encoding = if ($hasUtf16LeBom) { [Text.Encoding]::Unicode } else { [Text.Encoding]::BigEndianUnicode }
        $decodedCandidates = @($encoding.GetString($Bytes))
    } elseif (-not $hasNullByte) {
        $decodedCandidates = @([Text.Encoding]::UTF8.GetString($Bytes))
    } else {
        $decodedCandidates = @()
        $ascii = [Text.Encoding]::ASCII.GetString($Bytes)
        foreach ($match in [regex]::Matches($ascii, '[\x20-\x7E]{4,}')) {
            $decodedCandidates += $match.Value
        }

        foreach ($littleEndian in @($true, $false)) {
            $builder = [Text.StringBuilder]::new()
            $offset = if ($littleEndian) { 0 } else { 1 }
            for ($index = $offset; $index + 1 -lt $Bytes.Length; $index += 2) {
                $zeroByte = if ($littleEndian) { $Bytes[$index + 1] } else { $Bytes[$index] }
                $charByte = if ($littleEndian) { $Bytes[$index] } else { $Bytes[$index + 1] }
                if ($zeroByte -eq 0 -and $charByte -ge 0x20 -and $charByte -le 0x7E) {
                    [void]$builder.Append([char]$charByte)
                } else {
                    if ($builder.Length -ge 4) { $decodedCandidates += $builder.ToString() }
                    [void]$builder.Clear()
                }
            }
            if ($builder.Length -ge 4) { $decodedCandidates += $builder.ToString() }
        }
    }

    foreach ($decoded in $decodedCandidates) {
        foreach ($finding in @(Get-MmtlPublicHygieneContentFinding -Content $decoded -RelativePath $RelativePath -SensitiveIdentities $SensitiveIdentities)) {
            $all.Add($finding)
        }
    }

    $extension = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if ($extension -in @('.zip','.jar','.war','.nupkg')) {
        if ($ArchiveDepth -ge 4) {
            $all.Add([pscustomobject]@{ Path=$RelativePath; Line=0; Code='ARCHIVE_DEPTH_LIMIT' })
        } else {
            $memory = [IO.MemoryStream]::new($Bytes, $false)
            $archive = $null
            try {
                $archive = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read, $false)
                foreach ($entry in $archive.Entries) {
                    $entryPath = $RelativePath + '!/' + $entry.FullName
                    foreach ($finding in @(Get-MmtlPublicHygieneContentFinding -Content $entry.FullName -RelativePath $entryPath -SensitiveIdentities $SensitiveIdentities)) {
                        $all.Add($finding)
                    }
                    if ($entry.FullName.EndsWith('/')) { continue }
                    $entryStream = $entry.Open()
                    $entryMemory = [IO.MemoryStream]::new()
                    try {
                        $entryStream.CopyTo($entryMemory)
                        $entryBytes = $entryMemory.ToArray()
                    } finally {
                        $entryStream.Dispose()
                        $entryMemory.Dispose()
                    }
                    foreach ($finding in @(Get-MmtlPublicHygieneFileFinding -RelativePath $entryPath -Bytes $entryBytes -SensitiveIdentities $SensitiveIdentities -ArchiveDepth ($ArchiveDepth + 1))) {
                        $all.Add($finding)
                    }
                }
            } catch {
                $all.Add([pscustomobject]@{ Path=$RelativePath; Line=0; Code='ARCHIVE_SCAN_FAILED' })
            } finally {
                if ($archive) { $archive.Dispose() } else { $memory.Dispose() }
            }
        }
    }

    $all | Sort-Object Path, Line, Code -Unique
}

Export-ModuleMember -Function Get-MmtlPublicHygieneIdentityCandidates, Get-MmtlPublicHygieneContentFinding, Get-MmtlPublicHygieneFileFinding
