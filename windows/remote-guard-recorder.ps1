$ErrorActionPreference = 'Stop'
$recordRoot = $PSScriptRoot
. (Join-Path $recordRoot 'recording-common.ps1')
$lock = New-Object Threading.Mutex($false, 'Local\RemoteGuardRecorder')
if (-not $lock.WaitOne(0)) { $lock.Dispose(); exit 0 }
$capture = $null
function Write-RecordingLog([string]$Message) {
    $path = Join-Path $recordRoot 'recording.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) { Move-Item -LiteralPath $path -Destination ($path + '.1') -Force }
    Add-Content -LiteralPath $path -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Message) -Encoding UTF8
}
try {
    [IO.File]::WriteAllText((Join-Path $recordRoot 'recording.pid'), [string]$PID)
    Add-Type -Path (Join-Path $recordRoot 'RecordingCrypto.cs')
    Write-RecordingLog '录屏进程就绪'
    while (Get-GuardRecordingSession $recordRoot) {
        $cfg = Get-GuardRecordingConfig $recordRoot
        if (-not $cfg) { break }
        [void][IO.Directory]::CreateDirectory($cfg.directory)
        # Max-rate budget plus encoder/container overhead; the encrypted writer enforces a hard cap.
        $budget = [long]([math]::Ceiling([double]$cfg.bitrateKbps * 1000 / 8 * $cfg.segmentSeconds * 1.25) + 2MB)
        Limit-GuardRecordingStorage $cfg $budget
        $name = 'rg-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N') + '.rgrec'
        $final = Join-Path $cfg.directory $name
        $partial = $final + '.partial'
        $arguments = Get-GuardRecordingArguments $cfg
        $capture = [RemoteGuard.Capture]::new($cfg.ffmpeg, $arguments, $cfg.publicKey, $partial, $budget)
        Write-RecordingLog ('开始加密片段: ' + $name)
        while (-not $capture.Done) {
            Start-Sleep -Seconds 2
            $current = Get-GuardRecordingConfig $recordRoot
            if (-not $current -or -not (Get-GuardRecordingSession $recordRoot)) { break }
            # Configuration changes take effect at the next segment boundary.
            if (($current | ConvertTo-Json -Compress) -ne ($cfg | ConvertTo-Json -Compress)) { break }
            $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($cfg.directory))
            if ($drive.AvailableFreeSpace -lt ([long]$cfg.minFreeMB * 1MB + 1MB)) { break }
        }
        $capture.Finish()
        $capture.Dispose(); $capture = $null
        Move-Item -LiteralPath $partial -Destination $final -ErrorAction Stop
        Write-RecordingLog ('完成加密片段: ' + $name)
    }
} catch {
    Write-RecordingLog ('录屏停止: ' + $_.Exception.Message)
    @{after=(Get-Date).AddSeconds(60).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $recordRoot 'recording-retry.json') -Encoding UTF8
} finally {
    if ($capture) { try { $capture.Dispose() } catch { } }
    Remove-Item -LiteralPath (Join-Path $recordRoot 'recording.pid') -ErrorAction SilentlyContinue
    $lock.ReleaseMutex(); $lock.Dispose()
}
