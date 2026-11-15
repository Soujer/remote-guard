# ============================================================
# remote-guard-setup.ps1 — 远程监控推送通道配置 & 一键部署工具
#
# 功能：
#   1) hayo 微信通道：扫码登录自动获取 token（wxLogin -> 二维码 -> checkWxLogin 轮询 -> getToken）
#   2) Bark 通道：手动填 key
#   3) 通道独立测试按钮（发送测试消息验证）
#   4) 保存 push-channels.json
#   5) 一键部署：复制守护脚本 + 注册每分钟计划任务 + 拉起即时监控进程
#
# 打包：Invoke-PS2EXE .\remote-guard-setup.ps1 .\remote-guard-setup.exe -noConsole -requireAdmin
# ============================================================

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 部分老系统/老 .NET 默认只启用 TLS1.0，访问 mp.weixin.qq.com 会握手失败导致二维码下载不到
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$InstallRoot = 'C:\remote-guard'
if (-not (Test-Path $InstallRoot)) { $InstallRoot = Join-Path $env:USERPROFILE 'remote-guard' }
$SetupDir    = $PSScriptRoot
# ps2exe 编译后没有脚本路径，守护文件仍位于 exe 同目录。
if (-not $SetupDir) { $SetupDir = [AppDomain]::CurrentDomain.BaseDirectory }
if (Test-Path -LiteralPath (Join-Path $SetupDir 'push-channels.json')) { $InstallRoot = $SetupDir }

# ---------- 布局 ----------
$form                = New-Object System.Windows.Forms.Form
$form.Text           = 'remote-guard 远程监控 · 通道配置与部署'
$form.Size           = New-Object System.Drawing.Size(720, 650)
$form.StartPosition  = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox    = $false

# === hayo 微信通道组 ===
$gbHayo              = New-Object System.Windows.Forms.GroupBox
$gbHayo.Text         = 'hayo 微信推送通道（扫码自动获取 token）'
$gbHayo.Location     = New-Object System.Drawing.Point(15, 12)
$gbHayo.Size         = New-Object System.Drawing.Size(675, 300)

$pbQr                = New-Object System.Windows.Forms.PictureBox
$pbQr.Location       = New-Object System.Drawing.Point(15, 25)
$pbQr.Size           = New-Object System.Drawing.Size(280, 260)
$pbQr.SizeMode       = 'Zoom'
$pbQr.BorderStyle    = 'FixedSingle'
$gbHayo.Controls.Add($pbQr)

$lblHayoTok          = New-Object System.Windows.Forms.Label
$lblHayoTok.Text     = 'token:'
$lblHayoTok.Location = New-Object System.Drawing.Point(205, 30)
$lblHayoTok.Size     = New-Object System.Drawing.Size(45, 20)
$gbHayo.Controls.Add($lblHayoTok)

$txtHayoTok          = New-Object System.Windows.Forms.TextBox
$txtHayoTok.Location = New-Object System.Drawing.Point(250, 27)
$txtHayoTok.Size     = New-Object System.Drawing.Size(300, 24)
$gbHayo.Controls.Add($txtHayoTok)

$btnHayoScan         = New-Object System.Windows.Forms.Button
$btnHayoScan.Text    = '扫码获取'
$btnHayoScan.Location = New-Object System.Drawing.Point(205, 60)
$btnHayoScan.Size    = New-Object System.Drawing.Size(90, 30)
$gbHayo.Controls.Add($btnHayoScan)

$btnHayoTest         = New-Object System.Windows.Forms.Button
$btnHayoTest.Text    = '测试通道'
$btnHayoTest.Location = New-Object System.Drawing.Point(305, 60)
$btnHayoTest.Size    = New-Object System.Drawing.Size(90, 30)
$gbHayo.Controls.Add($btnHayoTest)

$chkHayo             = New-Object System.Windows.Forms.CheckBox
$chkHayo.Text        = '启用 hayo 微信通道'
$chkHayo.Checked     = $true
$chkHayo.Location    = New-Object System.Drawing.Point(410, 63)
$chkHayo.Size        = New-Object System.Drawing.Size(180, 24)
$gbHayo.Controls.Add($chkHayo)

$lblHayoHint         = New-Object System.Windows.Forms.Label
$lblHayoHint.Text    = '点"扫码获取"→微信扫码确认→token 自动填入。也可手动粘贴已有 token。'
$lblHayoHint.Location = New-Object System.Drawing.Point(205, 100)
$lblHayoHint.Size    = New-Object System.Drawing.Size(450, 40)
$gbHayo.Controls.Add($lblHayoHint)
$form.Controls.Add($gbHayo)

# === Bark 通道组 ===
$gbBark              = New-Object System.Windows.Forms.GroupBox
$gbBark.Text         = 'Bark 推送通道（iOS App，手动填 key）'
$gbBark.Location     = New-Object System.Drawing.Point(15, 320)
$gbBark.Size         = New-Object System.Drawing.Size(675, 115)

$lblBarkKey          = New-Object System.Windows.Forms.Label
$lblBarkKey.Text     = 'key:'
$lblBarkKey.Location = New-Object System.Drawing.Point(25, 32)
$lblBarkKey.Size     = New-Object System.Drawing.Size(40, 20)
$gbBark.Controls.Add($lblBarkKey)

$txtBarkKey          = New-Object System.Windows.Forms.TextBox
$txtBarkKey.Location = New-Object System.Drawing.Point(70, 29)
$txtBarkKey.Size     = New-Object System.Drawing.Size(480, 24)
$gbBark.Controls.Add($txtBarkKey)

$btnBarkTest         = New-Object System.Windows.Forms.Button
$btnBarkTest.Text    = '测试通道'
$btnBarkTest.Location = New-Object System.Drawing.Point(25, 62)
$btnBarkTest.Size    = New-Object System.Drawing.Size(90, 30)
$gbBark.Controls.Add($btnBarkTest)

$chkBark             = New-Object System.Windows.Forms.CheckBox
$chkBark.Text        = '启用 Bark 通道'
$chkBark.Checked     = $true
$chkBark.Location    = New-Object System.Drawing.Point(130, 65)
$chkBark.Size        = New-Object System.Drawing.Size(150, 24)
$gbBark.Controls.Add($chkBark)
$form.Controls.Add($gbBark)

# === 部署组 ===
$gbDeploy            = New-Object System.Windows.Forms.GroupBox
$gbDeploy.Text       = '部署'
$gbDeploy.Location   = New-Object System.Drawing.Point(15, 443)
$gbDeploy.Size       = New-Object System.Drawing.Size(675, 155)

$lblDir              = New-Object System.Windows.Forms.Label
$lblDir.Text         = '安装目录:'
$lblDir.Location     = New-Object System.Drawing.Point(25, 32)
$lblDir.Size         = New-Object System.Drawing.Size(60, 20)
$gbDeploy.Controls.Add($lblDir)

$txtDir              = New-Object System.Windows.Forms.TextBox
$txtDir.Text         = $InstallRoot
$txtDir.Location     = New-Object System.Drawing.Point(90, 29)
$txtDir.Size         = New-Object System.Drawing.Size(460, 24)
$gbDeploy.Controls.Add($txtDir)

$btnBrowse           = New-Object System.Windows.Forms.Button
$btnBrowse.Text      = '浏览'
$btnBrowse.Location  = New-Object System.Drawing.Point(560, 27)
$btnBrowse.Size      = New-Object System.Drawing.Size(80, 26)
$gbDeploy.Controls.Add($btnBrowse)

$btnSave             = New-Object System.Windows.Forms.Button
$btnSave.Text        = '保存通道配置'
$btnSave.Location    = New-Object System.Drawing.Point(25, 70)
$btnSave.Size        = New-Object System.Drawing.Size(120, 32)
$gbDeploy.Controls.Add($btnSave)

$btnRecording = New-Object System.Windows.Forms.Button
$btnRecording.Text = '加密录屏设置 / 播放'
$btnRecording.Location = New-Object System.Drawing.Point(400, 112)
$btnRecording.Size = New-Object System.Drawing.Size(240, 28)
$gbDeploy.Controls.Add($btnRecording)
$btnRecording.BringToFront()
$btnRecording.Add_Click({
    $scriptPath = Join-Path $SetupDir 'remote-guard-recording-setup.ps1'
    if (Test-Path -LiteralPath $scriptPath) {
        Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + $scriptPath + '" -Directory "' + $txtDir.Text + '"') -WindowStyle Hidden
    } else { Set-Status '缺少录屏配置程序，请下载完整新版发行包' 'Red' }
})

$btnDeploy           = New-Object System.Windows.Forms.Button
$btnDeploy.Text      = '一键部署（复制脚本+注册任务+启动监控）'
$btnDeploy.Location  = New-Object System.Drawing.Point(155, 70)
$btnDeploy.Size      = New-Object System.Drawing.Size(320, 32)
$gbDeploy.Controls.Add($btnDeploy)

$btnUninstall        = New-Object System.Windows.Forms.Button
$btnUninstall.Text   = '卸载'
$btnUninstall.Location = New-Object System.Drawing.Point(490, 70)
$btnUninstall.Size   = New-Object System.Drawing.Size(150, 32)
$gbDeploy.Controls.Add($btnUninstall)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = '就绪。'
$lblStatus.ForeColor = 'DarkGreen'
$lblStatus.Location  = New-Object System.Drawing.Point(25, 110)
$lblStatus.Size      = New-Object System.Drawing.Size(365, 40)
$gbDeploy.Controls.Add($lblStatus)
$form.Controls.Add($gbDeploy)

# ---------- 工具函数 ----------
function Set-Status([string]$Text, [string]$Color = 'DarkGreen') {
    $lblStatus.Text = $Text
    $lblStatus.ForeColor = $Color
}

function Get-ConfigPath { return (Join-Path $txtDir.Text 'push-channels.json') }

function Save-Config {
    $channels = @()
    if ($chkHayo.Checked -and $txtHayoTok.Text.Trim()) {
        $channels += [ordered]@{ name = 'hayo'; type = 'hayo'; enabled = $true; token = $txtHayoTok.Text.Trim(); base = 'https://hayo.svip8.vip' }
    }
    if ($chkBark.Checked -and $txtBarkKey.Text.Trim()) {
        $channels += [ordered]@{ name = 'bark'; type = 'bark'; enabled = $true; key = $txtBarkKey.Text.Trim(); base = 'https://api.day.app'; group = 'remote-guard'; ttl = 600 }
    }
    if ($channels.Count -eq 0) { Set-Status '没有可保存的通道（需要至少启用一个并填好参数）' 'Red'; return $false }
    $dir = $txtDir.Text
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    [ordered]@{ channels = $channels } | ConvertTo-Json -Depth 5 | Set-Content (Get-ConfigPath) -Encoding UTF8
    Set-Status ('已保存: ' + (Get-ConfigPath))
    return $true
}

function Test-Hayo([string]$Token) {
    try {
        $uri = 'https://hayo.svip8.vip/send?token=' + [uri]::EscapeDataString($Token) + '&title=' + [uri]::EscapeDataString('remote-guard 通道测试') + '&content=' + [uri]::EscapeDataString('hayo 微信通道配置成功 ' + (Get-Date -Format 'HH:mm:ss'))
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15
        if ($r.status -eq 200) { Set-Status ('hayo 测试成功：' + $r.message) } else { Set-Status ('hayo 返回异常: ' + $r.message) 'Red' }
    } catch { Set-Status ('hayo 测试失败: ' + $_.Exception.Message) 'Red' }
}

function Test-Bark([string]$Key) {
    try {
        $uri = 'https://api.day.app/' + [uri]::EscapeDataString($Key) + '/' + [uri]::EscapeDataString('remote-guard 通道测试') + '/' + [uri]::EscapeDataString('Bark 通道配置成功 ' + (Get-Date -Format 'HH:mm:ss')) + '?group=remote-guard&ttl=600'
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15
        if ($r.code -eq 200) { Set-Status 'Bark 测试成功（看手机）' } else { Set-Status ('Bark 返回异常: ' + ($r | ConvertTo-Json -Compress)) 'Red' }
    } catch { Set-Status ('Bark 测试失败: ' + $_.Exception.Message) 'Red' }
}

# ---------- hayo 扫码登录辅助 ----------
# 说明：wxLogin 只返回 ticket，二维码图片需要再向微信换取。
# 这里对“取 ticket”和“换图片”都做多入口 + 重试 + 内容校验，
# 避免单次网络抖动 / CDN 节点异常 / 返回错误页时二维码直接空白。
$script:HayoHosts = @('https://www.hayo.cn', 'https://hayo.svip8.vip')
$script:qrStream  = $null

function Get-HayoLoginTicket {
    $lastErr = '未知错误'
    foreach ($base in $script:HayoHosts) {
        for ($i = 1; $i -le 2; $i++) {
            try {
                $uri = $base + '/wxLogin?_=' + [DateTime]::Now.Ticks
                $res = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15
                if ([string]$res.status -eq '1' -and $res.ticket) { $script:HayoLoginHost = $base; return [string]$res.ticket }
                $lastErr = ($res | ConvertTo-Json -Compress)
            } catch { $lastErr = $_.Exception.Message }
            Start-Sleep -Milliseconds 700
        }
    }
    throw ('获取 ticket 失败: ' + $lastErr)
}

function Get-HayoQrBytes([string]$Ticket) {
    $url = 'https://mp.weixin.qq.com/cgi-bin/showqrcode?ticket=' + [uri]::EscapeDataString($Ticket)
    $lastErr = '未知错误'
    for ($i = 1; $i -le 4; $i++) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) remote-guard/1.1')
            $bytes = $wc.DownloadData($url)
            if ($bytes -and $bytes.Length -gt 1024) {
                $isPng = ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50)
                $isJpg = ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8)
                $isGif = ($bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49)
                if ($isPng -or $isJpg -or $isGif) { return ,$bytes }
                $lastErr = '返回内容不是图片（' + $bytes.Length + ' 字节）'
            } else {
                $lastErr = '返回内容为空或过小（' + $(if ($bytes) { $bytes.Length } else { 0 }) + ' 字节）'
            }
        } catch { $lastErr = $_.Exception.Message }
        Start-Sleep -Milliseconds 800
    }
    throw ('二维码图片获取失败: ' + $lastErr)
}

# ---------- hayo 扫码登录（同步流程 + DoEvents 保持窗口响应） ----------
$btnHayoScan.Add_Click({
    if ($script:scanning) { return }
    $script:scanning = $true
    $btnHayoScan.Enabled = $false
    if ($pbQr.Image) { $pbQr.Image.Dispose() }
    $pbQr.Image = $null
    try {
        Set-Status '正在获取登录二维码...'
        [System.Windows.Forms.Application]::DoEvents()

        $ticket = Get-HayoLoginTicket
        $bytes  = Get-HayoQrBytes $ticket

        # 图片流必须保持存活（GDI+ 要求流在 Image 使用期间不被回收），放到 script 作用域常驻
        if ($script:qrStream) { $script:qrStream.Dispose() }
        $script:qrStream = New-Object System.IO.MemoryStream(,$bytes)
        $pbQr.Image = [System.Drawing.Image]::FromStream($script:qrStream)
        Set-Status '请用微信扫码并确认登录（2 分钟内有效）...'
        [System.Windows.Forms.Application]::DoEvents()
        # 轮询（独立会话，登录成功时服务端种 PHPSESSID）；每 2 秒让 UI 处理消息
        $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $loginHost = $(if ($script:HayoLoginHost) { $script:HayoLoginHost } else { 'https://www.hayo.cn' })
        $deadline = (Get-Date).AddMinutes(2)
        $gotToken = $null
        $pollTick = 0
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 150
            $pollTick += 150
            if ($pollTick -lt 2000) { [System.Windows.Forms.Application]::DoEvents(); continue }
            $pollTick = 0
            try {
                $resp = Invoke-RestMethod -Uri ($loginHost + '/checkWxLogin?ticket=' + [uri]::EscapeDataString($ticket)) -WebSession $sess -TimeoutSec 15
            } catch { continue }
            [System.Windows.Forms.Application]::DoEvents()
            $st = [string]$resp.status
            if ($st -eq '2') { continue }                    # 认证中
            if ($st -eq '1' -or $st -eq '200') {
                if ($resp.data) { $gotToken = [string]$resp.data }
                else {
                    try {
                        $gt = Invoke-RestMethod -Uri ($loginHost + '/getToken') -WebSession $sess -TimeoutSec 15
                        if ($gt.status -eq 200 -and $gt.data) { $gotToken = [string]$gt.data }
                    } catch { }
                }
                break
            }
            if ($st -eq '0' -or $st -eq '4' -or $st -eq '5') { Set-Status '二维码已过期/失败，请重试' 'Red'; break }
        }
        if ($gotToken) {
            $txtHayoTok.Text = $gotToken
            Set-Status '登录成功，token 已自动填入。可点"测试通道"验证。'
        } elseif (-not $gotToken -and (Get-Date) -ge $deadline) {
            Set-Status '扫码超时（2 分钟），请重试' 'Red'
        }
    } catch {
        Set-Status ('扫码登录失败: ' + $_.Exception.Message) 'Red'
    } finally {
        Remove-Item (Join-Path $env:TEMP 'hayo-setup-qr.png') -Force -ErrorAction SilentlyContinue
        $btnHayoScan.Enabled = $true
        $script:scanning = $false
    }
})

$btnHayoTest.Add_Click({
    $tok = $txtHayoTok.Text.Trim()
    if (-not $tok) { Set-Status '请先填入或扫码获取 hayo token' 'Red'; return }
    Test-Hayo $tok
})

$btnBarkTest.Add_Click({
    $k = $txtBarkKey.Text.Trim()
    if (-not $k) { Set-Status '请先填入 Bark key' 'Red'; return }
    Test-Bark $k
})

$btnSave.Add_Click({ [void](Save-Config) })

$btnBrowse.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = '选择 remote-guard 安装目录'
    if ($fbd.ShowDialog() -eq 'OK') { $txtDir.Text = $fbd.SelectedPath }
})

# ---------- 一键部署 ----------
$btnDeploy.Add_Click({
    try {
        $btnDeploy.Enabled = $false
        $dir = $txtDir.Text
        if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }

        # 1. 保存通道配置
        if (-not (Save-Config)) { $btnDeploy.Enabled = $true; return }

        # 2. 复制守护文件
        $files = @('remote-guard.ps1', 'remote-guard-instant.ps1', 'remote-guard-launcher.vbs', 'remote-guard-instant-launcher.vbs', 'recording-common.ps1', 'RecordingCrypto.cs', 'remote-guard-recorder.ps1', 'remote-guard-recording-setup.ps1', 'remote-guard-play.ps1', 'Install-RecordingEncoder.ps1')
        foreach ($f in $files) {
            $src = Join-Path $SetupDir $f
            if (Test-Path $src) { Copy-Item $src -Destination (Join-Path $dir $f) -Force }
            else { Set-Status ('缺少文件: ' + $src) 'Red'; $btnDeploy.Enabled = $true; return }
        }

        # 3. 注册每分钟计划任务（当前用户，普通权限）
        $action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + (Join-Path $dir 'remote-guard-launcher.vbs') + '"')
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
        Unregister-ScheduledTask -TaskName 'remote-guard' -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName 'remote-guard' -Action $action -Trigger $trigger -Settings $settings | Out-Null

        # 4. 杀掉旧即时进程并拉起新的
        $pidFile = Join-Path $dir 'instant.pid'
        if (Test-Path $pidFile) {
            $old = Get-Content $pidFile -ErrorAction SilentlyContinue
            if ($old) { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        }
        Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $dir 'remote-guard-instant-launcher.vbs') + '"') -WindowStyle Hidden
        Start-Sleep -Seconds 4
        $alive = $false
        if (Test-Path $pidFile) {
            $np = Get-Content $pidFile -ErrorAction SilentlyContinue
            if ($np -and (Get-Process -Id ([int]$np) -ErrorAction SilentlyContinue)) { $alive = $true }
        }

        $tstate = (Get-ScheduledTask -TaskName 'remote-guard').State
        Set-Status ("部署完成：任务[{0}] 即时进程[{1}] 通道配置已保存。可用 UU 连一下验证告警。" -f $tstate, $(if ($alive) { '运行中' } else { '未启动!' }))
        if (-not $alive) { $lblStatus.ForeColor = 'Red' }
    } catch {
        Set-Status ('部署失败: ' + $_.Exception.Message) 'Red'
    } finally {
        $btnDeploy.Enabled = $true
    }
})

$btnUninstall.Add_Click({
    try {
        $dir = $txtDir.Text
        Unregister-ScheduledTask -TaskName 'remote-guard' -Confirm:$false -ErrorAction SilentlyContinue
        $recordConfig = Join-Path $dir 'recording.json'
        if (Test-Path -LiteralPath $recordConfig) {
            $recordCfg = Get-Content -LiteralPath $recordConfig -Raw -Encoding UTF8 | ConvertFrom-Json
            $recordCfg.enabled = $false
            $recordCfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ($recordConfig + '.tmp') -Encoding UTF8
            Move-Item -LiteralPath ($recordConfig + '.tmp') -Destination $recordConfig -Force
        }
        $pidFile = Join-Path $dir 'instant.pid'
        if (Test-Path $pidFile) {
            $old = Get-Content $pidFile -ErrorAction SilentlyContinue
            if ($old) { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
        }
        Set-Status '已卸载计划任务并停止即时监控（文件保留，可手动删除目录）'
    } catch { Set-Status ('卸载失败: ' + $_.Exception.Message) 'Red' }
})

# ---------- 启动时读取已有配置 ----------
$existing = Get-ConfigPath
if (Test-Path $existing) {
    try {
        $cfg = Get-Content $existing -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($ch in @($cfg.channels)) {
            if ($ch.type -eq 'hayo') { $txtHayoTok.Text = [string]$ch.token; $chkHayo.Checked = [bool]$ch.enabled }
            if ($ch.type -eq 'bark') { $txtBarkKey.Text = [string]$ch.key; $chkBark.Checked = [bool]$ch.enabled }
        }
        Set-Status ('已载入现有配置: ' + $existing)
    } catch { }
}

[System.Windows.Forms.Application]::Run($form)
