# ============================================================
# remote-guard-instant.ps1 — 即时通道监视进程（常驻，2 秒级轮询）
#
# 目的：主任务每分钟采样一轮，最坏延迟 ~70 秒；本进程把"会话刚建立"
#       的信号做到几秒内推送。
# 信号（与主任务同源，均为已实测的真实会话特征）：
#   UU远程：GameViewerServer 存在非 80/443 的高端口直连，
#           或 config\server\*.ini 在 15 秒内刚生成/刷新（会话开始标志）
#   ToDesk：session*.xlog 在 15 秒内刚生成，且 ToDesk 进程已建立远程连接
# 行为：触发 → 立即推送 Bark 告警，进入保持态（最短 3 分钟）；
#       直连消失 + IO 连续 3 次(每 10 秒一测) <1MB/分钟 + ini 不新鲜
#       → 推送"已解除"，回到待命。
# 单实例：pid 文件防重入；由 remote-guard.ps1 每分钟看护拉起。
# 事件日志写同一个 remote-guard.log（前缀 [即时]）。
# ============================================================

$ErrorActionPreference = 'Continue'
# 安装根目录：默认脚本所在目录（部署时可放任意路径）
$Root      = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogFile   = Join-Path $Root 'remote-guard.log'
$PidFile   = Join-Path $Root 'instant.pid'
$InstState = Join-Path $Root 'instant-state.json'

# （推送通道统一走 push-channels.json 配置，见 Send-Push）

$LoopSec        = 2      # 轮询间隔（秒）
$IniFreshSec    = 15     # UU 会话 ini 新鲜窗口
$TdFreshSec     = 15     # ToDesk 会话 xlog 新鲜窗口
$LatchMin       = 0.5    # 触发后最短保持受控时长（分钟）：直连消失是可靠的断开信号（静态画面直连仍在），30 秒足够防抖
$QuietChecksNeed = 1     # 静默 IO 检查次数（每次间隔 10 秒）=> 判定解除：直连消失后 10~30 秒内解除
$IoActiveBytesPerMin = 1MB
$PeerPortExclude = @(80,443)
$PushMinGapSec  = 10     # 两次告警的最小间隔（防抖；解除推送不重置此计时器，解除后的重连视为新会话必须推送）
$ChannelsFile   = Join-Path $Root 'push-channels.json'
# UU/ToDesk 会话文件路径自动探测（从运行中进程的安装目录推导）
$UuSessionGlob = $null
try {
    $gvp = Get-Process -Name 'GameViewerServer' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gvp -and $gvp.Path) { $UuSessionGlob = Join-Path (Split-Path (Split-Path (Split-Path $gvp.Path))) 'config\server\*.ini' }
} catch { }
$TdSessionGlob = $null
try {
    $tdp = Get-Process -Name 'ToDesk' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($tdp -and $tdp.Path) { $TdSessionGlob = Join-Path (Split-Path $tdp.Path) 'Logs\session*.xlog' }
} catch { }

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

function Test-RemoteAddress([string]$Addr) {
    if (-not $Addr) { return $false }
    if ($Addr -eq '127.0.0.1' -or $Addr -eq '::1' -or $Addr -eq '0.0.0.0' -or $Addr -eq '::') { return $false }
    if ($Addr -like '127.*') { return $false }
    if ($Addr -like 'fe80::*') { return $false }
    return $true
}

function Save-InstantState([hashtable]$St) {
    try {
        [ordered]@{
            lastAlert    = $St.lastAlert
            lastTool     = $St.lastTool
            lastRecovery = $St.lastRecovery
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $InstState -Encoding UTF8
    } catch { }
}

# ---------- 单实例守卫 ----------
try {
    $already = $false
    if (Test-Path -LiteralPath $PidFile) {
        $oldPid = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue
        if ($oldPid -and (Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue)) { $already = $true }
    }
    if ($already) { exit 0 }
    $PID > $PidFile
} catch { }

Write-Log ('即时通道待命 (PID ' + $PID + '，轮询 ' + $LoopSec + 's)')

$lastAlertTime = $null
$ist = @{ lastAlert = $null; lastTool = $null; lastRecovery = $null }
if (Test-Path -LiteralPath $InstState) {
    try {
        $prev = Get-Content -LiteralPath $InstState -Raw -Encoding UTF8 | ConvertFrom-Json
        $ist.lastAlert = $prev.lastAlert; $ist.lastTool = $prev.lastTool; $ist.lastRecovery = $prev.lastRecovery
    } catch { }
}
# 待命态基线（跨轮保持）：ini mtime 跳变检测 + GameViewerServer IO 速率计算
$lastIniMtimeSeen = $null
$ioSnapPrev = $null
$ioSnapPrevTime = $null
$pollCount = 0

while ($true) {
    try {
        Start-Sleep -Seconds $LoopSec
        $now = Get-Date

        # ---------- 待命：检测触发信号 ----------
        $trigger = $null
        $detail  = ''

        # UU：GameViewerServer 高端口直连
        $uuDirectCount = 0
        $uuProc = Get-Process -Name 'GameViewerServer' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($uuProc) {
            $c = @(Get-NetTCPConnection -State Established -OwningProcess $uuProc.Id -ErrorAction SilentlyContinue | Where-Object { $PeerPortExclude -notcontains $_.RemotePort -and (Test-RemoteAddress $_.RemoteAddress) })
            $uuDirectCount = $c.Count
            if ($c.Count -gt 0) {
                $trigger = 'UU远程'
                $detail  = '被控直连会话 (' + (@($c | ForEach-Object { $_.RemoteAddress + ':' + $_.RemotePort }) -join ', ') + ')'
            }
        }

        # UU：会话 ini 刚生成（纯中继会话兜底）。
        # 红线：会话【开始】和【结束】都会刷新 ini，文件新鲜 ≠ 会话进行中，
        #       必须叠加高端口直连佐证；断开瞬间直连已消失，不会再误报。
        if (-not $trigger -and $UuSessionGlob) {
            $ini = Get-ChildItem -Path $UuSessionGlob -File -ErrorAction SilentlyContinue | Where-Object { ($now - $_.LastWriteTime).TotalSeconds -le $IniFreshSec } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($ini -and $uuDirectCount -gt 0) { $trigger = 'UU远程'; $detail = '会话文件刚生成 (' + $ini.Name + ')' }
        }

        # ToDesk：会话 xlog 刚生成 + 进程已建立远程连接
        if (-not $trigger -and $TdSessionGlob) {
            $td = Get-ChildItem -Path $TdSessionGlob -File -ErrorAction SilentlyContinue | Where-Object { ($now - $_.LastWriteTime).TotalSeconds -le $TdFreshSec } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($td) {
                $tdProcs = @(Get-Process -Name 'ToDesk','ToDesk_Session' -ErrorAction SilentlyContinue)
                $tdNet = $false
                foreach ($tp in $tdProcs) {
                    if (@(Get-NetTCPConnection -State Established -OwningProcess $tp.Id -ErrorAction SilentlyContinue | Where-Object { Test-RemoteAddress $_.RemoteAddress }).Count -gt 0) { $tdNet = $true; break }
                }
                if ($tdNet) { $trigger = 'ToDesk'; $detail = '会话文件刚生成 (' + $td.Name + ')' }
            }
        }

        if (-not $trigger) { continue }

        # 防抖：距上次推送太近则只进保持态，不重复推
        $canPush = $true
        if ($lastAlertTime -and (($now - $lastAlertTime).TotalSeconds -lt $PushMinGapSec)) { $canPush = $false }

        if ($canPush) {
            $body = '检测到本机可能正被远程控制（即时通道，会话建立后 ' + $LoopSec + '~' + ($LoopSec * 3) + ' 秒内捕获）：' + "`r`n" + ('· {0}: {1}' -f $trigger, $detail) + "`r`n主机: $env:COMPUTERNAME  用户: $env:USERNAME" + "`r`n时间: " + $now.ToString('yyyy-MM-dd HH:mm:ss')
            if (Invoke-Bark '远程控制告警' $body) {
                Write-Log ('即时告警已推送: · {0}: {1}' -f $trigger, $detail)
            } else {
                Write-Log ('即时告警推送失败（保持态仍生效）: · {0}: {1}' -f $trigger, $detail)
            }
            $lastAlertTime = $now
            $ist.lastAlert = $now.ToString('o'); $ist.lastTool = $trigger
            Save-InstantState $ist
        }

        # ---------- 保持态：直连/IO 任一在场即维持，全部消失后解除 ----------
        $quietChecks = 0
        $lastIoVals = $null
        $lastIoTime = $now
        $holdStart = $now
        while ($true) {
            Start-Sleep -Seconds $LoopSec
            $t = Get-Date

            # 直连仍在 → 活跃
            $stillActive = $false
            $uuP = Get-Process -Name 'GameViewerServer' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($uuP) {
                if (@(Get-NetTCPConnection -State Established -OwningProcess $uuP.Id -ErrorAction SilentlyContinue | Where-Object { $PeerPortExclude -notcontains $_.RemotePort -and (Test-RemoteAddress $_.RemoteAddress) }).Count -gt 0) { $stillActive = $true }
            }
            if (-not $stillActive) {
                $tdProcs2 = @(Get-Process -Name 'ToDesk','ToDesk_Session' -ErrorAction SilentlyContinue)
                foreach ($tp in $tdProcs2) {
                    if (@(Get-NetTCPConnection -State Established -OwningProcess $tp.Id -ErrorAction SilentlyContinue | Where-Object { Test-RemoteAddress $_.RemoteAddress }).Count -gt 0) { $stillActive = $true; break }
                }
            }
            if ($stillActive) { $quietChecks = 0; $lastIoVals = $null; $lastIoTime = $t; continue }

            # 每 10 秒测一次进程 IO（串流流量 >=1MB/分钟 视为活跃）
            if (($t - $lastIoTime).TotalSeconds -ge 10) {
                $curIo = @{}
                try {
                    foreach ($pf in @(Get-CimInstance Win32_PerfRawData_PerfProc_Process -ErrorAction SilentlyContinue)) {
                        if ($pf.IDProcess -gt 0 -and ($pf.Name -match '(?i)^gamerviewerserver$|^todesk$')) { $curIo[[int]$pf.IDProcess] = [double]$pf.IODataBytesPersec }
                    }
                } catch { }
                $ioRate = 0.0
                if ($lastIoVals) {
                    foreach ($k in $curIo.Keys) {
                        if ($lastIoVals.ContainsKey($k)) {
                            $d = $curIo[$k] - [double]$lastIoVals[$k]
                            if ($d -gt 0) { $ioRate += $d / ($t - $lastIoTime).TotalSeconds * 60 }
                        }
                    }
                }
                $lastIoVals = $curIo
                $lastIoTime = $t
                $script:ioRateLast = $ioRate
                if ($ioRate -ge $IoActiveBytesPerMin) { $quietChecks = 0 } else { $quietChecks++ }
            }

            # 会话文件兜底：ini 新鲜且串流 IO 仍在（≥1MB/分钟）→ 会话还在（纯中继场景）。
            # 不能只看 ini 新鲜：断开时 UU 也会刷新 ini，会把"已解除"错误地续命。
            if ($UuSessionGlob -and $lastIoVals -and $script:ioRateLast -ge $IoActiveBytesPerMin) {
                $ini2 = Get-ChildItem -Path $UuSessionGlob -File -ErrorAction SilentlyContinue | Where-Object { ($t - $_.LastWriteTime).TotalSeconds -le $IniFreshSec }
                if ($ini2) { $quietChecks = 0; continue }
            }

            $age = ($t - $holdStart).TotalMinutes
            if ($age -ge $LatchMin -and $quietChecks -ge $QuietChecksNeed) {
                $recBody = '本机远程控制迹象已消失（即时通道）。主机: ' + $env:COMPUTERNAME + '  时间: ' + $t.ToString('yyyy-MM-dd HH:mm:ss')
                if (Invoke-Bark '远程控制已解除' $recBody) {
                    Write-Log '即时通道已恢复: 已推送'
                } else {
                    Write-Log '即时通道已恢复: 推送失败'
                }
                $ist.lastRecovery = $t.ToString('o')
                Save-InstantState $ist
                break
            }
        }
    } catch {
        Start-Sleep -Seconds 5
    }
}
