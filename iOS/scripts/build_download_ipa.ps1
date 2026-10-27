[CmdletBinding()]
param(
    [string]$Ref = 'main',
    [long]$RunId = 0,
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repo = 'euije/AudioRepeater'
$workflow = 'ios-ipa.yml'
$ghCommand = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCommand) {
    throw 'Install GitHub CLI from https://cli.github.com/ and run gh auth login first.'
}

function Invoke-Gh {
    param([string[]]$Arguments)
    $result = & $ghCommand.Source @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI failed (exit $LASTEXITCODE): gh $($Arguments -join ' ')"
    }
    return $result
}

if ($RunId -eq 0) {
    $listArgs = @('run', 'list', '--repo', $repo, '--workflow', $workflow,
        '--branch', $Ref, '--event', 'workflow_dispatch', '--limit', '20',
        '--json', 'databaseId,url')
    $previous = Invoke-Gh -Arguments $listArgs | ConvertFrom-Json
    $previousIds = @($previous | ForEach-Object { $_.databaseId })
    Invoke-Gh -Arguments @('workflow', 'run', $workflow, '--repo', $repo, '--ref', $Ref)
    $deadline = (Get-Date).AddMinutes(2)
    while ($RunId -eq 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $runs = Invoke-Gh -Arguments $listArgs | ConvertFrom-Json
        $newRuns = @($runs | Where-Object { $_.databaseId -notin $previousIds })
        if ($newRuns.Count -gt 1) {
            throw 'Multiple new builds appeared. Check Actions and rerun with -RunId RUN_ID.'
        }
        if ($newRuns.Count -eq 1) {
            $RunId = $newRuns[0].databaseId
        }
    }
    if ($RunId -eq 0) {
        throw 'The dispatched build did not appear within two minutes. Check GitHub Actions.'
    }
}

Write-Host "Build: https://github.com/$repo/actions/runs/$RunId"
Invoke-Gh -Arguments @('run', 'watch', "$RunId", '--repo', $repo, '--exit-status', '--interval', '10')
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) "build\ipa\$RunId"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputPath = (Resolve-Path -LiteralPath $OutputDirectory).Path
Invoke-Gh -Arguments @('run', 'download', "$RunId", '--repo', $repo,
    '--name', 'AudioRepeaterIOS-unsigned', '--dir', $outputPath)

$ipa = Join-Path $outputPath 'AudioRepeaterIOS-unsigned.ipa'
$checksum = Get-Content -LiteralPath (Join-Path $outputPath 'SHA256SUMS.txt')
if ($checksum -notmatch '^([0-9a-fA-F]{64})\s+AudioRepeaterIOS-unsigned\.ipa$') {
    throw 'The artifact checksum file has an unexpected format.'
}
$expectedHash = $Matches[1]
$stream = [System.IO.File]::OpenRead($ipa)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $actualHash = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
}
finally {
    $stream.Dispose()
    $sha256.Dispose()
}
if ($actualHash -ne $expectedHash) {
    throw 'IPA checksum verification failed. Download the artifact again.'
}
Write-Host "Verified IPA: $ipa"
Write-Host 'Open this IPA in Sideloadly, select your USB iPhone, and sign in there.'
