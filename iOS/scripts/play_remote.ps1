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

    [ValidateSet("avAudioEngine", "remoteIO")]
    [string]$PlaybackPath = "avAudioEngine",

    [ValidateRange(-1, 1)]
    [double]$AVAudioEnginePan = 0,

    [ValidateRange(0.01, 1)]
    [double]$AVAudioEngineGain = 1,

    [switch]$AVAudioEngineDirectPCM,

    [switch]$AVAudioEngineIsolateSignals,

    [ValidateRange(20, 20000)]
    [double]$AVAudioEngineEQFrequency = 3330,

    [ValidateRange(-96, 24)]
    [double]$AVAudioEngineEQGain = 0,

    [ValidateRange(0.05, 5)]
    [double]$AVAudioEngineEQBandwidth = 0.5,

    [switch]$AVAudioEngineAutomaticFormat,

    [ValidateSet("playedBack", "rendered", "consumed")]
    [string]$AVAudioEngineCompletionCallback = "playedBack",

    [switch]$AVAudioEngineStopPlayerEachSignal,

    [ValidateRange(0, 4096)]
    [int]$AVAudioEngineCompletionDelayFrames = 0,

    [ValidateSet("mono", "dualMono", "antiPhase", "left", "right")]
    [string]$AVAudioEngineStereoMode = "mono",

    [ValidateRange(0, 0.1)]
    [double]$PreferredIOBufferDuration = 0,

    [switch]$ForceMaximumOutputVolume,

    [ValidateSet("default", "measurement", "moviePlayback", "moviePlayback44100", "moviePlayback96000", "spokenAudio", "voicePrompt", "voiceChat", "videoChat", "gameChat", "videoRecording", "playAndRecordDefault", "ambientDefault", "soloAmbientDefault")]
    [string]$AVAudioSessionMode = "default",

    [switch]$CaptureSystemAudio,

    [string]$CaptureOutputPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9_.@:-]*$")]
    [string]$MacHost,
    [string]$MacDeveloperDir = "",
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[A-Za-z0-9-]+$")]
    [string]$DeviceId,
    [ValidatePattern("^[A-Za-z0-9_.-]+$")]
    [string]$BundleId = "com.a2m.audiorepeater.ios",

    [ValidateRange(10, 86400)]
    [int]$PlaybackTimeoutSeconds = 600,

    [switch]$UseDeviceCtl,

    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($MacDeveloperDir -match "['`r`n]") {
    throw "MacDeveloperDir must not contain quotes or line breaks."
}

$resolvedFiles = @(foreach ($path in $WavPath) {
    $file = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Extension -ine ".wav") {
        throw "Not a WAV file: $path"
    }
    $file
})

if ($CaptureSystemAudio -and [string]::IsNullOrWhiteSpace($CaptureOutputPath)) {
    throw "CaptureOutputPath is required when CaptureSystemAudio is enabled."
}

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
$sshOptions = @(
    "-n", "-T",
    "-o", "BatchMode=yes",
    "-o", "ConnectionAttempts=1",
    "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2"
)
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
            & ssh @sshOptions $MacHost $Command 2>$null
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    } else {
        & ssh @sshOptions $MacHost $Command
    }
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw "Remote command failed with exit code ${exitCode}: $Command"
    }
}

function Invoke-RemoteCommandWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [ValidateRange(1, 10)]
        [int]$MaximumAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            Invoke-RemoteCommand $Command
            return
        } catch {
            if ($attempt -eq $MaximumAttempts) {
                throw
            }
            Start-Sleep -Milliseconds (250 * $attempt)
        }
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
        playbackPath = $PlaybackPath
        avAudioEnginePan = $AVAudioEnginePan
        avAudioEngineGain = $AVAudioEngineGain
        avAudioEngineDirectPCM = [bool]$AVAudioEngineDirectPCM
        avAudioEngineIsolateSignals = [bool]$AVAudioEngineIsolateSignals
        avAudioEngineEQFrequency = $AVAudioEngineEQFrequency
        avAudioEngineEQGain = $AVAudioEngineEQGain
        avAudioEngineEQBandwidth = $AVAudioEngineEQBandwidth
        avAudioEngineAutomaticFormat = [bool]$AVAudioEngineAutomaticFormat
        avAudioEngineCompletionCallback = $AVAudioEngineCompletionCallback
        avAudioEngineStopPlayerEachSignal = [bool]$AVAudioEngineStopPlayerEachSignal
        avAudioEngineCompletionDelayFrames = $AVAudioEngineCompletionDelayFrames
        avAudioEngineStereoMode = $AVAudioEngineStereoMode
        preferredIOBufferDuration = $PreferredIOBufferDuration
        forceMaximumOutputVolume = [bool]$ForceMaximumOutputVolume
        avAudioSessionMode = $AVAudioSessionMode
        captureSystemAudio = [bool]$CaptureSystemAudio
        systemAudioCaptureFileName = "screen-capture.caf"
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

    # Stop the existing monitor before publishing the manifest.  Uploading
    # while it is alive lets it consume the request before the later launch;
    # launching before upload makes CoreDevice app-container copies flaky.
    # A stopped app gives the manifest one publisher and one consumer.
    $launchedBeforeUpload = $false
    if ($UseDeviceCtl -and -not $NoLaunch) {
        $processJsonLines = & ssh @sshOptions $MacHost "$xcrun devicectl device info processes --device $DeviceId --json-output - 2>/dev/null"
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect device processes before manifest upload."
        }
        $processInfo = ($processJsonLines -join "`n") | ConvertFrom-Json
        $existingProcess = @(
            $processInfo.result.runningProcesses |
                Where-Object {
                    $_.executable -like "*/AudioRepeaterIOS.app/AudioRepeaterIOS"
                }
        ) | Select-Object -First 1
        if ($null -ne $existingProcess) {
            Invoke-RemoteCommand (
                "$xcrun devicectl device process terminate " +
                "--device $DeviceId --pid $($existingProcess.processIdentifier)"
            )
            Start-Sleep -Milliseconds 500
        }
    }

    $deviceCommand = "$iosDeploy --id $DeviceId --bundle_id $BundleId"
    if ($UseDeviceCtl) {
        $deviceCtlDomain = "--domain-type appDataContainer --domain-identifier $BundleId"
        Invoke-RemoteCommand "$xcrun devicectl --version >/dev/null"
        Invoke-RemoteCommandWithRetry "$xcrun devicectl device copy to --device $DeviceId --source $remoteStaging/RemoteAudio --destination Documents/RemoteAudio $deviceCtlDomain --remove-existing-content true"
        Invoke-RemoteCommandWithRetry "$xcrun devicectl device copy to --device $DeviceId --source $remoteStaging/remote-playback-status.log --destination Documents/remote-playback-status.log $deviceCtlDomain"
        # Upload the manifest last so the app never observes a partially copied request.
        # Do not blindly retry this publication: CoreDevice can report an
        # error after the app has already consumed the file, and a retry would
        # start the same playback twice.
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
    Write-Host "Playback path: $PlaybackPath; AVAudioEngine pan: $AVAudioEnginePan; AVAudioEngine direct PCM: $([bool]$AVAudioEngineDirectPCM); AVAudioEngine isolate signals: $([bool]$AVAudioEngineIsolateSignals); AVAudioEngine EQ: $AVAudioEngineEQFrequency Hz, $AVAudioEngineEQGain dB, $AVAudioEngineEQBandwidth oct; AVAudioEngine automatic format: $([bool]$AVAudioEngineAutomaticFormat); AVAudioEngine completion callback: $AVAudioEngineCompletionCallback; Stop player each signal: $([bool]$AVAudioEngineStopPlayerEachSignal); Completion delay frames: $AVAudioEngineCompletionDelayFrames; Stereo mode: $AVAudioEngineStereoMode; Preferred IO buffer: $PreferredIOBufferDuration s; Force maximum output volume: $([bool]$ForceMaximumOutputVolume); AVAudioSession mode: $AVAudioSessionMode; ScreenCaptureKit audio: $([bool]$CaptureSystemAudio)"
    for ($index = 0; $index -lt $resolvedFiles.Count; $index++) {
        Write-Host ("  {0:D3}: {1}" -f ($index + 1), $resolvedFiles[$index].FullName)
    }

    if ($NoLaunch) {
        Write-Host "Playback request is ready. Launch AudioRepeaterIOS to consume it."
        return
    }

    if ($UseDeviceCtl) {
        if (-not $launchedBeforeUpload) {
            $launchLogName = "devicectl.log"
            $launchCommand = "$xcrun devicectl device process launch --device $DeviceId --terminate-existing $BundleId > $remoteStaging/$launchLogName 2>&1"
            Invoke-RemoteCommand $launchCommand
        }
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
            $downloadOutput = & ssh @sshOptions $MacHost "$downloadCommand >/dev/null 2>&1" 2>$null
        } else {
            $downloadDirectory = "$remoteStaging/status-$attempt"
            $downloadCommand = "$deviceCommand --download=/Documents/remote-playback-status.log --to $downloadDirectory"
            $downloadOutput = & ssh @sshOptions $MacHost $downloadCommand 2>$null
            $statusPath = "$downloadDirectory/Documents/remote-playback-status.log"
        }

        if ($LASTEXITCODE -eq 0) {
            $statusLines = & ssh @sshOptions $MacHost "if [ -f $statusPath ]; then cat $statusPath; fi" 2>$null
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
        $debugLog = & ssh @sshOptions $MacHost "tail -80 $remoteStaging/$launchLogName" 2>&1
        throw "Remote playback did not finish within $PlaybackTimeoutSeconds seconds.`n$($debugLog -join "`n")"
    }

    Write-Host "Remote playback completed successfully."
    $finalStatus |
        Where-Object { $_ -match "playQueue start|repeat=$RepeatCount/$RepeatCount|playQueue finish" } |
        ForEach-Object { Write-Host "  $_" }

    if ($CaptureSystemAudio) {
        if (-not $UseDeviceCtl) {
            throw "ScreenCaptureKit capture download currently requires UseDeviceCtl."
        }
        $digitalAudioUnavailable = @($finalStatus | Where-Object { $_ -match "digitalAudioFile=false" }).Count -gt 0
        if ($digitalAudioUnavailable) {
            Write-Warning "ScreenCaptureKit stream was active, but this iOS build returned zero digital audio buffers; no CAF was copied."
        } else {
            $captureParent = Split-Path -Parent $CaptureOutputPath
            if (-not [string]::IsNullOrWhiteSpace($captureParent)) {
                New-Item -ItemType Directory -Path $captureParent -Force | Out-Null
            }
            $remoteCapturePath = "$remoteStaging/screen-capture.caf"
            Invoke-RemoteCommand "$xcrun devicectl device copy from --device $DeviceId --source Documents/screen-capture.caf --destination $remoteCapturePath $deviceCtlDomain"
            & scp -- "${MacHost}:$remoteCapturePath" $CaptureOutputPath
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to copy ScreenCaptureKit audio to $CaptureOutputPath"
            }
            Write-Host "ScreenCaptureKit audio copied to $CaptureOutputPath"
        }
    }
} finally {
    if ($debuggerLauncherStarted) {
        & ssh @sshOptions $MacHost "pkill -f 'ios-deploy --id $DeviceId --bundle .*AudioRepeaterIOS.app --noinstall --debug' 2>/dev/null || true" 2>$null | Out-Null
    }

    $resolvedStagingRoot = [IO.Path]::GetFullPath($stagingRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedLocalStaging = [IO.Path]::GetFullPath($localStaging)
    if ($resolvedLocalStaging.StartsWith($resolvedStagingRoot + [IO.Path]::DirectorySeparatorChar) -and
        (Test-Path -LiteralPath $resolvedLocalStaging)) {
        Remove-Item -LiteralPath $resolvedLocalStaging -Recurse -Force
    }
}
