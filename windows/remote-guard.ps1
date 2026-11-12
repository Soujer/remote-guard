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
#      - 快速助手、Windows 远程协助也需活动佐证，打开窗口不代表已建立会话
#      - connection 模式：进程存在且有已建立的远程 TCP 连接（VNC）
#      - activity 模式：同一进程连续两轮具有连接、IO 和直连/会话文件/CPU 佐证
#        进程 IO 包含磁盘操作，不能单独认定为网络串流；单次握手不告警
#      - 服务启动和 RDP 开关仅记诊断日志，不代表已建立受控会话
#      - 输入时间戳仅作诊断，不能区分本机键鼠和远程输入，不参与受控判定
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
$CpuActiveRateWithNet = 1.0   # 有远程连接时的宽松阈值（80/443 常驻信令会干扰，不能设太低）
$CpuStreakNeeded      = 2     # 连续命中次数（每分钟一次采样）
$IoActiveBytesPerMin  = 1MB   # 串流流量判定：进程 IO ≥1 MB/分钟（空闲仅几 KB）
$RemindMinutes        = 30    # 持续受控的提醒间隔（分钟）
$NotifyRecovery       = $true # 解除时是否推送恢复消息
$InputWindowSec       = 25    # 输入注入传感器采样窗口（秒，逐秒采样）
# 远控服务状态仅供诊断，升级/自启也会启动服务
$SvcDefs = @(
    @{ Tool = 'ToDesk'; Svc = 'ToDesk_Service' },
    @{ Tool = '向日葵'; Svc = 'SunloginService' }
)

# 会话文件路径自动探测（从运行中进程的安装目录推导；探测失败则该项禁用）
$uuSessionPath = $null
try {
    $gvp = Get-Process -Name 'GameViewerServer' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gvp -and $gvp.Path) { $uuSessionPath = Join-Path (Split-Path (Split-Path $gvp.Path)) 'config\server\*.ini' }
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
    @{ Name = '快速助手';        Procs = @('QuickAssist');                                                 Mode = 'activity' },
    @{ Name = 'Windows远程协助'; Procs = @('msra');                                                        Mode = 'activity' }
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
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Addr, [ref]$ip)) { return $false }
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    return -not ([System.Net.IPAddress]::IsLoopback($ip) -or $ip.Equals([System.Net.IPAddress]::Any) -or $ip.Equals([System.Net.IPAddress]::IPv6Any))
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
$instant = $null
$instantFresh = $false
try {
    $instant = Get-Content -LiteralPath (Join-Path $Root 'instant-state.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    $instantAge = ($now - [datetime]::Parse($instant.updated)).TotalSeconds
    $instantFresh = ($instant.schema -eq 3 -and $instantAge -ge 0 -and $instantAge -le 15)
} catch { }

# ---------- 采集 ----------
$findings = New-Object System.Collections.ArrayList
$procInfo = @{}
$newStreaks = @{}
$peerStreaksNew = @{}

$allProcs = @(Get-Process -ErrorAction SilentlyContinue)
$estConns = @()
try {
    $tcpSnapshot = @(Get-NetTCPConnection -ErrorAction Stop)
    $estConns = @($tcpSnapshot | Where-Object { $_.State -eq 'Established' })
} catch {
    if ($DryRun) { throw }
    Write-Log '网络采样失败，保留上轮状态，不判定解除'
    return
}

# 进程 IO 累计快照（包含磁盘与设备操作，须配合连接证据使用）
$ioByPid = @{}
try {
    foreach ($pf in @(Get-CimInstance Win32_PerfRawData_PerfProc_Process -ErrorAction Stop)) {
        if ($pf.IDProcess -gt 0) { $ioByPid[[int]$pf.IDProcess] = [double]$pf.IODataBytesPersec }
    }
    if ($ioByPid.Count -eq 0) { throw '性能采样为空' }
} catch {
    if ($DryRun) { throw }
    Write-Log '活动采样失败，保留上轮状态，不判定解除'
    return
}

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
    if (-not $DryRun) { Write-Log ('诊断: RDP 开关变更 {0} -> {1}，{2}（不代表会话建立）' -f $rdpDenyPrevVal, $rdpDenyNow, $denyMeaning) }
}
try {
    $qw = @(qwinsta 2>$null)
    foreach ($line in $qw) {
        if ($line -match '(?i)rdp-tcp#\d+\s+.+?\s+\d+\s+(Active|活动)\b') {
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
    # 即时通道对这两种工具负责完整会话周期，主任务共用结果，避免重复告警和相反状态。
    if ($instantFresh -and $def.Name -in @('UU远程','ToDesk')) {
        if ($instant.activeTools -contains $def.Name) {
            [void]$findings.Add([pscustomobject]@{ Tool = $def.Name; Pid = '-'; Detail = '即时通道已确认会话（含断开静默观察期）'; Real = $true })
        }
        continue
    }
    $procs = @($allProcs | Where-Object { $def.Procs -contains $_.Name })
    if ($procs.Count -eq 0) { $newStreaks[$def.Name] = 0; continue }

    switch ($def.Mode) {
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
            $newStreaks[$def.Name] = 0
            $peerStreaksNew[$def.Name] = 0
            $hasSession = $false
            if ($def.SessionFiles) {
                foreach ($sfp in $def.SessionFiles) {
                    $fresh = @(Get-Item -Path $sfp -ErrorAction SilentlyContinue | Where-Object {
                        $ageSec = ($now - $_.LastWriteTime).TotalSeconds
                        $ageSec -ge 0 -and $ageSec -le $def.SessionFreshSec
                    })
                    if ($fresh.Count -gt 0) { $hasSession = $true }
                }
            }
            foreach ($p in $procs) {
                $key = [string]$p.Id
                $started = $null
                try { $started = $p.StartTime.ToUniversalTime().ToString('o') } catch { }
                $cpu = $(if ($null -ne $p.CPU) { [double]$p.CPU } else { 0 })
                $io = $(if ($ioByPid.ContainsKey([int]$p.Id)) { $ioByPid[[int]$p.Id] } else { $null })
                $conns = @($estConns | Where-Object { $_.OwningProcess -eq $p.Id -and (Test-RemoteAddress $_.RemoteAddress) })
                $peer = @($conns | Where-Object { $PeerPortExclude -notcontains $_.RemotePort })
                $bundle = $false
                if ($def.Name -eq 'UU远程') {
                    $ports = @($tcpSnapshot | Where-Object { $_.OwningProcess -eq $p.Id -and $_.State -eq 'Listen' } | ForEach-Object LocalPort)
                    $peer = @($peer | Where-Object { $ports -contains $_.LocalPort })
                    foreach ($group in @($peer | Group-Object RemoteAddress)) {
                        if (@($group.Group.LocalPort | Select-Object -Unique).Count -ge 3) { $bundle = $true }
                    }
                }
                $cpuRate = 0.0
                $ioRate = 0.0
                $prev = $null
                if ($state -and $state.procs) { $prev = $state.procs.$key }
                # 丢弃跨进程重启、PID 复用、休眠恢复和过期的采样。
                $valid = ($elapsedMin -ge 0.5 -and $elapsedMin -le 3 -and $started -and $prev -and $prev.started -eq $started -and $prev.name -eq $p.Name)
                if ($valid) {
                    $cpuRate = [Math]::Max(0, ($cpu - [double]$prev.cpu) / $elapsedMin)
                    if ($null -ne $io -and $null -ne $prev.io) {
                        $ioRate = [Math]::Max(0, ($io - [double]$prev.io) / $elapsedMin)
                    }
                }
                # 每个 PID 独立关联连接、活动和连续次数，不把不同进程的证据拼接。
                $hasPeer = ($peer.Count -gt 0)
                if ($def.PeerProcs) { $hasPeer = ($hasPeer -and $def.PeerProcs -contains $p.Name) }
                $cpuOk = ($def.CpuRule -ne $false -and $cpuRate -ge $CpuActiveRateWithNet)
                $support = ($hasPeer -or $hasSession -or $cpuOk)
                $candidate = ($valid -and $conns.Count -gt 0 -and $ioRate -ge $IoActiveBytesPerMin -and $support)
                $peerKeys = @($peer | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.LocalAddress, $_.LocalPort, $_.RemoteAddress, $_.RemotePort })
                if ($def.Name -eq 'UU远程') {
                    $bundleStable = ($valid -and $bundle -and $prev.peerBundle -and @($peerKeys | Where-Object { $prev.observedPeers -contains $_ }).Count -ge 3)
                    $candidate = (($def.PeerProcs -contains $p.Name) -and ($bundleStable -or ($candidate -and $hasSession)))
                }
                $confirmedPeers = @()
                $continuing = $false
                if ($valid -and $prev.confirmedPeers) {
                    $confirmedPeers = @($prev.confirmedPeers)
                    $continuing = (@($peerKeys | Where-Object { $prev.confirmedPeers -contains $_ }).Count -gt 0)
                }
                $streak = 0
                if ($candidate) { $streak = 1 + [int]$prev.confirmations }
                if ($continuing) { $streak = [Math]::Max($streak, $CpuStreakNeeded) }
                if ($candidate -and $streak -ge $CpuStreakNeeded) { $confirmedPeers = $peerKeys }
                $procInfo[$key] = @{ name = $p.Name; started = $started; cpu = $cpu; io = $io; confirmations = $streak; confirmedPeers = $confirmedPeers; observedPeers = $peerKeys; peerBundle = $bundle }
                $newStreaks[$def.Name] = [Math]::Max($newStreaks[$def.Name], $streak)
                if ($hasPeer) { $peerStreaksNew[$def.Name] = $streak }
                if ($streak -ge $CpuStreakNeeded) {
                    $detail = $(if ($continuing) { '已确认会话连接仍在（静态画面无需持续流量）' } elseif ($def.Name -eq 'UU远程' -and $bundleStable) { 'UU 同一对端至少 3 个被控监听端口连续确认' } else { '同一进程连续 {0} 轮连接与活动确认，IO {1:N1} MB/分钟' -f $streak, ($ioRate / 1MB) })
                    [void]$findings.Add([pscustomobject]@{ Tool = $def.Name; Pid = $p.Id; Detail = $detail; Real = $true })
                }
            }
        }
    }
}
# --- 2b) 服务状态变更仅供诊断，不能据此认定会话建立 ---
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
        # 5 分钟内只记录一次，避免服务抖动反复刷日志。
        $recent = ($prevFired -and (($now - $prevFired).TotalMinutes -lt 5))
        if (-not $recent) {
            if (-not $DryRun) { Write-Log ('诊断: 服务 {0} 由 {1} 转为 Running（不代表会话建立）' -f $sd.Svc, $prevStatus) }
            $firedOut = $now.ToString('o')
        }
    }
    if ($firedOut -and (($now - [datetime]$firedOut).TotalMinutes -ge 5)) { $firedOut = $null }
    $svcStatesNew[$sd.Tool] = @{ state = $curStatus; fired = $firedOut }
}

# 本轮的会话时间仅来自已确认连接，不继承旧输入锁存。
$realSession = (@($findings | Where-Object { $_.Real }).Count -gt 0)
$sessionSignalOut = $(if ($realSession) { $now.ToString('o') } else { $null })
# --- 2d) 输入注入传感器（红线：不记录按键内容，只统计输入 tick 与锁屏状态） ---
# 只在诊断时采样，常规轮询无需再等待 25 秒输入窗口。
if ($DryRun) {
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
    # GetLastInputInfo 只提供输入时间，不说明输入来源；锁屏、UAC 和本机打字均不能证明远控。
    # 保留采样用于 DryRun 校准，不产生 finding，也不刷新会话时间。
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
$instantOwnsCurrent = ($instantFresh -and $controlled -and @($findings | Where-Object { $instant.notifiedTools -notcontains $_.Tool }).Count -eq 0)

# 虚拟显示器仅供诊断，不代表远控会话存在。
# ---------- 受控粘滞：防"静态画面/直连休眠"误恢复 ----------
# 真会话确认后信号可能暂时归零：UU 静态画面时 GPU 编码器不产出（串流 IO 掉到空闲基线），
# P2P 直连可能被断开省资源——但会话并没有结束！
# 规则：曾受控时本轮无 finding 不立即解除，需"无任何会话信号"连续 $ReleaseAfterQuietMin 分钟。
$ReleaseAfterQuietMin = 3
$stickyHeld = $false   # 本轮是否为"粘滞保持"（无 finding 但因静默期未满而保持受控）
if (-not $controlled -and $wasControlled -and $state -and $state.since -and -not ($instantFresh -and $state.instantOwned)) {
    try {
        $quietSince = $null
        if ($state.quietSince) { try { $quietSince = [datetime]::Parse([string]$state.quietSince) } catch { } }
        if (-not $quietSince) {
            # 第一轮静默: 记录时刻, 暂不解除
            $controlled = $true; $stickyHeld = $true
            $detailLines = @('· 会话静默观察中（等待确认结束，最长 ' + $ReleaseAfterQuietMin + ' 分钟）')
        } elseif ((($now - $quietSince).TotalMinutes -lt $ReleaseAfterQuietMin)) {
            # 静默未满 3 分钟: 保持受控
            $controlled = $true; $stickyHeld = $true
            $detailLines = @('· 会话静默 ' + [int](($now - $quietSince).TotalMinutes) + ' 分钟（< ' + $ReleaseAfterQuietMin + ' 分钟，保持受控）')
        }
        # 静默 >= 3 分钟: controlled 保持 false, 正常解除
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
        if (-not $wasControlled) {
            if ($instantOwnsCurrent) { $lastNotify = [datetime]::Parse($instant.lastAlert) }
            else { $needNotify = $true }
        }
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
        if ($wasControlled -and $NotifyRecovery -and -not ($instantFresh -and $state.instantOwned)) {
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
$quietSinceOut = $null
if ($Seed) {
    # 基线模式不改动受控状态，只更新已见事件
    $stateControlled = $wasControlled
    if ($wasControlled -and $state -and $state.since) { $sinceValue = $state.since }
    if ($wasControlled -and $state -and $state.quietSince) { $quietSinceOut = [string]$state.quietSince }
} elseif ($stickyHeld) {
    # 粘滞保持（无 finding 但静默期未满）：必须持久化静默起始时刻，否则下一轮永远当作"第一轮静默"
    if ($wasControlled -and $state -and $state.since) { $sinceValue = $state.since } else { $sinceValue = $now.ToString('o') }
    if ($state -and $state.quietSince) { $quietSinceOut = [string]$state.quietSince } else { $quietSinceOut = $now.ToString('o') }
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
    instantOwned = $instantOwnsCurrent
    tools      = @($findings | ForEach-Object { $_.Tool } | Select-Object -Unique)
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
        if ($ipid -match '^\d+$') {
            $guardProc = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$ipid) -ErrorAction SilentlyContinue
            $expected = Join-Path $Root 'remote-guard-instant.ps1'
            $instantAlive = ($guardProc -and $guardProc.Name -match '^(powershell|pwsh)\.exe$' -and $guardProc.CommandLine -like ('*' + $expected + '*'))
        }
    }
    if (-not $instantAlive) {
        $vbs = Join-Path $Root 'remote-guard-instant-launcher.vbs'
        if (Test-Path -LiteralPath $vbs) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
            Write-Log ('即时通道进程不在，已重新拉起')
        }
    }
} catch { }
