# ============================================================
# remote-guard-setup.ps1 — 统一 Windows 桌面程序
#
# 功能：
#   1) hayo 微信通道：扫码登录自动获取 token（wxLogin -> 二维码 -> checkWxLogin 轮询 -> getToken）
#   2) Bark 通道：手动填 key
#   3) 通道独立测试按钮（发送测试消息验证）
#   4) 保存 push-channels.json
#   5) 一键部署：复制守护脚本 + 注册每分钟计划任务 + 拉起即时监控进程
#
# 打包：scripts/Build-Release.ps1（内置资源，无需管理员权限）
param([string]$InstallRoot,[switch]$SmokeTest)
# BUILD_PAYLOAD
$ErrorActionPreference='Stop'
trap {
    if($SmokeTest -and $InstallRoot){[void][IO.Directory]::CreateDirectory($InstallRoot);[IO.File]::WriteAllText((Join-Path $InstallRoot 'desktop-smoke-error.txt'),$_.ToString());exit 1}
    throw $_
}
if(-not $script:GuardBuildVersion){$script:GuardBuildVersion='1.3.0'}
# ============================================================

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 部分老系统/老 .NET 默认只启用 TLS1.0，访问 mp.weixin.qq.com 会握手失败导致二维码下载不到
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$SetupDir    = $PSScriptRoot
# ps2exe 编译后没有脚本路径，守护文件仍位于 exe 同目录。
if (-not $SetupDir) { $SetupDir = [AppDomain]::CurrentDomain.BaseDirectory }
$GuiExecutable = Join-Path $SetupDir 'remote-guard.exe'
if (-not $PSScriptRoot) { $GuiExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
if ($script:GuardEmbeddedPayload) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $payloadRoot = Join-Path $env:LOCALAPPDATA ('RemoteGuard\payload\' + $script:GuardBuildVersion + '-' + $script:GuardBuildCommit)
    [void][IO.Directory]::CreateDirectory($payloadRoot)
    $memory = [IO.MemoryStream]::new([Convert]::FromBase64String($script:GuardEmbeddedPayload))
    $archive = [IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($entry in $archive.Entries) {
            $target=Join-Path $payloadRoot $entry.FullName;$valid=$false
            if(Test-Path -LiteralPath $target){
                $hasher=[Security.Cryptography.SHA256]::Create();$stream=$entry.Open()
                try{$expected=[BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','');$valid=((Get-FileHash -LiteralPath $target).Hash -eq $expected)}finally{$stream.Dispose();$hasher.Dispose()}
            }
            if(-not $valid){[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$true)}
        }
    }finally { $archive.Dispose(); $memory.Dispose() }
    $SetupDir = $payloadRoot
}
. (Join-Path $SetupDir 'update-common.ps1')
. (Join-Path $SetupDir 'recording-common.ps1')
. (Join-Path $SetupDir 'recording-ui.ps1')
if (-not ('RemoteGuard.Preview' -as [type])) { Add-Type -Path @((Join-Path $SetupDir 'RecordingCrypto.cs'),(Join-Path $SetupDir 'DesktopRuntime.cs')) }
if (-not $InstallRoot) {
    if (Test-Path -LiteralPath (Join-Path (Split-Path $GuiExecutable -Parent) 'push-channels.json')) { $InstallRoot = Split-Path $GuiExecutable -Parent }
    else {
        try {
            $installedTask = Get-ScheduledTask -TaskName remote-guard -ErrorAction Stop
            if ($installedTask.Actions.Arguments -match '"([^"\r\n]+)\\remote-guard-launcher\.vbs"') { $InstallRoot = $Matches[1] }
        } catch { }
    }
    if (-not $InstallRoot) { $InstallRoot = Join-Path $env:LOCALAPPDATA 'RemoteGuard\app' }
}
if (Test-Path -LiteralPath (Join-Path $InstallRoot 'updating.flag')) { exit }

# ---------- 布局 ----------
$form                = New-Object System.Windows.Forms.Form
$form.Text           = 'remote-guard · 远程守护'
$form.Size           = New-Object System.Drawing.Size(870, 800)
$form.StartPosition  = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox    = $false
$heading=New-Object Windows.Forms.Label;$heading.Text='远程守护';$heading.Font=New-Object Drawing.Font('Microsoft YaHei UI',18,[Drawing.FontStyle]::Bold);$heading.SetBounds(20,15,500,40);$form.Controls.Add($heading)
$footer=New-Object Windows.Forms.Label;$footer.SetBounds(20,715,815,30);$footer.Text='就绪';$form.Controls.Add($footer)
$tabs=New-Object Windows.Forms.TabControl;$tabs.SetBounds(15,65,825,640);$form.Controls.Add($tabs)
$tabOverview=New-Object Windows.Forms.TabPage('监控')
$tabPush=New-Object Windows.Forms.TabPage('推送')
$tabRecording=New-Object Windows.Forms.TabPage('加密录屏')
$tabLibrary=New-Object Windows.Forms.TabPage('录像播放')
$tabUpdate=New-Object Windows.Forms.TabPage('更新')
$tabs.TabPages.AddRange(@($tabOverview,$tabPush,$tabRecording,$tabLibrary,$tabUpdate))

# === hayo 微信通道组 ===
$gbHayo              = New-Object System.Windows.Forms.GroupBox
$gbHayo.Text         = 'hayo 微信推送通道（扫码自动获取 token）'
$gbHayo.Location     = New-Object System.Drawing.Point(15, 12)
$gbHayo.Size         = New-Object System.Drawing.Size(675, 300)

$pbQr                = New-Object System.Windows.Forms.PictureBox
$pbQr.Location       = New-Object System.Drawing.Point(15, 25)
$pbQr.Size           = New-Object System.Drawing.Size(175, 240)
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
$tabPush.Controls.Add($gbHayo)

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
$tabPush.Controls.Add($gbBark)

# === 部署组 ===
$gbDeploy            = New-Object System.Windows.Forms.GroupBox
$gbDeploy.Text       = '本机监控'
$gbDeploy.Location   = New-Object System.Drawing.Point(15, 15)
$gbDeploy.Size       = New-Object System.Drawing.Size(780, 200)

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
$btnSave.SetBounds(25,460,150,35)
$tabPush.Controls.Add($btnSave)

$btnDeploy           = New-Object System.Windows.Forms.Button
$btnDeploy.Text      = '启动 / 更新监控'
$btnDeploy.Location  = New-Object System.Drawing.Point(25, 75)
$btnDeploy.Size      = New-Object System.Drawing.Size(240, 38)
$gbDeploy.Controls.Add($btnDeploy)

$btnUninstall        = New-Object System.Windows.Forms.Button
$btnUninstall.Text   = '停止监控'
$btnUninstall.Location = New-Object System.Drawing.Point(280, 75)
$btnUninstall.Size   = New-Object System.Drawing.Size(160, 38)
$gbDeploy.Controls.Add($btnUninstall)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = '就绪。'
$lblStatus.ForeColor = 'DarkGreen'
$lblStatus.Location  = New-Object System.Drawing.Point(25, 130)
$lblStatus.Size      = New-Object System.Drawing.Size(725, 55)
$gbDeploy.Controls.Add($lblStatus)
$tabOverview.Controls.Add($gbDeploy)
$liveStatus=New-Object Windows.Forms.Label;$liveStatus.SetBounds(30,240,740,130);$liveStatus.Font=New-Object Drawing.Font('Microsoft YaHei UI',12);$tabOverview.Controls.Add($liveStatus)
$hint=New-Object Windows.Forms.Label;$hint.Text="确认远程连接时通知，并按录屏设置加密保存画面。`r`n关闭此窗口后，已启动的监控仍在后台运行。";$hint.SetBounds(30,400,740,80);$tabOverview.Controls.Add($hint)
$recordingView=New-GuardRecordingView $tabRecording $txtDir $SetupDir
$libraryView=New-GuardLibraryView $tabLibrary $txtDir
$tabs.Add_SelectedIndexChanged({
    try {
        if($tabs.SelectedTab -eq $tabRecording -and $recordingView.Path -ne $txtDir.Text){Load-GuardRecordingView $recordingView}
        if($tabs.SelectedTab -eq $tabLibrary){Refresh-GuardLibrary $libraryView}
    }catch{Set-Status $_.Exception.Message 'Red'}
})

# ---------- 工具函数 ----------
function Set-Status([string]$Text, [string]$Color = 'DarkGreen') {
    $lblStatus.Text = $Text
    $lblStatus.ForeColor = $Color
    $footer.Text=$Text;$footer.ForeColor=$Color
}

function Get-ConfigPath { return (Join-Path $txtDir.Text 'push-channels.json') }

function Save-Config {
    try {
    $channels = @()
    if ($txtHayoTok.Text.Trim()) {
        $channels += [ordered]@{ name = 'hayo'; type = 'hayo'; enabled = $chkHayo.Checked; token = $txtHayoTok.Text.Trim(); base = 'https://hayo.svip8.vip' }
    }
    if ($txtBarkKey.Text.Trim()) {
        $channels += [ordered]@{ name = 'bark'; type = 'bark'; enabled = $chkBark.Checked; key = $txtBarkKey.Text.Trim(); base = 'https://api.day.app'; group = 'remote-guard'; ttl = 600 }
    }
    if(Test-Path -LiteralPath (Get-ConfigPath)) {
        $old=Get-Content -LiteralPath (Get-ConfigPath) -Raw -Encoding UTF8 | ConvertFrom-Json
        $channels+=@($old.channels | Where-Object {$_.type -notin @('bark','hayo')})
    }
    $dir = $txtDir.Text
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    [ordered]@{ channels = @($channels) } | ConvertTo-Json -Depth 5 | Set-Content ((Get-ConfigPath)+'.tmp') -Encoding UTF8
    Move-Item -LiteralPath ((Get-ConfigPath)+'.tmp') -Destination (Get-ConfigPath) -Force
    Set-Status ('已保存: ' + (Get-ConfigPath))
    return $true
    }catch{Set-Status ('保存失败: '+$_.Exception.Message) 'Red';return $false}
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

        # The single executable carries the runtime. Prepare a complete install set before pausing monitors.
        if(-not(Test-Path -LiteralPath $GuiExecutable)){throw '请运行编译后的 remote-guard.exe 启动监控'}
        $source=Join-Path ([IO.Path]::GetTempPath()) ('remote-guard-install-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($source)
        foreach($f in (Get-GuardPackageFiles)) {
            if($f -in @('remote-guard.exe','remote-guard-setup.exe')){$src=$GuiExecutable}else{$src=Join-Path $SetupDir $f}
            Copy-Item -LiteralPath $src -Destination (Join-Path $source $f) -ErrorAction Stop
        }
        $previousTask=Get-ScheduledTask -TaskName remote-guard -ErrorAction SilentlyContinue
        $resume=($previousTask -and $previousTask.State -ne 'Disabled' -and $previousTask.Actions.Arguments -like ('*'+$dir+'\remote-guard-launcher.vbs*'))
        try{Stop-GuardRuntime $dir;[void](Install-GuardFiles $source $dir)}catch{if($resume){Start-GuardRuntime $dir};throw}

        # 3. 注册每分钟计划任务（当前用户，普通权限）
        $action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + (Join-Path $dir 'remote-guard-launcher.vbs') + '"')
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
        Unregister-ScheduledTask -TaskName 'remote-guard' -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName 'remote-guard' -Action $action -Trigger $trigger -Settings $settings | Out-Null

        # 4. 注册更新任务并拉起后台监控
        Register-GuardUpdates $dir
        Start-GuardRuntime $dir
        $pidFile = Join-Path $dir 'instant.pid'
        Start-Sleep -Seconds 4
        $alive = $false
        if (Test-Path $pidFile) {
            $np = Get-Content $pidFile -ErrorAction SilentlyContinue
            if ($np -and (Get-Process -Id ([int]$np) -ErrorAction SilentlyContinue)) { $alive = $true }
        }

        $tstate = (Get-ScheduledTask -TaskName 'remote-guard').State
        Set-Status ("监控已启动；后台检测[{0}]，自动更新已注册。" -f $(if ($alive) { '运行中' } else { '未启动!' }))
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
        Stop-GuardRuntime $dir
        Unregister-ScheduledTask -TaskName 'remote-guard' -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'remote-guard-update' -Confirm:$false -ErrorAction SilentlyContinue
        Set-Status '监控已停止；推送、密钥和录像均保留。'
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

# ---------- Gitee 自动更新 ----------
$versionLabel=New-Object Windows.Forms.Label;$versionLabel.SetBounds(25,25,755,35);$versionLabel.Text='当前软件版本 v'+$script:GuardBuildVersion+' · 更新来源：Gitee / Soujer / remote-guard';$tabUpdate.Controls.Add($versionLabel)
$autoUpdate=New-Object Windows.Forms.CheckBox;$autoUpdate.Text='自动检查并安装正式版更新（每 6 小时）';$autoUpdate.SetBounds(25,80,755,30);$autoUpdate.Checked=$true;$tabUpdate.Controls.Add($autoUpdate)
try{$settings=Get-Content -LiteralPath (Join-Path $InstallRoot 'updates.json') -Raw -ErrorAction Stop|ConvertFrom-Json;$autoUpdate.Checked=[bool]$settings.enabled}catch{}
$checkUpdate=New-Object Windows.Forms.Button;$checkUpdate.Text='检查更新';$checkUpdate.SetBounds(25,140,160,38);$tabUpdate.Controls.Add($checkUpdate)
$installUpdate=New-Object Windows.Forms.Button;$installUpdate.Text='更新并重启';$installUpdate.SetBounds(205,140,160,38);$installUpdate.Enabled=$false;$tabUpdate.Controls.Add($installUpdate)
$updateStatus=New-Object Windows.Forms.Label;$updateStatus.SetBounds(25,210,755,110);$updateStatus.Text="自动更新会保留推送配置、录屏设置、私钥和录像。`r`n远程连接或录屏期间延后安装；软件关闭后也会自动检查。";$tabUpdate.Controls.Add($updateStatus)
$script:updateJob=$null;$script:availableUpdate=$null;$script:lastCheck=[datetime]::MinValue
$script:manualUpdating=$false
function Begin-GuardUpdateCheck {
    if($script:updateJob){return}
    $checkUpdate.Enabled=$false;$updateStatus.Text='正在检查 Gitee 正式发行版……'
    $script:updateJob=Start-Job -ScriptBlock {param($path,$version);. (Join-Path $path 'update-common.ps1');Get-GuardUpdate ([version]$version)} -ArgumentList $SetupDir,$script:GuardBuildVersion
    $script:lastCheck=Get-Date
}
$checkUpdate.Add_Click({Begin-GuardUpdateCheck})
$autoUpdate.Add_CheckedChanged({
    try{[void][IO.Directory]::CreateDirectory($txtDir.Text);@{enabled=$autoUpdate.Checked}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $txtDir.Text 'updates.json') -Encoding UTF8;Set-Status '自动更新偏好已保存。'}catch{Set-Status ('保存失败: '+$_.Exception.Message) 'Red'}
})
$installUpdate.Add_Click({
    try{
        if(Get-GuardRecordingSession $txtDir.Text){throw '远程会话尚未结束，结束后再安装更新'}
        $worker=Join-Path $txtDir.Text 'remote-guard-update.ps1'
        if(-not(Test-Path -LiteralPath $worker)){throw '请先在监控页面启动或更新监控'}
        $script:manualUpdating=$true
        Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$worker+'" -InstallRoot "'+$txtDir.Text+'" -WaitForPid '+$PID+' -Relaunch') -WindowStyle Hidden
        $form.Close()
    }catch{$updateStatus.Text=$_.Exception.Message}
})
$statusTimer=New-Object Windows.Forms.Timer;$statusTimer.Interval=3000
$statusTimer.Add_Tick({
    try{
        $task=Get-ScheduledTask -TaskName remote-guard -ErrorAction SilentlyContinue
        $taskHere=($task -and $task.Actions.Arguments -like ('*'+$txtDir.Text+'\remote-guard-launcher.vbs*'))
        $monitor=if($taskHere -and $task.State -ne 'Disabled'){'后台监控已启动'}else{'监控未启动'}
        $session=if(-not $taskHere -or $task.State -eq 'Disabled'){'启动监控后显示远程状态'}elseif(Get-GuardRecordingSession $txtDir.Text){'已确认远程会话'}else{'当前未确认远程会话'}
        $record='录屏未启用'
        try{$cfg=Get-Content -LiteralPath (Join-Path $txtDir.Text 'recording.json') -Raw -ErrorAction Stop|ConvertFrom-Json;if($cfg.enabled){$record='加密录屏待命';if(@(Get-GuardOwnedProcess $txtDir.Text 'remote-guard-recorder.ps1').Count -gt 0){$record='加密录屏进行中'}}}catch{}
        $liveStatus.Text=$monitor+"`r`n"+$session+"`r`n"+$record
        if($script:updateJob -and $script:updateJob.State -in @('Completed','Failed','Stopped')){
            try{$script:availableUpdate=Receive-Job $script:updateJob -ErrorAction Stop;$installUpdate.Enabled=($null -ne $script:availableUpdate);$updateStatus.Text=if($script:availableUpdate){'发现新版 v'+$script:availableUpdate.Version+'。空闲时将自动安装，也可点击更新并重启。'}else{'已是最新正式版。'}}catch{$updateStatus.Text='检查更新失败，稍后自动重试。'}
            Remove-Job $script:updateJob -Force;$script:updateJob=$null;$checkUpdate.Enabled=$true
        }
        if($autoUpdate.Checked -and ((Get-Date)-$script:lastCheck).TotalHours -ge 6){Begin-GuardUpdateCheck}
    }catch{$liveStatus.Text='状态暂时无法读取，稍后刷新。'}
})
$form.Add_FormClosed({
    $statusTimer.Stop();$statusTimer.Dispose();Stop-GuardPreview $libraryView;$libraryView.Timer.Dispose();$recordingView.Password.Clear();$recordingView.Confirm.Clear();$libraryView.Password.Clear()
    if($libraryView.Picture.Image){$libraryView.Picture.Image.Dispose()}
    if($script:updateJob){Stop-Job $script:updateJob;Remove-Job $script:updateJob -Force;$script:updateJob=$null}
    $worker=Join-Path $txtDir.Text 'remote-guard-update.ps1'
    if(-not $script:manualUpdating -and $autoUpdate.Checked -and (Test-Path -LiteralPath $worker)){
        Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$worker+'" -InstallRoot "'+$txtDir.Text+'" -WaitForPid '+$PID+' -Auto') -WindowStyle Hidden
    }
})
if($SmokeTest){
    & $libraryView.RefreshAction
    & $libraryView.StopAction
    $result=[pscustomobject]@{Tabs=@($tabs.TabPages|ForEach-Object Text);RecordingEmbedded=($recordingView.Enabled.Parent -eq $tabRecording);PlayerEmbedded=($libraryView.Picture.Parent -eq $tabLibrary);UpdaterPresent=($checkUpdate.Parent -eq $tabUpdate)}|ConvertTo-Json
    if($script:GuardEmbeddedPayload){[void][IO.Directory]::CreateDirectory($InstallRoot);[IO.File]::WriteAllText((Join-Path $InstallRoot 'desktop-smoke.json'),$result)}else{Write-Output $result}
    $form.Dispose();$statusTimer.Dispose();$libraryView.Timer.Dispose();return
}
$statusTimer.Start()
[System.Windows.Forms.Application]::Run($form)
