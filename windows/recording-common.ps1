# Shared recording configuration and session coordination. Loading this file has no side effects.
function Get-GuardRecordingConfig([string]$Directory) {
    $path = Join-Path $Directory 'recording.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    # Upgrade the previous stock profile; preserve deliberate custom encoding settings.
    if ($cfg.width -eq 1280 -and $cfg.bitrateKbps -eq 400) { $cfg.width=1920; $cfg.bitrateKbps=1000 }
    if (-not $cfg.enabled) { return $null }
    if ($cfg.schema -ne 1) { throw '不支持的录屏配置版本' }
    if (-not [IO.Path]::IsPathRooted([string]$cfg.directory) -or [string]$cfg.directory -notmatch '^[A-Za-z]:\\') { throw '请选择本机磁盘上的录像目录' }
    if (-not (Test-Path -LiteralPath $cfg.ffmpeg -PathType Leaf)) { throw '未找到 FFmpeg，请先配置录屏' }
    foreach ($rule in @(@('segmentSeconds',30,900), @('fps',1,15), @('width',640,1920), @('bitrateKbps',100,2000), @('maxStorageMB',128,1048576), @('minFreeMB',128,1048576))) {
        $value = 0
        if (-not [int]::TryParse([string]$cfg.($rule[0]), [ref]$value) -or $value -lt $rule[1] -or $value -gt $rule[2]) { throw ('录屏参数无效: ' + $rule[0]) }
    }
    if (-not $cfg.publicKey -or $cfg.publicKey -match '<(D|P|Q)>') { throw '录屏配置只允许保存公钥' }
    return $cfg
}

function Test-GuardRecordingSession($Instant, $Main, [datetime]$Now) {
    $instantFresh = $false
    if ($Instant -and $Instant.schema -eq 3 -and $Instant.updated) {
        $age = ($Now.ToUniversalTime() - ([datetime]$Instant.updated).ToUniversalTime()).TotalSeconds
        $instantFresh = ($age -ge 0 -and $age -le 20)
        if ($instantFresh -and @($Instant.activeTools | Where-Object { $_ }).Count -gt 0) { return $true }
    }
    if ($Main -and $Main.lastRun -and $Main.controlled) {
        $age = ($Now.ToUniversalTime() - ([datetime]$Main.lastRun).ToUniversalTime()).TotalSeconds
        if ($age -ge 0 -and $age -le 100) {
            # Fresh instantaneous state owns UU/ToDesk, including a confirmed disconnect.
            if (-not $instantFresh) { return $true }
            return @($Main.tools | Where-Object { $_ -notin @('UU远程','ToDesk') }).Count -gt 0
        }
    }
    return $false
}

function Get-GuardRecordingSession([string]$Directory) {
    if ($script:recordingSnapshotRoot -ne $Directory) {
        $script:recordingSnapshotRoot = $Directory
        $script:recordingInstantSnapshot = $null; $script:recordingMainSnapshot = $null
    }
    # Retain the last complete snapshot across a temporary read/parse failure, until its normal expiry.
    try { $script:recordingInstantSnapshot = Get-Content -LiteralPath (Join-Path $Directory 'instant-state.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { }
    try { $script:recordingMainSnapshot = Get-Content -LiteralPath (Join-Path $Directory 'state.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { }
    $instant = $script:recordingInstantSnapshot; $main = $script:recordingMainSnapshot
    return Test-GuardRecordingSession $instant $main (Get-Date)
}

function Get-GuardRecordingFiles([string]$Directory) {
    return @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction Stop | Where-Object {
        $_.Name -match '^rg-\d{8}T\d{9}Z-[a-f0-9]{32}\.rgrec(\.partial)?$' -and
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | Sort-Object LastWriteTimeUtc, Name)
}

function Get-GuardRecordingArguments($Config) {
    $filter = 'scale=w=min(' + [int]$Config.width + '\,iw):h=min(' + [int]([math]::Floor($Config.width * 9 / 16)) + '\,ih):force_original_aspect_ratio=decrease,pad=ceil(iw/2)*2:ceil(ih/2)*2'
    return '-hide_banner -loglevel error -nostats -progress pipe:2 -f gdigrab -framerate ' + [int]$Config.fps + ' -draw_mouse 1 -i desktop -an -vf "' + $filter + '" -c:v libx264 -bf 0 -preset veryfast -pix_fmt yuv420p -b:v ' + [int]$Config.bitrateKbps + 'k -maxrate ' + [int]$Config.bitrateKbps + 'k -bufsize ' + ([int]$Config.bitrateKbps * 2) + 'k -g ' + ([int]$Config.fps * 2) + ' -threads 2 -t ' + [int]$Config.segmentSeconds + ' -movflags +frag_keyframe+empty_moov+default_base_moof -f mp4 pipe:1'
}

function Get-GuardRecordingDuration([string]$Path) {
    try {
        $file=Get-Item -LiteralPath $Path -ErrorAction Stop
        $metadata=Get-Content -LiteralPath ($Path+'.meta.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        if($metadata.schema -eq 1 -and $metadata.bytes -eq $file.Length -and $metadata.durationSeconds -gt 0 -and $metadata.durationSeconds -le 86400){return [double]$metadata.durationSeconds}
    }catch{ }
    return $null
}

function Set-GuardRecordingDuration([string]$Path,[double]$Seconds) {
    if([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -le 0 -or $Seconds -gt 86400){return}
    $metadata=[pscustomobject]@{schema=1;durationSeconds=$Seconds;bytes=(Get-Item -LiteralPath $Path -ErrorAction Stop).Length}
    $metadata|ConvertTo-Json|Set-Content -LiteralPath ($Path+'.meta.json.tmp') -Encoding UTF8
    Move-Item -LiteralPath ($Path+'.meta.json.tmp') -Destination ($Path+'.meta.json') -Force
}

function Limit-GuardRecordingStorage($Config, [long]$ReserveBytes) {
    $limit = [long]$Config.maxStorageMB * 1MB
    if ($ReserveBytes -gt $limit) { throw '单段录像预算超过总存储上限，请减少分段时长或码率' }
    $files = @(Get-GuardRecordingFiles $Config.directory)
    $total = [long]0; foreach ($file in $files) { $total += $file.Length }
    foreach ($file in $files) {
        if ($total + $ReserveBytes -le $limit) { break }
        Remove-Item -LiteralPath $file.FullName -ErrorAction Stop
        Remove-Item -LiteralPath ($file.FullName+'.meta.json') -ErrorAction SilentlyContinue
        $total -= $file.Length
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Config.directory))
    if ($drive.AvailableFreeSpace -lt ([long]$Config.minFreeMB * 1MB + $ReserveBytes)) { throw '磁盘剩余空间不足，暂停录屏' }
}

function Start-GuardRecording([string]$Directory, [bool]$Active) {
    if (-not $Active) { return }
    if (Test-Path -LiteralPath (Join-Path $Directory 'recording.stop')) { return }
    try {
        $cfg = Get-GuardRecordingConfig $Directory
        if (-not $cfg) { return }
        $retryPath = Join-Path $Directory 'recording-retry.json'
        if (Test-Path -LiteralPath $retryPath) {
            try {
                $retry = Get-Content -LiteralPath $retryPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $remaining = ([datetime]$retry.after - (Get-Date)).TotalSeconds
                if ($remaining -gt 0 -and $remaining -le 60 -and (Get-Item -LiteralPath (Join-Path $Directory 'recording.json')).LastWriteTimeUtc -le (Get-Item -LiteralPath $retryPath).LastWriteTimeUtc) { return }
            } catch { }
        }
        $worker = Join-Path $Directory 'remote-guard-recorder.ps1'
        $pidPath = Join-Path $Directory 'recording.pid'
        if (Test-Path -LiteralPath $pidPath) {
            $idText = [IO.File]::ReadAllText($pidPath).Trim()
            if ($idText -match '^\d+$') {
                $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $idText) -ErrorAction SilentlyContinue
                if ($p -and $p.Name -eq 'powershell.exe' -and $p.CommandLine -like ('*' + $worker + '*')) { return }
            }
        }
        Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $worker + '"') -WindowStyle Hidden
    } catch {
        # A recording failure must never interrupt detection or generate a connection notification.
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log ('录屏未启动: ' + $_.Exception.Message) }
    }
}
