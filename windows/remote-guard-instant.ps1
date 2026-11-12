# ============================================================
# remote-guard-instant.ps1 — 即时通道监视进程（常驻，2 秒级轮询）
#
# 目的：主任务每分钟采样一轮，最坏延迟 ~70 秒；本进程把"会话刚建立"
#       的信号做到几秒内推送。
# 会话建立需连续两轮连接与流量佐证；解除需连续 3 分钟无会话证据。

$ErrorActionPreference = 'Continue'
# 安装根目录：默认脚本所在目录（部署时可放任意路径）
$Root      = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogFile   = Join-Path $Root 'remote-guard.log'
$PidFile   = Join-Path $Root 'instant.pid'
$InstState = Join-Path $Root 'instant-state.json'

# （推送通道统一走 push-channels.json 配置，见 Send-Push）

$LoopSec        = 2      # 轮询间隔（秒）
$ChannelsFile = Join-Path $Root 'push-channels.json'

function Get-PushChannels {
    try {
        if (Test-Path -LiteralPath $ChannelsFile) {
            $cfg = Get-Content -LiteralPath $ChannelsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return @($cfg.channels | Where-Object { $_.enabled })
        }
    } catch { }
    return @()
}

function Send-Push([string]$Title, [string]$Body) {
    $anyOk = $false
    foreach ($ch in (Get-PushChannels)) {
        $ok = $false
        try {
            switch ([string]$ch.type) {
                'bark' {
                    if ($ch.key -and $ch.base) {
                        $uri = '{0}/{1}/{2}/{3}?group={4}&ttl={5}' -f $ch.base, $ch.key, [uri]::EscapeDataString($Title), [uri]::EscapeDataString($Body), $(if ($ch.group) { $ch.group } else { 'remote-guard' }), $(if ($ch.ttl) { $ch.ttl } else { 600 })
                        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10
                        if ($r.code -eq 200) { $ok = $true }
                    }
                }
                'hayo' {
                    if ($ch.token -and $ch.base) {
                        $uri = '{0}/send?token={1}&title={2}&content={3}' -f $ch.base, [uri]::EscapeDataString($ch.token), [uri]::EscapeDataString($Title), [uri]::EscapeDataString(($Body -replace "`r`n", ' | '))
                        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10
                        if ($r.status -eq 200) { $ok = $true }
                    }
                }
                'webhook' {
                    if ($ch.url) {
                        $uri = $ch.url + '?title=' + [uri]::EscapeDataString($Title) + '&content=' + [uri]::EscapeDataString($Body)
                        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10
                        $ok = $true
                    }
                }
            }
        } catch { }
        if ($ok) { $anyOk = $true } else { Write-Log ('推送通道 ' + $ch.name + ' 发送失败') }
    }
    return $anyOk
}

function Write-Log([string]$Text) {
    try {
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 2MB)) {
            Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.1') -Force
        }
        $line = '{0}  [即时] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Invoke-Bark([string]$Title, [string]$Body) {
    # 兼容旧名：多通道推送统一入口
    return Send-Push $Title $Body
}

# 同一进程、连续采样确认；已确认的端点不要求静态画面持续产生流量。
function Update-InstantEvidence($Previous, [array]$Samples, [datetime]$Now, [bool]$VDisplayActive, [bool]$RequireUuEvidence = $false) {
    if (-not $Previous) { $Previous = @{ active = $false; samples = @{}; quietSince = $null; notified = $false } }
    $next = @{ active = $false; samples = @{}; quietSince = $Previous.quietSince; notified = $Previous.notified; pendingRecovery = $Previous.pendingRecovery; lastPushAttempt = $Previous.lastPushAttempt; reason = $Previous.reason }
    $evidence = $false
    # VDisplayActive 仅保留参数兼容：驱动可常驻，不能建立或维持会话。
    foreach ($sample in $Samples) {
        $key = [string]$sample.Id
        $prev = $Previous.samples[$key]
        $seconds = 0
        if ($prev) { $seconds = ($Now - $prev.time).TotalSeconds }
        $sameProcess = ($prev -and $sample.Started -and $prev.started -eq $sample.Started -and $seconds -gt 0 -and $seconds -le 10)
        $valid = ($sameProcess -and $null -ne $sample.Io -and $null -ne $prev.io -and $sample.Io -ge $prev.io)
        $delta = 0
        if ($valid) { $delta = $sample.Io - $prev.io }
        $overlap = @()
        if ($prev -and $prev.confirmedPeers -and $prev.started -eq $sample.Started) {
            $overlap = @($sample.PeerKeys | Where-Object { $prev.confirmedPeers -contains $_ })
        }
        $streak = 0
        $bundleStable = ($sameProcess -and $sample.PeerBundle -and $prev.peerBundle -and @($sample.PeerKeys | Where-Object { $prev.observedPeers -contains $_ }).Count -ge 3)
        # 新会话至少连续两次有有效流量，不能累计十几秒的后台文件 IO。
        $flowCandidate = ($valid -and $sample.HasNet -and ($sample.PeerKeys.Count -gt 0 -or $sample.FreshSession) -and $delta -ge 512KB)
        if ($RequireUuEvidence) { $flowCandidate = ($flowCandidate -and $sample.FreshSession) }
        if ($flowCandidate -or ($RequireUuEvidence -and $bundleStable)) {
            $streak = 1 + [int]$prev.streak
        }
        $confirmedPeers = @()
        if ($Previous.active -and $prev -and $prev.started -eq $sample.Started) { $confirmedPeers = @($prev.confirmedPeers) }
        if ($streak -ge 2) {
            $confirmedPeers = @($sample.PeerKeys); $evidence = $true
            $next.reason = $(if ($RequireUuEvidence -and $bundleStable) { 'UU 同一对端至少 3 个被控监听端口连续确认' } else { '会话连接与活动连续确认' })
        }
        if ($Previous.active -and $overlap.Count -gt 0) { $evidence = $true }
        # 已确认的中继会话仍需当前会话文件和 IO 佐证，443 心跳不能单独续期。
        if ($Previous.active -and $valid -and $sample.HasNet -and $sample.FreshSession -and ($delta / $seconds * 60) -ge 1MB) { $evidence = $true }
        $next.samples[$key] = @{ started = $sample.Started; time = $Now; io = $sample.Io; streak = $streak; confirmedPeers = $confirmedPeers; observedPeers = @($sample.PeerKeys); peerBundle = [bool]$sample.PeerBundle }
    }
    if ($evidence) {
        $next.active = $true
        $next.quietSince = $null
    } elseif ($Previous.active) {
        if (-not $next.quietSince) { $next.quietSince = $Now }
        $next.active = (($Now - $next.quietSince).TotalSeconds -lt 180)
    }
    if ($Previous.active -and -not $next.active -and $Previous.notified) { $next.pendingRecovery = $true }
    if (-not $next.active) { $next.notified = $false }
    else { $next.pendingRecovery = $false }
    return $next
}

function Restore-InstantTracking($Saved, [datetime]$Now) {
    $restored = @{}
    if (-not $Saved -or $Saved.schema -ne 3 -or -not $Saved.updated) { return $restored }
    $age = ($Now.ToUniversalTime() - ([datetime]$Saved.updated).ToUniversalTime()).TotalSeconds
    if ($age -lt 0 -or $age -gt 180) { return $restored }
    foreach ($entry in $Saved.tracking.PSObject.Properties) {
        $value = $entry.Value
        $samples = @{}
        foreach ($sp in $value.samples.PSObject.Properties) {
            $v = $sp.Value
            $samples[$sp.Name] = @{ started = $v.started; time = ([datetime]$v.time).ToLocalTime(); io = $v.io; streak = $v.streak; confirmedPeers = @($v.confirmedPeers); observedPeers = @($v.observedPeers); peerBundle = [bool]$v.peerBundle }
        }
        $restored[$entry.Name] = @{ active = [bool]$value.active; notified = [bool]$value.notified; samples = $samples; quietSince = $(if ($value.quietSince) { ([datetime]$value.quietSince).ToLocalTime() } else { $null }); pendingRecovery = [bool]$value.pendingRecovery; lastPushAttempt = $(if ($value.lastPushAttempt) { ([datetime]$value.lastPushAttempt).ToLocalTime() } else { $null }); reason = $value.reason }
    }
    return $restored
}

function Test-RemoteAddress([string]$Addr) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Addr, [ref]$ip)) { return $false }
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    return -not ([System.Net.IPAddress]::IsLoopback($ip) -or $ip.Equals([System.Net.IPAddress]::Any) -or $ip.Equals([System.Net.IPAddress]::IPv6Any))
}

# 命名互斥量防并发启动；PID 文件仅供看护，避免误把复用 PID 当作守护进程。
$mutex = New-Object Threading.Mutex($false, 'Local\RemoteGuardInstant')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    $PID | Set-Content -LiteralPath $PidFile
    Write-Log ('即时通道待命 (PID ' + $PID + '，连续流量确认，解除静默期 180s)')
    $tools = @(
        @{ name = 'UU远程'; procs = @('GameViewerServer') },
        @{ name = 'ToDesk'; procs = @('ToDesk','ToDesk_Session') }
    )
    $states = @{}
    $ist = @{ schema = 3; updated = $null; activeTools = @(); notifiedTools = @(); lastAlert = $null; lastTool = $null; lastRecovery = $null; tracking = @{} }
    try {
        $saved = Get-Content -LiteralPath $InstState -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $states = Restore-InstantTracking $saved (Get-Date)
        if ($states.Count -gt 0) {
            $ist.lastAlert = $saved.lastAlert; $ist.lastTool = $saved.lastTool; $ist.lastRecovery = $saved.lastRecovery
        }
    } catch { }
    while ($true) {
        try {
            $now = Get-Date
            $tcp = @(Get-NetTCPConnection -ErrorAction Stop)
            $connections = @($tcp | Where-Object { $_.State -eq 'Established' })
            $io = @{}
            foreach ($pf in @(Get-CimInstance Win32_PerfRawData_PerfProc_Process -ErrorAction Stop)) {
                $io[[int]$pf.IDProcess] = [double]$pf.IODataBytesPersec
            }
            if ($io.Count -eq 0) { throw '性能采样为空' }
            foreach ($tool in $tools) {
                $samples = @()
                foreach ($p in @(Get-Process -Name $tool.procs -ErrorAction SilentlyContinue)) {
                    $started = $null
                    $sessionGlob = $null
                    try {
                        $started = $p.StartTime.ToUniversalTime().ToString('o')
                        if ($p.Path -and $tool.name -eq 'UU远程') {
                            $sessionGlob = Join-Path (Split-Path (Split-Path $p.Path)) 'config\server\*.ini'
                        } elseif ($p.Path) {
                            $sessionGlob = Join-Path (Split-Path $p.Path) 'Logs\session*.xlog'
                        }
                    } catch { }
                    $fresh = $false
                    if ($sessionGlob) {
                        $files = @(Get-ChildItem -Path $sessionGlob -File -ErrorAction SilentlyContinue | Where-Object {
                            $age = ($now - $_.LastWriteTime).TotalSeconds
                            $age -ge 0 -and $age -le 15
                        })
                        $fresh = ($files.Count -gt 0)
                    }
                    $conns = @($connections | Where-Object { $_.OwningProcess -eq $p.Id -and (Test-RemoteAddress $_.RemoteAddress) })
                    $hasNet = ($conns.Count -gt 0)
                    $bundle = $false
                    if ($tool.name -eq 'UU远程') {
                        $ports = @($tcp | Where-Object { $_.OwningProcess -eq $p.Id -and $_.State -eq 'Listen' } | ForEach-Object LocalPort)
                        $conns = @($conns | Where-Object { $ports -contains $_.LocalPort -and $_.RemotePort -notin @(80,443) })
                        foreach ($group in @($conns | Group-Object RemoteAddress)) {
                            if (@($group.Group.LocalPort | Select-Object -Unique).Count -ge 3) { $bundle = $true }
                        }
                    }
                    $peers = @($conns | Where-Object { $_.RemotePort -notin @(80,443) } | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.LocalAddress, $_.LocalPort, $_.RemoteAddress, $_.RemotePort })
                    $samples += @{ Id = $p.Id; Started = $started; Io = $(if ($io.ContainsKey([int]$p.Id)) { $io[[int]$p.Id] } else { $null }); PeerKeys = $peers; HasNet = $hasNet; FreshSession = $fresh; PeerBundle = $bundle }
                }
                $previous = $states[$tool.name]
                $next = Update-InstantEvidence $previous $samples $now $false ($tool.name -eq 'UU远程')
                $canPush = (-not $next.lastPushAttempt -or ($now - $next.lastPushAttempt).TotalSeconds -ge 10)
                if ($next.active -and -not $next.notified -and $canPush) {
                    # 从分钟任务接管已通知的会话时，不再重复发送进入通知。
                    try {
                        $main = Get-Content -LiteralPath (Join-Path $Root 'state.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                        $mainAge = ($now - [datetime]$main.lastRun).TotalSeconds
                        if ($main.controlled -and $main.tools -contains $tool.name -and $mainAge -ge 0 -and $mainAge -le 90 -and $main.lastNotify -and ($now - [datetime]$main.lastNotify).TotalMinutes -lt 30) {
                            $next.notified = $true
                            $ist.lastAlert = $main.lastNotify
                        }
                    } catch { }
                }
                if ($next.active -and -not $next.notified -and $canPush) {
                    $next.lastPushAttempt = $now
                    $body = $next.reason + ': ' + $tool.name + ' 主机: ' + $env:COMPUTERNAME + ' 时间: ' + $now.ToString('yyyy-MM-dd HH:mm:ss')
                    if (Send-Push '远程控制告警' $body) {
                        $next.notified = $true
                        $ist.lastAlert = $now.ToString('o')
                        $ist.lastTool = $tool.name
                        Write-Log ('即时告警已推送: ' + $tool.name)
                    }
                } elseif ($next.pendingRecovery -and $canPush) {
                    $next.lastPushAttempt = $now
                    if (Send-Push '远程控制已解除' ('会话信号连续 3 分钟消失: ' + $tool.name + ' 主机: ' + $env:COMPUTERNAME)) {
                        $next.pendingRecovery = $false
                        Write-Log ('即时通道已恢复: ' + $tool.name)
                    } else { Write-Log ('解除推送失败: ' + $tool.name) }
                    $ist.lastRecovery = $now.ToString('o')
                }
                $states[$tool.name] = $next
            }
            $ist.updated = $now.ToString('o')
            $ist.activeTools = @($tools | Where-Object { $states[$_.name].active } | ForEach-Object { $_.name })
            $ist.notifiedTools = @($tools | Where-Object { $states[$_.name].active -and $states[$_.name].notified } | ForEach-Object { $_.name })
            $ist.tracking = $states
            # 临时文件 + 原子替换，主任务不会读到半截 JSON。
            # （.NET Framework 的 File.Replace 对空 backup 路径会抛异常，改用 Move -Force 覆盖）
            $tmp = $InstState + '.tmp'
            $ist | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $InstState -Force
        } catch {
            # 采集失败不等同断开，不更新状态，等下一轮恢复采集。
            Write-Log ('即时采样失败: ' + $_.Exception.Message)
        }
        Start-Sleep -Seconds $LoopSec
    }
} finally {
    Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
