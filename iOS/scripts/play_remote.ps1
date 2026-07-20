param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string[]]$WavPath,

    [ValidateRange(1, 100000)]
    [int]$RepeatCount = 1,

    [ValidateRange(0, 86400)]
    [double]$SameFileDelaySeconds = 0,

    [ValidateRange(0, 86400)]
    [double]$DifferentFileDelaySeconds = 0,

    [string]$MacHost = "macbook",
    [string]$MacDeveloperDir = "/Applications/Xcode-beta.app/Contents/Developer",
    [string]$DeviceId = "YOUR_DEVICE_UDID",
    [string]$BundleId = "com.a2m.audiorepeater.ios",

    [ValidateRange(10, 86400)]
    [int]$PlaybackTimeoutSeconds = 600,

    [switch]$UseDeviceCtl,

    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedFiles = @(foreach ($path in $WavPath) {
    $file = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Extension -ine ".wav") {
        throw "Not a WAV file: $path"
    }
    $file
})

if ($resolvedFiles.Count -eq 0) {
    throw "At least one WAV file is required."
}

$sessionId = [Guid]::NewGuid().ToString("N")
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) "AudioRepeaterRemote"
$localStaging = Join-Path $stagingRoot $sessionId
$localAudioStaging = Join-Path $localStaging "RemoteAudio"
$remoteStagingRoot = "~/AudioRepeaterIOSWork/remote-playback"
$remoteStaging = "$remoteStagingRoot/$sessionId"
$iosDeploy = "~/AudioRepeaterIOSWork/tools/ios-deploy/build/Release/ios-deploy"
$appPath = "~/AudioRepeaterIOSWork/iOS/build/DeviceDerivedData/Build/Products/Debug-iphoneos/AudioRepeaterIOS.app"
$xcrun = if ([string]::IsNullOrWhiteSpace($MacDeveloperDir)) {
    "xcrun"
} else {
    "DEVELOPER_DIR='$MacDeveloperDir' xcrun"
}

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [switch]$IgnoreExitCode
    )

    if ($IgnoreExitCode) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "SilentlyContinue"
            & ssh $MacHost $Command 2>$null
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    } else {
        & ssh $MacHost $Command
    }
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw "Remote command failed with exit code ${exitCode}: $Command"
    }
}

New-Item -ItemType Directory -Path $localAudioStaging -Force | Out-Null
$debuggerLauncherStarted = $false
$launchLogName = "ios-deploy.log"

try {
    $manifestFiles = @()
    for ($index = 0; $index -lt $resolvedFiles.Count; $index++) {
        $remoteName = "{0:D3}.wav" -f ($index + 1)
        Copy-Item -LiteralPath $resolvedFiles[$index].FullName -Destination (Join-Path $localAudioStaging $remoteName)
        $manifestFiles += [ordered]@{
            fileName = $remoteName
            displayName = $resolvedFiles[$index].Name
            repeatCount = $RepeatCount
        }
    }

    $manifest = [ordered]@{
        files = $manifestFiles
        sameFileDelaySeconds = $SameFileDelaySeconds
        differentFileDelaySeconds = $DifferentFileDelaySeconds
    }
    $manifestPath = Join-Path $localStaging "remote-playback.json"
    $manifestJson = $manifest | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($manifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))
    $emptyStatusPath = Join-Path $localStaging "remote-playback-status.log"
    [IO.File]::WriteAllText($emptyStatusPath, "", [Text.UTF8Encoding]::new($false))

    Invoke-RemoteCommand "mkdir -p $remoteStagingRoot"
    & scp -r -- $localStaging "${MacHost}:$remoteStagingRoot/"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy the playback staging directory to the Mac."
    }

    $deviceCommand = "$iosDeploy --id $DeviceId --bundle_id $BundleId"
    if ($UseDeviceCtl) {
        $deviceCtlDomain = "--domain-type appDataContainer --domain-identifier $BundleId"
        Invoke-RemoteCommand "$xcrun devicectl --version >/dev/null"
        Invoke-RemoteCommand "$xcrun devicectl device copy to --device $DeviceId --source $remoteStaging/RemoteAudio --destination Documents/RemoteAudio $deviceCtlDomain --remove-existing-content true"
        Invoke-RemoteCommand "$xcrun devicectl device copy to --device $DeviceId --source $remoteStaging/remote-playback-status.log --destination Documents/remote-playback-status.log $deviceCtlDomain"
        # Upload the manifest last so the app never observes a partially copied request.
        Invoke-RemoteCommand "$xcrun devicectl device copy to --device $DeviceId --source $remoteStaging/remote-playback.json --destination Documents/remote-playback.json $deviceCtlDomain"
    } else {
        Invoke-RemoteCommand "$deviceCommand --rmtree /Documents/RemoteAudio" -IgnoreExitCode
        Invoke-RemoteCommand "$deviceCommand --mkdir /Documents/RemoteAudio"

        foreach ($file in $manifestFiles) {
            Invoke-RemoteCommand "$deviceCommand --upload $remoteStaging/RemoteAudio/$($file.fileName) --to /Documents/RemoteAudio/$($file.fileName)"
        }

        Invoke-RemoteCommand "$deviceCommand --rm /Documents/remote-playback.json" -IgnoreExitCode
        Invoke-RemoteCommand "$deviceCommand --rm /Documents/remote-playback-status.log" -IgnoreExitCode
        Invoke-RemoteCommand "$deviceCommand --upload $remoteStaging/remote-playback.json --to /Documents/remote-playback.json"
        Invoke-RemoteCommand "$deviceCommand --kill" -IgnoreExitCode
    }

    Write-Host "Uploaded $($resolvedFiles.Count) WAV files for remote playback."
    for ($index = 0; $index -lt $resolvedFiles.Count; $index++) {
        Write-Host ("  {0:D3}: {1}" -f ($index + 1), $resolvedFiles[$index].FullName)
    }

    if ($NoLaunch) {
        Write-Host "Playback request is ready. Launch AudioRepeaterIOS to consume it."
        return
    }

    if ($UseDeviceCtl) {
        $launchLogName = "devicectl.log"
        $launchCommand = "$xcrun devicectl device process launch --device $DeviceId --terminate-existing $BundleId > $remoteStaging/$launchLogName 2>&1"
        Invoke-RemoteCommand $launchCommand
    } else {
        $launchCommand = "nohup $iosDeploy --id $DeviceId --bundle $appPath --noinstall --debug --noninteractive --unbuffered > $remoteStaging/$launchLogName 2>&1 < /dev/null &"
        Invoke-RemoteCommand $launchCommand
        $debuggerLauncherStarted = $true
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($PlaybackTimeoutSeconds)
    $attempt = 0
    $finalStatus = $null

    do {
        Start-Sleep -Seconds 2
        $attempt++
        if ($UseDeviceCtl) {
            $statusPath = "$remoteStaging/status-$attempt.log"
            $downloadCommand = "$xcrun devicectl device copy from --device $DeviceId --source Documents/remote-playback-status.log --destination $statusPath $deviceCtlDomain"
            $downloadOutput = & ssh $MacHost "$downloadCommand >/dev/null 2>&1" 2>$null
        } else {
            $downloadDirectory = "$remoteStaging/status-$attempt"
            $downloadCommand = "$deviceCommand --download=/Documents/remote-playback-status.log --to $downloadDirectory"
            $downloadOutput = & ssh $MacHost $downloadCommand 2>$null
            $statusPath = "$downloadDirectory/Documents/remote-playback-status.log"
        }

        if ($LASTEXITCODE -eq 0) {
            $statusLines = & ssh $MacHost "if [ -f $statusPath ]; then cat $statusPath; fi" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $statusText = $statusLines -join "`n"
                if ($statusText -match "AudioRepeaterIOS playQueue finish stopped=false") {
                    $finalStatus = $statusLines
                    break
                }
                if ($statusText -match "AudioRepeaterIOS playQueue (error|finish stopped=true)") {
                    throw "Remote playback failed:`n$statusText"
                }
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($null -eq $finalStatus) {
        $debugLog = & ssh $MacHost "tail -80 $remoteStaging/$launchLogName" 2>&1
        throw "Remote playback did not finish within $PlaybackTimeoutSeconds seconds.`n$($debugLog -join "`n")"
    }

    Write-Host "Remote playback completed successfully."
    $finalStatus |
        Where-Object { $_ -match "playQueue start|repeat=$RepeatCount/$RepeatCount|playQueue finish" } |
        ForEach-Object { Write-Host "  $_" }
} finally {
    if ($debuggerLauncherStarted) {
        & ssh $MacHost "pkill -f 'ios-deploy --id $DeviceId --bundle .*AudioRepeaterIOS.app --noinstall --debug' 2>/dev/null || true" 2>$null | Out-Null
    }

    $resolvedStagingRoot = [IO.Path]::GetFullPath($stagingRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedLocalStaging = [IO.Path]::GetFullPath($localStaging)
    if ($resolvedLocalStaging.StartsWith($resolvedStagingRoot + [IO.Path]::DirectorySeparatorChar) -and
        (Test-Path -LiteralPath $resolvedLocalStaging)) {
        Remove-Item -LiteralPath $resolvedLocalStaging -Recurse -Force
    }
}
