param(
    [switch]$DryRun,
    [switch]$TestPush,
    [switch]$Seed
)

# ============================================================
# remote-guard.ps1 — 本机远程控制检测 + Bark 推送
#
# 检测项：
#   1) RDP：qwinsta 中存在活动的 rdp-tcp#N 会话，或 3389 存在已建立的远程连接
#   2) 第三方远控软件（ToDesk / 向日葵 / UU远程 / AnyDesk / TeamViewer /
#      RustDesk / Parsec / Chrome远程桌面 / VNC）：
#      - presence 模式：进程存在即视为会话进行中（快速助手、Windows 远程协助）
#      - connection 模式：进程存在且有已建立的远程 TCP 连接（VNC）
#      - activity 模式：CPU 持续占用（≥1.5 秒/分钟，连续 2 次采样）、
#        或进程 IO ≥1MB/分钟（串流流量，连续 2 次）、或强 IO ≥5MB/分钟；
#        UU远程额外检测被控端与控端的高端口直连（空闲时只有 80/443 信令）
#      - 会话文件触发：UU（config\server\*.ini）/ ToDesk（session*.xlog）会话开始时
#        生成/刷新的会话文件，在新鲜窗口内出现即告警（ToDesk 需已建立连接才生效）
#      - 远控服务状态：ToDesk_Service / SunloginService 由 Stopped 转为 Running 即告警
#      - RDP 开关盯防：fDenyTSConnections 注册表值被改动即告警（远端恶意开 RDP 的关键动作）
#      - 输入注入传感器（不记录按键内容，只统计输入 tick / 锁屏状态）：
#        锁屏或安全桌面下仍有输入注入即告警；真实受控信号后 6 分钟内仍有输入也告警
#   3) 病毒性远程 / 未知远控（事件型，不改变受控状态）：
#      - 内网穿透/隧道工具进程（frpc/nps/ngrok/chisel/cloudflared/gost 等）
#      - 可疑进程链（Office/浏览器/IM 拉起 cmd/powershell/mshta 等脚本宿主）
#      - 脚本宿主命令行带 http(s) URL、PowerShell Base64 编码命令
#      - Defender 近 2 天有威胁检出（事件 1116/1117）
#      - 未知进程监听常见远控端口（5800/5900/5938/21115-21119 等）
#
# 推送：Bark，进入受控状态立即推送；持续受控每 30 分钟提醒一次；解除时推送恢复。
# 病毒性远程按事件推送（同一事件只推一次，7 天 TTL 去重），不发恢复消息。
# 由计划任务 remote-guard 每分钟通过 remote-guard-launcher.vbs 隐藏调用（零闪屏）。
# ============================================================

$ErrorActionPreference = 'Continue'
# 安装根目录：默认脚本所在目录（部署时可放任意路径）
$Root      = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$StateFile = Join-Path $Root 'state.json'
$LogFile   = Join-Path $Root 'remote-guard.log'

# ---------- Bark 推送配置 ----------
# （推送通道统一走 push-channels.json 配置，见 Send-Push）

# ---------- 检测阈值 ----------
$CpuActiveRate        = 1.5   # 活动判定：CPU 秒 / 分钟
$CpuActiveRateWithNet = 1.0   # 有远程连接时的宽松阈值（80/443 常驻信令会干扰，不能设太低）
$CpuStreakNeeded      = 2     # 连续命中次数（每分钟一次采样）
$IoActiveBytesPerMin  = 1MB   # 串流流量判定：进程 IO ≥1 MB/分钟（空闲仅几 KB）
$IoStrongBytesPerMin  = 5MB   # 强信号：≥5 MB/分钟，单次采样即告警
$RemindMinutes        = 30    # 持续受控的提醒间隔（分钟）
$NotifyRecovery       = $true # 解除时是否推送恢复消息
$SessionLatchMinutes  = 6     # 受控信号锁存窗口（分钟）：真实会话信号刷新 sessionSignal，随后该窗口内仍有输入视为会话注入
$InputWindowSec       = 25    # 输入注入传感器采样窗口（秒，逐秒采样）
$InputLockedMinTicks  = 4     # 锁屏注入判定所需最少输入 tick（窗口内）
# 远控服务状态（Manual 服务不会自己启动：Stopped -> Running 即强信号）
$SvcDefs = @(
    @{ Tool = 'ToDesk'; Svc = 'ToDesk_Service' },
    @{ Tool = '向日葵'; Svc = 'SunloginService' }
)

# 会话文件路径自动探测（从运行中进程的安装目录推导；探测失败则该项禁用）
$uuSessionPath = $null
try {
    $gvp = Get-Process -Name 'GameViewerServer' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gvp -and $gvp.Path) { $uuSessionPath = Join-Path (Split-Path (Split-Path (Split-Path $gvp.Path))) 'config\server\*.ini' }
} catch { }
$tdSessionPath = $null
try {
    $tdp = Get-Process -Name 'ToDesk' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($tdp -and $tdp.Path) { $tdSessionPath = Join-Path (Split-Path $tdp.Path) 'Logs\session*.xlog' }
} catch { }

# ---------- 远程工具进程表 ----------
$ToolDefs = @()
if ($tdSessionPath) { $ToolDefs += @{ Name = 'ToDesk';          Procs = @('ToDesk','ToDesk_Session');                                     Mode = 'activity'; SessionFiles = @($tdSessionPath); SessionFreshSec = 120; SessionNeedsNet = $true } }
else                 { $ToolDefs += @{ Name = 'ToDesk';          Procs = @('ToDesk','ToDesk_Session');                                     Mode = 'activity' } }
$ToolDefs += @(
    @{ Name = '向日葵';          Procs = @('SunloginClient','SunloginRemote','SunloginClient_Desktop','AweSun','AweSunCore','awesun_guard'); Mode = 'activity'; CpuRule = $false }
)
if ($uuSessionPath) { $ToolDefs += @{ Name = 'UU远程';          Procs = @('GameViewer','GameViewerServer','GameViewerHealthd','uuyc-mux','uuyc-cli'); Mode = 'activity'; PeerProcs = @('GameViewerServer'); SessionFiles = @($uuSessionPath); SessionFreshSec = 75; CpuRule = $false } }
else                 { $ToolDefs += @{ Name = 'UU远程';          Procs = @('GameViewer','GameViewerServer','GameViewerHealthd','uuyc-mux','uuyc-cli'); Mode = 'activity'; PeerProcs = @('GameViewerServer'); CpuRule = $false } }
$ToolDefs += @(
    @{ Name = 'AnyDesk';         Procs = @('AnyDesk');                                                     Mode = 'activity' },
    @{ Name = 'TeamViewer';      Procs = @('TeamViewer');                                                  Mode = 'activity' },
    @{ Name = 'RustDesk';        Procs = @('rustdesk');                                                    Mode = 'activity'; CpuRule = $false },
    @{ Name = 'Parsec';          Procs = @('parsecd');                                                     Mode = 'activity' },
    @{ Name = 'Chrome远程桌面';  Procs = @('remoting_host','remoting_desktop');                             Mode = 'activity' },
    @{ Name = 'VNC';             Procs = @('winvnc','vncserver','tvnserver');                              Mode = 'connection' },
    @{ Name = '快速助手';        Procs = @('QuickAssist');                                                 Mode = 'presence' },
    @{ Name = 'Windows远程协助'; Procs = @('msra');                                                        Mode = 'presence' }
)

# ---------- 病毒性远程 / 未知远控配置 ----------
# 内网穿透 / 隧道工具：常被用来把本机端口暴露到公网，实现隐蔽远控
$TunnelProcs  = @('frpc','frps','nps','npc','ngrok','chisel','rathole','cloudflared','bore','sish','pagekite','playit','gost','tun2socks')
# 可能被钓鱼文档/网页/聊天软件利用的父进程
$SuspParents  = @('WINWORD','EXCEL','POWERPNT','OUTLOOK','chrome','msedge','firefox','AcroRd32','Acrobat','wps','et','wpp','QQ','WeChat','WXWork')
# 异常链中常见的脚本宿主/系统工具（小写）
$ScriptHosts  = @('cmd','powershell','pwsh','wscript','cscript','mshta','rundll32','regsvr32','certutil','bitsadmin')
# 常见远控 / 隐蔽隧道端口
$RemotePorts  = @(5800,5900,5901,5902,3283,4899,7070,5938,21115,21116,21117,21118,21119)
# 被控端与控端直连时排除的常驻信令端口（80/443 不代表被控）
$PeerPortExclude = @(80,443)
# 事件去重保留天数
$EventSeenTtlDays = 7

function Write-Log([string]$Text) {
    try {
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 2MB)) {
            Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.1') -Force
        }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

# ---------- 多通道推送配置 ----------
# push-channels.json：channels[] 数组，每项 { name, type, enabled, ... }
#   type=bark: key/base/group/ttl        -> GET {base}/{key}/{title}/{body}?group=&ttl=
#   type=hayo: token/base                -> GET {base}/send?token=&title=&content=
#   type=webhook: url/method/bodyTemplate-> 自定义 JSON POST（bodyTemplate 中 {title}/{body} 占位）
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
    # 逐通道发送；单通道失败不影响其他通道；返回"是否至少一个通道成功"
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
                        $payload = @{ }
                        if ($ch.bodyTemplate) {
                            $payload = $ch.bodyTemplate | ConvertFrom-Json
                            foreach ($prop in $payload.PSObject.Properties) {
                                $prop.Value = [string]$prop.Value -replace '\{title\}', $Title -replace '\{body\}', ($Body -replace "`r`n", ' | ')
                            }
                            $payload = $payload | ConvertTo-Json -Depth 4
                        } else {
                            $payload = @{ title = $Title; body = $Body } | ConvertTo-Json
                        }
                        $method = $(if ($ch.method) { [string]$ch.method } else { 'Post' })
                        if ($method -ieq 'get') {
                            $r = Invoke-RestMethod -Uri ($ch.url + '?title=' + [uri]::EscapeDataString($Title) + '&content=' + [uri]::EscapeDataString($Body)) -Method Get -TimeoutSec 10
                        } else {
                            $r = Invoke-RestMethod -Uri $ch.url -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 10
                        }
                        $ok = $true
                    }
                }
            }
        } catch { }
        if ($ok) { $anyOk = $true } else { Write-Log ('推送通道 ' + $ch.name + ' 发送失败') }
    }
    return $anyOk
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

function Get-ShortText([string]$Text, [int]$Max) {
    if (-not $Text) { return '' }
    $Text = ($Text -replace '\s+', ' ').Trim()
    if ($Text.Length -gt $Max) { return $Text.Substring(0, $Max) + '...' }
    return $Text
}

# ---------- 测试推送 ----------
if ($TestPush) {
    $ok = Invoke-Bark '远程监控测试' ('这是一条测试消息，来自 ' + $env:COMPUTERNAME)
    Write-Log ('测试推送: ' + $(if ($ok) { '成功' } else { '失败' }))
    if ($ok) { 'test push ok' } else { 'test push failed' }
    exit 0
}

# ---------- 读取状态 ----------
$state = $null
if (Test-Path -LiteralPath $StateFile) {
    try { $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
}
$now = Get-Date
$lastRun = $null
if ($state -and $state.lastRun) { try { $lastRun = [datetime]::Parse($state.lastRun) } catch { } }
$elapsedMin = 0
if ($lastRun) { $elapsedMin = ($now - $lastRun).TotalMinutes }
$wasControlled = $false
if ($state -and $state.controlled) { $wasControlled = $true }
$lastNotify = $null
if ($state -and $state.lastNotify) { try { $lastNotify = [datetime]::Parse($state.lastNotify) } catch { } }

# ---------- 采集 ----------
$findings = New-Object System.Collections.ArrayList
$procInfo = @{}
$newStreaks = @{}
$peerStreaksNew = @{}

$allProcs = @(Get-Process -ErrorAction SilentlyContinue)
$estConns = @()
try { $estConns = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue) } catch { }

# 进程 IO 累计快照（用于识别串流流量；UU/GPU 编码时 CPU 很低，但串流 IO 是 MB 级）
$ioByPid = @{}
try {
    foreach ($pf in @(Get-CimInstance Win32_PerfRawData_PerfProc_Process -ErrorAction SilentlyContinue)) {
        if ($pf.IDProcess -gt 0) { $ioByPid[[int]$pf.IDProcess] = [double]$pf.IODataBytesPersec }
    }
} catch { }

# UU 虚拟显示器状态（被控会话可能激活；仅用于 false->true 跳变信号，避免常驻误报）
$uuVDisplayActive = $false
try {
    $uuVc = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'GameViewer Virtual Display Adapter' })
    if ($uuVc.Count -gt 0 -and $uuVc[0].Availability -eq 3 -and $uuVc[0].CurrentHorizontalResolution -gt 0) { $uuVDisplayActive = $true }
} catch { }

# --- 1) RDP ---
$rdpDetail = @()
# RDP 开关盯防：fDenyTSConnections 被远端恶意改开（1->0）是病毒性远程的关键动作
$rdpDenyNow = $null
try { $rdpDenyNow = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections } catch { }
$rdpDenyPrevVal = $null
if ($state -and $null -ne $state.rdpDenyPrev) { try { $rdpDenyPrevVal = [int]$state.rdpDenyPrev } catch { } }
if ($null -ne $rdpDenyNow -and $null -ne $rdpDenyPrevVal -and $rdpDenyNow -ne $rdpDenyPrevVal) {
    $denyMeaning = $(if ($rdpDenyNow -eq 0) { 'RDP 已被开启' } else { 'RDP 已被关闭' })
    [void]$findings.Add([pscustomobject]@{ Tool = 'RDP'; Pid = '-'; Detail = ('RDP 开关变更: fDenyTSConnections {0} -> {1}，{2}' -f $rdpDenyPrevVal, $rdpDenyNow, $denyMeaning); Real = $true })
}
try {
    $qw = @(qwinsta 2>$null)
    foreach ($line in $qw) {
        if ($line -match 'rdp-tcp#\d+' -and $line -notmatch '(?i)断开|Disc|侦听|Listen|连接|Conn\b') {
            $rdpDetail += '存在活动的 RDP 会话'
            break
        }
    }
} catch { }
$rdpConns = @($estConns | Where-Object { $_.LocalPort -eq 3389 -and (Test-RemoteAddress $_.RemoteAddress) })
if ($rdpConns.Count -gt 0) { $rdpDetail += ('3389 已建立远程连接 ' + $rdpConns.Count + ' 条') }
if ($rdpDetail.Count -gt 0) {
    [void]$findings.Add([pscustomobject]@{ Tool = 'RDP'; Pid = '-'; Detail = ($rdpDetail -join '；'); Real = $true })
}

# --- 2) 第三方远控工具 ---
foreach ($def in $ToolDefs) {
    $procs = @($allProcs | Where-Object { $def.Procs -contains $_.Name })
    if ($procs.Count -eq 0) { $newStreaks[$def.Name] = 0; continue }

    switch ($def.Mode) {
        'presence' {
            foreach ($p in $procs) {
                [void]$findings.Add([pscustomobject]@{ Tool = $def.Name; Pid = $p.Id; Detail = '进程正在运行（会话型工具）'; Real = $true })
                $procInfo[[string]$p.Id] = @{ name = $p.Name; cpu = $(if ($null -ne $p.CPU) { [double]$p.CPU } else { 0 }); io = $(if ($ioByPid.ContainsKey([int]$p.Id)) { $ioByPid[[int]$p.Id] } else { $null }) }
            }
        }
        'connection' {
            foreach ($p in $procs) {
                $conns = @($estConns | Where-Object { $_.OwningProcess -eq $p.Id -and (Test-RemoteAddress $_.RemoteAddress) })
                if ($conns.Count -gt 0) {
                    $ep = @($conns | ForEach-Object { $_.RemoteAddress + ':' + $_.RemotePort }) -join ', '
                    [void]$findings.Add([pscustomobject]@{ Tool = $def.Name; Pid = $p.Id; Detail = ('已建立远程连接 ' + $conns.Count + ' 条 (' + $ep + ')'); Real = $true })
                }
                $procInfo[[string]$p.Id] = @{ name = $p.Name; cpu = $(if ($null -ne $p.CPU) { [double]$p.CPU } else { 0 }); io = $(if ($ioByPid.ContainsKey([int]$p.Id)) { $ioByPid[[int]$p.Id] } else { $null }) }
            }
        }
        'activity' {
            # CpuRule=$false：常驻信令型客户端（向日葵/UU/RustDesk 带 443 心跳）的后台 CPU 空转
            # 会造成假警报，这类工具只信 IO 串流流量 / 高端口直连 / 会话文件
            $cpuRuleOk = $true
            if ($null -ne $def.CpuRule) { $cpuRuleOk = [bool]$def.CpuRule }
            $maxRate = 0.0
            $maxIoRate = 0.0
            $bestPid = $procs[0].Id
            $hasNet = $false
            $hasPeer = $false
            $peerText = ''
            $hasSession = $false
            $sessionText = ''
            foreach ($p in $procs) {
                $rate = 0.0
                $ioRate = 0.0
                if ($elapsedMin -ge 0.5 -and $state -and $state.procs) {
                    $prev = $state.procs.([string]$p.Id)
                    if ($prev) {
                        if ($null -ne $prev.cpu) {
                            $delta = [double]$p.CPU - [double]$prev.cpu
                            if ($delta -lt 0) { $delta = 0 }
                            $rate = $delta / $elapsedMin
                        }
                        if ($null -ne $prev.io -and $ioByPid.ContainsKey([int]$p.Id)) {
                            $ioDelta = [double]$ioByPid[[int]$p.Id] - [double]$prev.io
                            if ($ioDelta -lt 0) { $ioDelta = 0 }
                            $ioRate = $ioDelta / $elapsedMin
                        }
                    }
                }
                if ($rate -gt $maxRate) { $maxRate = $rate; $bestPid = $p.Id }
                if ($ioRate -gt $maxIoRate) { $maxIoRate = $ioRate; $bestPid = $p.Id }
                $conns = @($estConns | Where-Object { $_.OwningProcess -eq $p.Id -and (Test-RemoteAddress $_.RemoteAddress) })
                if ($conns.Count -gt 0) { $hasNet = $true }
                # 被控端与控端的高端口直连（UU: GameViewerServer），空闲时只有 80/443 信令
                if ($def.PeerProcs -and ($def.PeerProcs -contains $p.Name)) {
                    $peer = @($conns | Where-Object { $PeerPortExclude -notcontains $_.RemotePort })
                    if ($peer.Count -gt 0) {
                        $hasPeer = $true
                        $peerText = @($peer | ForEach-Object { $_.RemoteAddress + ':' + $_.RemotePort }) -join ', '
                    }
                }
                $procInfo[[string]$p.Id] = @{ name = $p.Name; cpu = $(if ($null -ne $p.CPU) { [double]$p.CPU } else { 0 }); io = $(if ($ioByPid.ContainsKey([int]$p.Id)) { $ioByPid[[int]$p.Id] } else { $null }) }
            }
            $streak = 0
            if ($state -and $state.streaks -and $null -ne $state.streaks.($def.Name)) { $streak = [int]$state.streaks.($def.Name) }
            # 会话文件触发：UU/ToDesk 会话开始时生成或刷新的会话文件。
            # 红线 1：UU 在会话【开始】和【结束】都会刷新 ini，文件新鲜 ≠ 会话进行中，
            #         必须叠加另一"会话在场"证据（高端口直连 / 串流 IO）才触发。
            # 红线 2：手机 UU App 打开时的设备发现/握手会刷新 ini 并建立几秒直连（下轮采样已消失），
            #         所以直连佐证需"连续两轮在场"——用 peerStreaks 记录直连连续出现轮数。
            if ($def.SessionFiles -and -not $hasSession) {
                $sessionNetOk = $true
                if ($def.SessionNeedsNet) {
                    $sessionNetOk = $hasNet
                }
                if ($sessionNetOk) {
                    $freshSec = 90
                    if ($def.SessionFreshSec) { $freshSec = [int]$def.SessionFreshSec }
                    foreach ($sfp in $def.SessionFiles) {
                        $freshFiles = @(Get-Item -Path $sfp -ErrorAction SilentlyContinue | Where-Object { ($now - $_.LastWriteTime).TotalSeconds -le $freshSec })
                        if ($freshFiles.Count -gt 0) {
                            $peerStreakPrev = 0
                            if ($state -and $state.peerStreaks -and $null -ne $state.peerStreaks.($def.Name)) { $peerStreakPrev = [int]$state.peerStreaks.($def.Name) }
                            $peerHoldOk = ($peerStreakPrev -ge 1 -and $hasPeer)
                            $hasCorroboration = ($peerHoldOk -or ($maxIoRate -ge $IoActiveBytesPerMin))
                            if ($hasCorroboration) {
                                $newest = $freshFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                                $hasSession = $true
                                $sessionText = ('{0}，{1:N0} 秒前' -f $newest.Name, (($now - $newest.LastWriteTime).TotalSeconds))
                            }
                        }
                    }
                }
            }
            # 会话级信号：直连 / 会话文件 / 串流 IO；纯 CPU 突发不算（也不许喂会话锁存）
            $realThis = ($hasPeer -or $hasSession -or ($maxIoRate -ge $IoActiveBytesPerMin))
            $active = ($maxIoRate -ge $IoActiveBytesPerMin) -or $hasPeer -or $hasSession -or ($cpuRuleOk -and ($maxRate -ge $CpuActiveRate -or ($hasNet -and $maxRate -ge $CpuActiveRateWithNet)))
            if ($active) { $streak++ } else { $streak = 0 }
            # 直连会话 / 会话文件 / 强 IO 信号单次采样即告警
            if ($hasPeer -or $hasSession -or ($hasNet -and $maxIoRate -ge $IoStrongBytesPerMin)) { $streak = [Math]::Max($streak, $CpuStreakNeeded) }
            $newStreaks[$def.Name] = $streak
            # 维护直连连续轮数（供会话文件触发的"直连已持续"佐证）
            if (-not $peerStreaksNew.ContainsKey($def.Name)) { $peerStreaksNew[$def.Name] = 0 }
            if ($hasPeer) { $peerStreaksNew[$def.Name] = $peerStreaksNew[$def.Name] + 1 } else { $peerStreaksNew[$def.Name] = 0 }
            if ($streak -ge $CpuStreakNeeded) {
                $netText = $(if ($hasNet) { '有远程连接' } else { '无远程连接' })
                if ($hasPeer)        { $detailText = '被控直连会话 (' + $peerText + ')' }
                elseif ($hasSession) { $detailText = '会话文件刚生成/刷新 (' + $sessionText + ')' }
                elseif ($maxIoRate -ge $IoActiveBytesPerMin) { $detailText = '串流流量 IO {0:N1} MB/分钟，{1}' -f ($maxIoRate / 1MB), $netText }
                else                 { $detailText = 'CPU {0:N1} 秒/分钟，IO {1:N1} MB/分钟，{2}' -f $maxRate, ($maxIoRate / 1MB), $netText }
                [void]$findings.Add([pscustomobject]@{ Tool = $def.Name; Pid = $bestPid; Detail = $detailText; Real = $realThis })
            }
        }
    }
}

# --- 2b) 远控服务状态：Manual 服务突发启动（Stopped->Running）= 可能有人正要控制 ---
$svcStatesNew = @{}
foreach ($sd in $SvcDefs) {
    $sv = Get-Service -Name $sd.Svc -ErrorAction SilentlyContinue
    $curStatus = $(if ($sv) { [string]$sv.Status } else { '?' })
    $prevStatus = $null
    $prevFired = $null
    if ($state -and $state.svcStates -and $state.svcStates.($sd.Tool)) {
        try { $prevStatus = [string]$state.svcStates.($sd.Tool).state } catch { }
        try { if ($state.svcStates.($sd.Tool).fired) { $prevFired = [datetime]::Parse([string]$state.svcStates.($sd.Tool).fired) } } catch { }
    }
    $firedOut = $prevFired
    if ($sv -and $curStatus -eq 'Running' -and $prevStatus -and $prevStatus -ne 'Running') {
        # 转变即触发一次；5 分钟内不重复触发（防服务抖动反复提醒）
        $recent = ($prevFired -and (($now - $prevFired).TotalMinutes -lt 5))
        if (-not $recent) {
            [void]$findings.Add([pscustomobject]@{ Tool = $sd.Tool; Pid = '-'; Detail = ('远控服务刚启动: {0} 由 {1} 转为 Running' -f $sd.Svc, $prevStatus); Real = $true })
            $firedOut = $now.ToString('o')
        }
    }
    if ($firedOut -and (($now - [datetime]$firedOut).TotalMinutes -ge 5)) { $firedOut = $null }
    $svcStatesNew[$sd.Tool] = @{ state = $curStatus; fired = $firedOut }
}

# --- 2c) 真实会话锁存：本轮存在受控迹象时刷新 sessionSignal（供输入传感器规则 ② 使用） ---
$realSession = (@($findings | Where-Object { $_.Real }).Count -gt 0)
$sessionSignalOut = $null
if ($realSession) {
    $sessionSignalOut = $now.ToString('o')
} elseif ($state -and $state.sessionSignal) {
    try {
        $ssPrev = [datetime]::Parse([string]$state.sessionSignal)
        if (($now - $ssPrev).TotalMinutes -le $SessionLatchMinutes) { $sessionSignalOut = [string]$state.sessionSignal }
    } catch { }
}

# --- 2d) 输入注入传感器（红线：不记录按键内容，只统计输入 tick 与锁屏状态） ---
$sensorReady = $false
try {
    if (-not ('RemoteGuardInputSensor' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RemoteGuardInputSensor
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("user32.dll")]
    private static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll")]
    private static extern bool CloseDesktop(IntPtr hDesktop);

    private static uint _lastTick = 0;

    // 返回 true 表示两次调用之间出现了新的键鼠输入（只比较 tick，不记录任何内容）
    public static bool PollInput()
    {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) { return false; }
        bool changed = (_lastTick != 0 && lii.dwTime != _lastTick);
        _lastTick = lii.dwTime;
        return changed;
    }

    // 返回 true 表示当前输入桌面不可访问（锁屏 / 安全桌面 / UAC 提示）
    public static bool IsSecureDesktop()
    {
        IntPtr h = OpenInputDesktop(0, false, 0x02000000u);
        if (h == IntPtr.Zero) { return true; }
        CloseDesktop(h);
        return false;
    }
}
'@ -ErrorAction Stop
    }
    $sensorReady = $true
} catch { }
$sensorInjTicks = -1
$sensorLockTicks = -1
$sensorLocked = $false
if ($sensorReady) {
    $injTicks = 0
    $lockStart = $false
    $lockEnd = $false
    $lockTicks = 0
    for ($i = 0; $i -lt $InputWindowSec; $i++) {
        Start-Sleep -Seconds 1
        if ([RemoteGuardInputSensor]::PollInput()) { $injTicks++ }
        if ([RemoteGuardInputSensor]::IsSecureDesktop()) {
            $lockTicks++
            if ($i -eq 0) { $lockStart = $true }
            if ($i -eq ($InputWindowSec - 1)) { $lockEnd = $true }
        }
    }
    $sensorInjTicks = $injTicks
    $sensorLockTicks = $lockTicks
    $sensorLocked = ($lockTicks -gt 0)
    # 规则①：窗口始末均处于锁屏/安全桌面，却仍有输入流入 => 必然是异地/后台注入
    if ($lockStart -and $lockEnd -and $injTicks -ge $InputLockedMinTicks) {
        [void]$findings.Add([pscustomobject]@{ Tool = '输入注入'; Pid = '-'; Detail = ('锁屏/安全桌面下检测到输入注入 (窗口 {0}s，输入 tick {1})' -f $InputWindowSec, $injTicks); Real = $true })
    }
    # 规则②：近 6 分钟内存在真实受控信号，且本窗口仍有输入流入 => 会话仍在被操作。
    # 仅用于"续受控"（wasControlled=true 时防误恢复）；不在受控状态后突然出现输入时新建警报，
    # 否则真实会话结束后的本地打字会在 6 分钟内反复触发新告警。
    $ssFresh = $false
    $ssDt = $null
    if ($wasControlled -and $state -and $state.sessionSignal) {
        try {
            $ssDt = [datetime]::Parse([string]$state.sessionSignal)
            if (($now - $ssDt).TotalMinutes -le $SessionLatchMinutes) { $ssFresh = $true }
        } catch { }
    }
    if ($ssFresh -and $injTicks -ge 2) {
        [void]$findings.Add([pscustomobject]@{ Tool = '输入注入'; Pid = '-'; Detail = ('受控会话信号 {0:N1} 分钟前，本窗口仍有输入流入 (tick {1})' -f (($now - $ssDt).TotalMinutes), $injTicks); Real = $true })
    }
}

# --- 3) 病毒性远程 / 未知远控（事件型，不参与受控状态） ---
$events = New-Object System.Collections.ArrayList

# 读取已见事件（7 天 TTL 去重）
$seenEvents = @{}
if ($state -and $state.seenEvents) {
    foreach ($prop in $state.seenEvents.PSObject.Properties) {
        try {
            $ts = [datetime]::Parse([string]$prop.Value)
            if (($now - $ts).TotalDays -le $EventSeenTtlDays) { $seenEvents[$prop.Name] = [string]$prop.Value }
        } catch { }
    }
}

# 进程快照（含父进程 / 命令行）
$cimProcs = @()
try { $cimProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) } catch { }
$procById = @{}
foreach ($cp in $cimProcs) { $procById[[string]$cp.ProcessId] = $cp }

# 已知工具进程名（用于端口检测时排除，避免误报）
$knownToolProcs = @()
foreach ($def in $ToolDefs) { $knownToolProcs += $def.Procs }
$knownToolProcs += $TunnelProcs

# 3.1 内网穿透 / 隧道工具进程
foreach ($p in $allProcs) {
    if ($TunnelProcs -contains $p.Name.ToLower()) {
        [void]$events.Add([pscustomobject]@{
            Key    = 'tunnel:' + $p.Name.ToLower()
            Title  = '隧道/穿透工具运行'
            Detail = ('{0} (PID {1})' -f $p.Name, $p.Id)
        })
    }
}

# 3.2 可疑进程链：Office/浏览器/IM -> 脚本宿主
foreach ($cp in $cimProcs) {
    $parent = $procById[[string]$cp.ParentProcessId]
    if (-not $parent) { continue }
    $pBase = [System.IO.Path]::GetFileNameWithoutExtension($parent.Name)
    $cBase = [System.IO.Path]::GetFileNameWithoutExtension($cp.Name)
    if ($SuspParents -contains $pBase -and $ScriptHosts -contains $cBase.ToLower()) {
        [void]$events.Add([pscustomobject]@{
            Key    = ('chain:{0}>{1}#{2}' -f $pBase, $cBase, $cp.ProcessId)
            Title  = '可疑进程链'
            Detail = ('{0} -> {1} (PID {2}) {3}' -f $pBase, $cBase, $cp.ProcessId, (Get-ShortText $cp.CommandLine 160))
        })
    }
}

# 3.3 脚本宿主命令行带 http(s) URL（mshta/rundll32/regsvr32/certutil/bitsadmin 远程加载）
$urlHosts = @('mshta','rundll32','regsvr32','certutil','bitsadmin')
foreach ($cp in $cimProcs) {
    $cBase = [System.IO.Path]::GetFileNameWithoutExtension($cp.Name).ToLower()
    if ($urlHosts -contains $cBase -and $cp.CommandLine -match 'https?://') {
        [void]$events.Add([pscustomobject]@{
            Key    = ('url:{0}#{1}' -f $cBase, $cp.ProcessId)
            Title  = '脚本宿主远程加载'
            Detail = ('{0} (PID {1}) {2}' -f $cBase, $cp.ProcessId, (Get-ShortText $cp.CommandLine 180))
        })
    }
}

# 3.4 PowerShell 编码命令（-e / -enc / -encodedcommand + 长 Base64）
foreach ($cp in $cimProcs) {
    $cBase = [System.IO.Path]::GetFileNameWithoutExtension($cp.Name).ToLower()
    if (($cBase -eq 'powershell' -or $cBase -eq 'pwsh') -and $cp.CommandLine -match '(?i)\s-e(?:c|nc(?:odedcommand)?)?\s+[A-Za-z0-9+/=]{40,}') {
        [void]$events.Add([pscustomobject]@{
            Key    = ('enc:{0}#{1}' -f $cBase, $cp.ProcessId)
            Title  = 'PowerShell 编码命令'
            Detail = ('{0} (PID {1}) 使用 Base64 编码命令' -f $cBase, $cp.ProcessId)
        })
    }
}

# 3.5 Defender 近 2 天威胁检出（1116/1117）
try {
    $defEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116,1117; StartTime = (Get-Date).AddDays(-2) } -MaxEvents 20 -ErrorAction Stop)
    foreach ($de in $defEvents) {
        $line = @($de.Message -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 2) -join ' '
        [void]$events.Add([pscustomobject]@{
            Key    = ('defender:{0}' -f $de.RecordId)
            Title  = 'Defender 检出威胁'
            Detail = (Get-ShortText $line 160)
        })
    }
} catch { }

# 3.6 未知进程监听常见远控端口
$listenConns = @()
try { $listenConns = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue) } catch { }
$listenKeys = @{}
foreach ($lc in $listenConns) {
    if ($RemotePorts -notcontains $lc.LocalPort) { continue }
    $owner = $procById[[string]$lc.OwningProcess]
    $oName = $(if ($owner) { $owner.Name } else { 'unknown' })
    $oBase = [System.IO.Path]::GetFileNameWithoutExtension($oName).ToLower()
    if ($oBase -eq 'system' -or $lc.OwningProcess -eq 4) { continue }
    if ($knownToolProcs -contains $oBase) { continue }
    $key = 'listen:{0}:{1}' -f $lc.LocalPort, $oBase
    if ($listenKeys.ContainsKey($key)) { continue }
    $listenKeys[$key] = $true
    [void]$events.Add([pscustomobject]@{
        Key    = $key
        Title  = '未知远控端口监听'
        Detail = ('端口 {0} 被 {1} (PID {2}) 监听' -f $lc.LocalPort, $oName, $lc.OwningProcess)
    })
}

$newEvents = @($events | Where-Object { -not $seenEvents.ContainsKey($_.Key) })

$controlled = ($findings.Count -gt 0)
$detailLines = @($findings | ForEach-Object { '· {0}: {1}' -f $_.Tool, $_.Detail })

# ---------- 受控粘滞：防"静态画面/直连休眠"误恢复 ----------
# 真会话确认后信号可能暂时归零：UU 静态画面时 GPU 编码器不产出（串流 IO 掉到空闲基线），
# P2P 直连可能被断开省资源——但会话并没有结束！
# 规则：曾受控时本轮无 finding 不立即解除，需"无任何会话信号"连续 $ReleaseAfterQuietMin 分钟。
$ReleaseAfterQuietMin = 3
if (-not $controlled -and $wasControlled -and $state -and $state.since) {
    try {
        $quietSince = $null
        if ($state.quietSince) { try { $quietSince = [datetime]::Parse([string]$state.quietSince) } catch { } }
        if (-not $quietSince) {
            $controlled = $true
            $detailLines = @('· 会话静默观察中（等待确认结束，最长 ' + $ReleaseAfterQuietMin + ' 分钟）')
        } elseif ((($now - $quietSince).TotalMinutes -lt $ReleaseAfterQuietMin)) {
            $controlled = $true
            $detailLines = @('· 会话静默 ' + [int](($now - $quietSince).TotalMinutes) + ' 分钟（< ' + $ReleaseAfterQuietMin + ' 分钟，保持受控）')
        }
    } catch { }
}

# ---------- DryRun：只输出，不推送、不写状态 ----------
if ($DryRun) {
    if ($controlled) {
        '检测结果: 发现远程控制迹象'
        $findings | Format-Table Tool, Pid, Detail -AutoSize | Out-String -Width 200
    } else {
        '检测结果: 未发现远程控制迹象'
    }
    '--- 匹配到的远程工具进程（用于校准） ---'
    foreach ($def in $ToolDefs) {
        $procs = @($allProcs | Where-Object { $def.Procs -contains $_.Name })
        foreach ($p in $procs) {
            '  {0}  PID={1}  CPU累计={2:N1}s  启动={3}' -f $def.Name, $p.Id, $(if ($null -ne $p.CPU) { $p.CPU } else { 0 }), $(try { $p.StartTime.ToString('MM-dd HH:mm') } catch { '?' })
        }
    }
    '--- 病毒性远程 / 未知远控事件 ---'
    if ($events.Count -eq 0) {
        '  （无）'
    } else {
        foreach ($ev in $events) {
            $tag = $(if ($seenEvents.ContainsKey($ev.Key)) { '已见' } else { '新' })
            '  [{0}] {1}: {2}' -f $tag, $ev.Title, $ev.Detail
        }
    }
    '--- UU 虚拟显示器: {0} ---' -f $(if ($uuVDisplayActive) { '激活' } else { '未激活' })
    if ($sensorReady) {
        '--- 输入注入传感器: 输入tick={0}  锁屏tick={1}/{2}s{3} ---' -f $sensorInjTicks, $sensorLockTicks, $InputWindowSec, $(if ($sensorLocked) { '（窗口内出现锁屏/安全桌面）' } else { '' })
    } else {
        '--- 输入注入传感器: 未启用（类型加载失败） ---'
    }
    '--- RDP 开关 fDenyTSConnections: {0} (上轮: {1}) ---' -f $rdpDenyNow, $rdpDenyPrevVal
    '--- 远控服务状态 ---'
    foreach ($sd in $SvcDefs) {
        $st = $svcStatesNew[$sd.Tool]
        '  {0}: {1}' -f $sd.Svc, $st.state
    }
    '--- sessionSignal: {0} ---' -f $(if ($sessionSignalOut) { $sessionSignalOut } else { '（无）' })
    '--- 采样间隔: {0:N1} 分钟 ---' -f $elapsedMin
    exit 0
}

# ---------- 推送 ----------
$body = '检测到本机可能正被远程控制：' + "`r`n" + ($detailLines -join "`r`n") + "`r`n主机: $env:COMPUTERNAME  用户: $env:USERNAME" + "`r`n时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

if (-not $Seed) {
    if ($controlled) {
        $needNotify = $false
        if (-not $wasControlled) { $needNotify = $true }
        elseif ($null -eq $lastNotify -or ($now - $lastNotify).TotalMinutes -ge $RemindMinutes) { $needNotify = $true }

        if ($needNotify) {
            if (Invoke-Bark '远程控制告警' $body) {
                $lastNotify = $now
                Write-Log ('告警已推送: ' + ($detailLines -join ' | '))
            } else {
                Write-Log ('告警推送失败（下次重试）: ' + ($detailLines -join ' | '))
            }
        } else {
            Write-Log ('仍在受控（未到提醒间隔）: ' + ($detailLines -join ' | '))
        }
    } else {
        if ($wasControlled -and $NotifyRecovery) {
            $ok = Invoke-Bark '远程控制已解除' ('本机远程控制迹象已消失。主机: ' + $env:COMPUTERNAME + '  时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            if ($ok) { $lastNotify = $now }
            Write-Log ('已恢复: ' + $(if ($ok) { '已推送' } else { '推送失败' }))
        }
    }

    # 病毒性远程：事件型推送，同一事件只推一次（推送成功后才写入 seenEvents）
    if ($newEvents.Count -gt 0) {
        $evLines = @($newEvents | ForEach-Object { '· {0}: {1}' -f $_.Title, $_.Detail })
        $evBody = '检测到可疑远程访问 / 恶意远控迹象：' + "`r`n" + ($evLines -join "`r`n") + "`r`n主机: $env:COMPUTERNAME  用户: $env:USERNAME" + "`r`n时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        if (Invoke-Bark '可疑远程访问告警' $evBody) {
            foreach ($ev in $newEvents) { $seenEvents[$ev.Key] = $now.ToString('o') }
            Write-Log ('可疑远程访问已推送: ' + (($newEvents | ForEach-Object { $_.Title }) -join ' | '))
        } else {
            Write-Log ('可疑远程访问推送失败（下次重试）: ' + (($newEvents | ForEach-Object { $_.Title }) -join ' | '))
        }
    }
} else {
    # Seed 基线：把当前所有事件标记为已见，不推送
    foreach ($ev in $events) { $seenEvents[$ev.Key] = $now.ToString('o') }
    Write-Log ('Seed 基线: 已标记 ' + $events.Count + ' 个事件为已见')
}

# ---------- 保存状态 ----------
$sinceValue = $null
$stateControlled = $controlled
if ($Seed) {
    # 基线模式不改动受控状态，只更新已见事件
    $stateControlled = $wasControlled
    if ($wasControlled -and $state -and $state.since) { $sinceValue = $state.since }
    if ($wasControlled -and $state -and $state.quietSince) { $quietSinceOut = [string]$state.quietSince }
} elseif ($controlled) {
    if ($wasControlled -and $state -and $state.since) { $sinceValue = $state.since } else { $sinceValue = $now.ToString('o') }
    # 受控恢复（本轮有 finding）→ 静默计时清空（quietSinceOut 保持 null）
} else {
    # 本轮无 finding: 若之前受控, 记录首轮静默时刻; 若已在静默中且未解除, 保留原值
    if ($wasControlled -or ($state -and $state.quietSince)) {
        if ($state -and $state.quietSince) { $quietSinceOut = [string]$state.quietSince } else { $quietSinceOut = $now.ToString('o') }
    }
}
$newState = [ordered]@{
    lastRun    = $now.ToString('o')
    controlled = $stateControlled
    since      = $sinceValue
    quietSince = $quietSinceOut
    lastNotify = $(if ($lastNotify) { $lastNotify.ToString('o') } else { $null })
    procs      = $procInfo
    streaks    = $newStreaks
    peerStreaks = $peerStreaksNew
    uuVDisplay = $uuVDisplayActive
    sessionSignal = $sessionSignalOut
    svcStates  = $svcStatesNew
    rdpDenyPrev = $rdpDenyNow
    seenEvents = $seenEvents
}
try {
    $newState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8
} catch {
    Write-Log ('状态写入失败: ' + $_.Exception.Message)
}

# ---------- 看护即时通道进程（几秒级推送的常驻监视器） ----------
try {
    $pidFile = Join-Path $Root 'instant.pid'
    $instantAlive = $false
    if (Test-Path -LiteralPath $pidFile) {
        $ipid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue
        if ($ipid -and (Get-Process -Id ([int]$ipid) -ErrorAction SilentlyContinue)) { $instantAlive = $true }
    }
    if (-not $instantAlive) {
        $vbs = Join-Path $Root 'remote-guard-instant-launcher.vbs'
        if (Test-Path -LiteralPath $vbs) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
            Write-Log ('即时通道进程不在，已重新拉起')
        }
    }
} catch { }
