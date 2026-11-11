$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script:checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Read-Ast([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) ('Parse failed: ' + $Path + ' ' + ($errors -join ', '))
    return $ast
}
$mainAst = Read-Ast (Join-Path $repo 'windows/remote-guard.ps1')
$instantAst = Read-Ast (Join-Path $repo 'windows/remote-guard-instant.ps1')
[void](Read-Ast (Join-Path $repo 'windows/remote-guard-setup.ps1'))
# Load only pure functions; never launch a watcher or read push credentials.
foreach ($fn in $instantAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Update-InstantEvidence','Restore-InstantTracking','Test-RemoteAddress') }, $true)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
foreach ($address in @('127.0.0.1','127.1.2.3','::1','::ffff:127.0.0.1','0.0.0.0','::','invalid')) {
    Assert (-not (Test-RemoteAddress $address)) ('Local/invalid endpoint accepted: ' + $address)
}
Assert (Test-RemoteAddress '192.168.1.20') 'LAN peers must remain detectable'
Assert (Test-RemoteAddress 'fe80::1234') 'IPv6 LAN peers must remain detectable'

$t = [datetime]'2026-11-11T12:00:00'
function Sample($Io, [string]$Started = 'process-A', [array]$Peers = @('peer-A'), [bool]$Fresh = $false) {
    return @{ Id = 100; Started = $Started; Io = $Io; PeerKeys = $Peers; HasNet = $true; FreshSession = $Fresh }
}
$s = Update-InstantEvidence $null @((Sample 0)) $t
Assert (-not $s.active) 'First sample cannot prove traffic'
$s = Update-InstantEvidence $s @((Sample 1MB)) $t.AddSeconds(2)
Assert (-not $s.active) 'One flow interval must not confirm a handshake'
$s = Update-InstantEvidence $s @((Sample 2MB)) $t.AddSeconds(4)
Assert $s.active 'Sustained peer traffic must confirm a session'
$confirmed = $s
for ($i = 1; $i -le 240; $i++) { $s = Update-InstantEvidence $s @((Sample 2MB)) $t.AddSeconds(4 + $i * 2) }
Assert $s.active 'Static screen with confirmed peer must stay active for eight minutes'
$s = Update-InstantEvidence $s @((Sample 2MB 'process-A' @())) $t.AddSeconds(486)
Assert $s.active 'One missing connection sample must not release'
$s = Update-InstantEvidence $s @((Sample 2MB)) $t.AddSeconds(488)
Assert ($s.active -and -not $s.quietSince) 'A returning confirmed peer must cancel the release timer'

$s = $confirmed
$s.notified = $true
for ($i = 1; $i -le 90; $i++) {
    # ToDesk remains running with 443 heartbeats after the real peer disconnects.
    $s = Update-InstantEvidence $s @((Sample (2MB + $i * 200) 'process-A' @())) $t.AddSeconds(4 + $i * 2)
}
Assert $s.active 'Release must wait for the full quiet period'
$s = Update-InstantEvidence $s @((Sample 3MB 'process-A' @())) $t.AddSeconds(186)
Assert (-not $s.active) 'Heartbeat must not keep a disconnected session alive'
Assert $s.pendingRecovery 'A notified session must queue its recovery notification'
$s = Update-InstantEvidence $s @((Sample 3MB 'process-A' @())) $t.AddSeconds(188)
Assert $s.pendingRecovery 'Failed recovery delivery must remain retryable'

$s = Update-InstantEvidence $null @((Sample $null)) $t
$s = Update-InstantEvidence $s @((Sample 1GB)) $t.AddSeconds(2)
Assert (-not $s.active) 'Missing IO must not become a zero baseline'
$s = Update-InstantEvidence $confirmed @((Sample 1GB 'process-B')) $t.AddSeconds(6)
Assert ($s.quietSince -and $s.samples['100'].streak -eq 0) 'PID reuse must invalidate old traffic and peer confirmation'
$s = Update-InstantEvidence $null @((Sample 0)) $t
for ($i = 1; $i -le 20; $i++) { $s = Update-InstantEvidence $s @((Sample ($i * 40KB))) $t.AddSeconds($i * 2) }
Assert (-not $s.active) 'Small background IO must not accumulate into a confirmed session'
$a = Sample 0
$b = Sample 0 'other-process' @(); $b.Id = 200
$s = Update-InstantEvidence $null @($a,$b) $t
for ($i = 1; $i -le 3; $i++) {
    $b = Sample ($i * 2MB) 'other-process' @(); $b.Id = 200
    $s = Update-InstantEvidence $s @($a,$b) $t.AddSeconds($i * 2)
}
Assert (-not $s.active) 'Traffic and peer evidence from different processes must not be combined'
$s = Update-InstantEvidence $null @((Sample 0 'process-A' @() $true)) $t
$s = Update-InstantEvidence $s @((Sample 1MB 'process-A' @() $true)) $t.AddSeconds(2)
$s = Update-InstantEvidence $s @((Sample 2MB 'process-A' @() $true)) $t.AddSeconds(4)
Assert $s.active 'Relay sessions with fresh session files and sustained IO must remain detectable'
$s = Update-InstantEvidence $s @((Sample 2MB 'process-A' @())) $t.AddSeconds(6) $true
Assert ($s.active -and -not $s.quietSince) 'Virtual display must keep a relay session alive with zero traffic'
for ($i = 1; $i -le 120; $i++) { $s = Update-InstantEvidence $s @((Sample 2MB 'process-A' @())) $t.AddSeconds(6 + $i * 2) $true }
Assert ($s.active -and -not $s.quietSince) 'Virtual display must hold a static relay session indefinitely'
$s = Update-InstantEvidence $s @((Sample 2MB 'process-A' @())) $t.AddSeconds(300) $false
Assert $s.active 'First quiet sample after losing the virtual display must start the release timer'
$s = Update-InstantEvidence $s @((Sample 2MB 'process-A' @())) $t.AddSeconds(360) $false
Assert $s.active 'Quiet under three minutes must hold the session'
$s = Update-InstantEvidence $s @((Sample 2MB 'process-A' @())) $t.AddSeconds(600) $false
Assert (-not $s.active) 'Losing the virtual display must allow normal release'
$saved = @{ schema = 2; updated = $t.AddSeconds(4); tracking = @{ 'UU远程' = $confirmed } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$restored = Restore-InstantTracking $saved $t.AddSeconds(6)
$s = Update-InstantEvidence $restored['UU远程'] @((Sample 2MB)) $t.AddSeconds(8)
Assert $s.active 'Watcher restart must preserve a confirmed static session'
Assert ((Restore-InstantTracking $saved $t.AddMinutes(10)).Count -eq 0) 'Stale saved tracking must not resurrect an old session'

# Execute the actual main-task activity branch against controlled process snapshots.
$activity = $null
foreach ($sw in $mainAst.FindAll({ param($n) $n -is [Management.Automation.Language.SwitchStatementAst] }, $true)) {
    foreach ($clause in $sw.Clauses) {
        if ($clause.Item1.Extent.Text -eq "'activity'") { $activity = [scriptblock]::Create(($clause.Item2.Statements.Extent.Text -join [Environment]::NewLine)) }
    }
}
Assert ($null -ne $activity) 'Main activity branch not found'
function Main-Sample($Previous, [double]$Io, [array]$Connections, [double]$Cpu = 0, [double]$Elapsed = 1, [string]$Started = '2026-11-11T10:00:00Z') {
    $def = @{ Name = 'UU远程'; CpuRule = $false; PeerProcs = @('GameViewerServer') }
    $procs = @([pscustomobject]@{ Id = 100; Name = 'GameViewerServer'; StartTime = [datetime]$Started; CPU = $Cpu })
    $state = [pscustomobject]@{ procs = [pscustomobject]$Previous }
    $elapsedMin = $Elapsed; $now = $t
    $ioByPid = @{ 100 = $Io }; $estConns = $Connections
    $newStreaks = @{}; $peerStreaksNew = @{}; $procInfo = @{}
    $findings = New-Object Collections.ArrayList
    $PeerPortExclude = @(80,443); $CpuActiveRateWithNet = 1; $IoActiveBytesPerMin = 1MB; $CpuStreakNeeded = 2
    . $activity
    return @{ procs = $procInfo; count = $findings.Count }
}
$peer = @([pscustomobject]@{ OwningProcess = 100; LocalAddress = '192.168.1.2'; LocalPort = 50000; RemoteAddress = '192.168.1.3'; RemotePort = 20000 })
$m = Main-Sample @{} 0 $peer
$m = Main-Sample $m.procs 10MB $peer
Assert ($m.count -eq 0) 'Main task must not bypass handshake confirmation with a single peer/strong IO sample'
$m = Main-Sample $m.procs 20MB $peer
Assert ($m.count -eq 1) 'Main fallback must detect sustained peer traffic'
$m = Main-Sample $m.procs 20MB $peer
Assert ($m.count -eq 1) 'Main fallback must retain a confirmed static peer'
$m = Main-Sample $m.procs 20MB @()
Assert ($m.count -eq 0) 'No peer and no IO must not create a fresh finding'
$m = Main-Sample $m.procs 20MB $peer
Assert ($m.count -eq 1) 'Transient peer loss must retain endpoint identity'
$m = Main-Sample $m.procs 30MB $peer 0 10
Assert ($m.count -eq 0) 'A stale sample must not confirm new activity'
$m = Main-Sample @{} 0 @() 0
$m = Main-Sample $m.procs 10MB @() 500
$m = Main-Sample $m.procs 20MB @() 1000
Assert ($m.count -eq 0) 'Disk IO/CPU without a remote connection must not trigger a session'

# Integration tests run a copy with no channel configuration. All OS collectors are mocked.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('remote-guard-regression-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
try {
    Copy-Item -LiteralPath (Join-Path $repo 'windows/remote-guard.ps1') -Destination $temp
    function Get-Process { param($Name, $ErrorAction) return @() }
    function Get-NetTCPConnection { param($State, $ErrorAction) return @() }
    function Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        if ($ClassName -eq 'Win32_PerfRawData_PerfProc_Process') { return [pscustomobject]@{ IDProcess = 4; IODataBytesPersec = 0 } }
        return @()
    }
    function Get-ItemProperty { param($Path, $Name, $ErrorAction) return @{ fDenyTSConnections = 0 } }
    function Get-Service { param($Name, $ErrorAction) return @{ Status = 'Running' } }
    function Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) throw 'No fixture events' }
    function qwinsta { return @('console user 1 Active') }
    function Start-Process { throw 'Unexpected process launch in regression test' }
    $global:vdisplayFixture = $false
    $statePath = Join-Path $temp 'state.json'
    $instantPath = Join-Path $temp 'instant-state.json'
    $baseline = @{ lastRun = (Get-Date).AddMinutes(-1).ToString('o'); controlled = $false; rdpDenyPrev = 1; svcStates = @{ ToDesk = @{ state = 'Stopped' } }; seenEvents = @{} }
    $baseline | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    & (Join-Path $temp 'remote-guard.ps1')
    $result = Get-Content $statePath -Raw | ConvertFrom-Json
    Assert (-not $result.controlled) 'Service start and RDP configuration change must not imply control'
    $baseline.controlled = $true; $baseline.since = (Get-Date).AddMinutes(-20).ToString('o')
    $baseline.quietSince = (Get-Date).AddMinutes(-4).ToString('o'); $baseline.sessionSignal = (Get-Date).ToString('o')
    $baseline | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    & (Join-Path $temp 'remote-guard.ps1')
    $result = Get-Content $statePath -Raw | ConvertFrom-Json
    Assert (-not $result.controlled) 'Old session/input latch must not prevent recovery'
    $baseline.controlled = $false
    $baseline | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    @{ schema = 2; updated = (Get-Date).ToString('o'); lastAlert = (Get-Date).ToString('o'); activeTools = @('UU远程'); notifiedTools = @('UU远程') } | ConvertTo-Json | Set-Content $instantPath -Encoding UTF8
    & (Join-Path $temp 'remote-guard.ps1')
    $result = Get-Content $statePath -Raw | ConvertFrom-Json
    Assert ($result.controlled -and $result.instantOwned -and $result.lastNotify) 'Main task must adopt an already notified instant session'
    @{ schema = 2; updated = (Get-Date).ToString('o'); activeTools = @(); notifiedTools = @() } | ConvertTo-Json | Set-Content $instantPath -Encoding UTF8
    & (Join-Path $temp 'remote-guard.ps1')
    $result = Get-Content $statePath -Raw | ConvertFrom-Json
    Assert (-not $result.controlled) 'Main task must not add another three-minute hold after instant recovery'
    # UU 虚拟显示器激活：纯中继/静态画面下会话在场的硬证据，必须维持受控且不清除静默计时陷阱
    # 注意：mock 通过 $global: 与被 & 调用的子脚本连通（$script: 作用域不跨脚本）
    @{ schema = 2; updated = (Get-Date).ToString('o'); activeTools = @(); notifiedTools = @() } | ConvertTo-Json | Set-Content $instantPath -Encoding UTF8
    $global:vdisplayFixture = $false
    $vdAdapter = [pscustomobject]@{ Name = 'GameViewer Virtual Display Adapter'; Availability = 3; CurrentHorizontalResolution = 1920 }
    function Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        if ($ClassName -eq 'Win32_PerfRawData_PerfProc_Process') { return [pscustomobject]@{ IDProcess = 4; IODataBytesPersec = 0 } }
        if ($ClassName -eq 'Win32_VideoController' -and $global:vdisplayFixture) { return @($vdAdapter) }
        return @()
    }
    $global:vdisplayFixture = $true
    & (Join-Path $temp 'remote-guard.ps1')
    $result = Get-Content $statePath -Raw | ConvertFrom-Json
    Assert ($result.controlled) 'Virtual display activity must hold the controlled state without instant ownership'
    $baseline2 = @{ lastRun = (Get-Date).AddMinutes(-1).ToString('o'); controlled = $true; since = (Get-Date).AddMinutes(-20).ToString('o'); quietSince = (Get-Date).AddMinutes(-4).ToString('o'); rdpDenyPrev = 1; svcStates = @{ ToDesk = @{ state = 'Stopped' } }; seenEvents = @{}; uuVDisplay = $true }
    $baseline2 | ConvertTo-Json -Depth 5 | Set-Content $statePath -Encoding UTF8
    & (Join-Path $temp 'remote-guard.ps1')
    $result = Get-Content $statePath -Raw | ConvertFrom-Json
    Assert ($result.controlled -and -not $result.quietSince) 'Virtual display must reset the quiet timer while holding control'
    $global:vdisplayFixture = $false
    & (Join-Path $temp 'remote-guard.ps1')
    $result = Get-Content $statePath -Raw | ConvertFrom-Json
    Assert ($result.controlled -and $result.quietSince) 'Losing the virtual display must start the quiet timer, not release instantly'
    $baseline3 = @{ lastRun = (Get-Date).AddMinutes(-1).ToString('o'); controlled = $true; since = (Get-Date).AddMinutes(-20).ToString('o'); quietSince = (Get-Date).AddMinutes(-4).ToString('o'); rdpDenyPrev = 1; svcStates = @{ ToDesk = @{ state = 'Stopped' } }; seenEvents = @{}; uuVDisplay = $false }
    $baseline3 | ConvertTo-Json -Depth 5 | Set-Content $statePath -Encoding UTF8
    & (Join-Path $temp 'remote-guard.ps1')
    $result = Get-Content $statePath -Raw | ConvertFrom-Json
    Assert (-not $result.controlled) 'Controlled state must release after the virtual display disappears and the quiet period elapses'
    $before = Get-Content $statePath -Raw
    function Get-NetTCPConnection { param($State, $ErrorAction) throw 'simulated network failure' }
    & (Join-Path $temp 'remote-guard.ps1')
    Assert ((Get-Content $statePath -Raw) -eq $before) 'Collector failure must preserve the prior state exactly'
    function Get-NetTCPConnection { param($State, $ErrorAction) return @() }
    function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) return @() }
    & (Join-Path $temp 'remote-guard.ps1')
    Assert ((Get-Content $statePath -Raw) -eq $before) 'Empty performance data must preserve state instead of declaring recovery'
} finally {
    # Only remove the test-owned files, without recursive deletion.
    Get-ChildItem -LiteralPath $temp -File | Remove-Item -Force
    Remove-Item -LiteralPath $temp
}
'Passed {0} regression checks.' -f $script:checks

