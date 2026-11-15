param([string]$Directory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'RecordingCrypto.cs')
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = '加密录屏设置'; $form.Size = New-Object Drawing.Size(680,490)
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
function Add-RecordingLabel([string]$Text, [int]$Y) {
    $label = New-Object Windows.Forms.Label; $label.Text = $Text; $label.SetBounds(20,$Y,620,23); $form.Controls.Add($label)
}
$enabled = New-Object Windows.Forms.CheckBox; $enabled.Text = '确认远程连接后自动录屏（只录画面，无声音）'; $enabled.SetBounds(20,15,620,25)
$enabled.Checked = $true; $form.Controls.Add($enabled)
Add-RecordingLabel '录像目录' 55
$folder = New-Object Windows.Forms.TextBox; $folder.SetBounds(20,80,525,25); $folder.Text = Join-Path $Directory 'recordings'; $form.Controls.Add($folder)
$browse = New-Object Windows.Forms.Button; $browse.Text = '浏览'; $browse.SetBounds(555,78,85,28); $form.Controls.Add($browse)
Add-RecordingLabel '内置录屏组件（无需下载，也可选择现有 ffmpeg.exe）' 115
$encoder = New-Object Windows.Forms.TextBox; $encoder.SetBounds(20,140,430,25); $encoder.Text = Join-Path $Directory 'ffmpeg\ffmpeg.exe'; $form.Controls.Add($encoder)
$select = New-Object Windows.Forms.Button; $select.Text = '选择'; $select.SetBounds(460,138,80,28); $form.Controls.Add($select)
$download = New-Object Windows.Forms.Button; $download.Text = '释放组件'; $download.SetBounds(550,138,90,28); $form.Controls.Add($download)
Add-RecordingLabel '总存储上限（MB），达到上限自动删除最旧片段' 175
$quota = New-Object Windows.Forms.NumericUpDown; $quota.SetBounds(20,200,150,25); $quota.Minimum = 128; $quota.Maximum = 1048576; $quota.Value = 2048; $form.Controls.Add($quota)
Add-RecordingLabel '私钥密码（左侧，至少 12 位）             再次输入密码（右侧确认）' 235
$password = New-Object Windows.Forms.TextBox; $password.SetBounds(20,260,300,25); $password.UseSystemPasswordChar = $true; $form.Controls.Add($password)
$confirm = New-Object Windows.Forms.TextBox; $confirm.SetBounds(335,260,305,25); $confirm.UseSystemPasswordChar = $true; $form.Controls.Add($confirm)
Add-RecordingLabel '左侧密码，右侧确认。私钥和密码丢失后无法恢复录像，请另行备份。' 295
Add-RecordingLabel '默认：5 分钟分段 / 最高 1080p / 5 帧每秒 / 1 Mbps / 预留 512 MB' 320
$save = New-Object Windows.Forms.Button; $save.Text = '保存设置'; $save.SetBounds(20,355,120,32); $form.Controls.Add($save)
$play = New-Object Windows.Forms.Button; $play.Text = '打开加密录像'; $play.SetBounds(155,355,140,32); $form.Controls.Add($play)
$status = New-Object Windows.Forms.Label; $status.SetBounds(20,395,620,45); $form.Controls.Add($status)
$status.Text = '尚未启用：首次使用请先保存播放私钥和录屏设置。'
$script:recordingConfig = $null
$configPath = Join-Path $Directory 'recording.json'
if (Test-Path -LiteralPath $configPath) {
    try {
        $script:recordingConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $enabled.Checked = [bool]$script:recordingConfig.enabled
        if ($script:recordingConfig.directory) { $folder.Text = [string]$script:recordingConfig.directory }
        if ($script:recordingConfig.ffmpeg) { $encoder.Text = [string]$script:recordingConfig.ffmpeg }
        if ($script:recordingConfig.maxStorageMB) { $quota.Value = [decimal]$script:recordingConfig.maxStorageMB }
        $status.Text = '已载入现有配置。首次启用需保存播放私钥；已有密钥会保留。'
    } catch { [void][Windows.Forms.MessageBox]::Show('现有配置无法读取，请先备份并检查 recording.json'); exit 1 }
}
$browse.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    try { if ($dialog.ShowDialog() -eq 'OK') { $folder.Text = $dialog.SelectedPath } } finally { $dialog.Dispose() }
})
$select.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog; $dialog.Filter = 'ffmpeg.exe|ffmpeg.exe'
    try { if ($dialog.ShowDialog() -eq 'OK') { $encoder.Text = $dialog.FileName } } finally { $dialog.Dispose() }
})
$download.Add_Click({
    $download.Enabled = $false
    try {
        $status.Text = '正在释放并校验内置组件……'; $form.Refresh()
        $encoder.Text = & (Join-Path $PSScriptRoot 'Install-RecordingEncoder.ps1') -Directory (Join-Path $Directory 'ffmpeg')
        $status.Text = '内置组件已就绪，无需下载。'
    } catch { $status.Text = '组件释放失败: ' + $_.Exception.Message }
    finally { $download.Enabled = $true }
})
$save.Add_Click({
    try {
        [void][IO.Directory]::CreateDirectory($Directory)
        if (-not $enabled.Checked) {
            if (-not $script:recordingConfig) { $script:recordingConfig = [pscustomobject]@{ schema=1; enabled=$false } }
            $script:recordingConfig.enabled = $false
            $script:recordingConfig | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ($configPath + '.tmp') -Encoding UTF8
            Move-Item -LiteralPath ($configPath + '.tmp') -Destination $configPath -Force
            $status.Text = '自动录屏已关闭，正在录制的片段将保存后停止。'; return
        }
        if (-not (Test-Path -LiteralPath $encoder.Text -PathType Leaf)) {
            $encoder.Text = & (Join-Path $PSScriptRoot 'Install-RecordingEncoder.ps1') -Directory (Join-Path $Directory 'ffmpeg')
        }
        if ($folder.Text -notmatch '^[A-Za-z]:\\') { throw '请选择本机磁盘上的绝对路径' }
        $publicKey = $null
        if ($script:recordingConfig) { $publicKey = $script:recordingConfig.publicKey }
        if (-not $publicKey) {
            $passwordError = [RemoteGuard.Vault]::PasswordError($password.Text,$confirm.Text)
            if ($passwordError) { throw $passwordError }
            $dialog = New-Object Windows.Forms.SaveFileDialog
            $dialog.Title = '保存播放私钥（请备份到安全位置）'; $dialog.Filter = '播放私钥 (*.rgkey)|*.rgkey'; $dialog.FileName = 'remote-guard-playback.rgkey'
            try {
                if ($dialog.ShowDialog() -ne 'OK') { return }
                if (Test-Path -LiteralPath $dialog.FileName) { throw '请选择新文件名，不能覆盖已有私钥' }
                $publicKey = [RemoteGuard.Vault]::CreateKey($dialog.FileName, $password.Text)
            } finally { $dialog.Dispose() }
            # Keep the matching public key in memory even if saving the config needs a retry.
            $script:recordingConfig = [pscustomobject]@{publicKey=$publicKey;enabled=$false}
        }
        $cfg = [ordered]@{schema=1;enabled=$true;directory=[IO.Path]::GetFullPath($folder.Text);ffmpeg=[IO.Path]::GetFullPath($encoder.Text);publicKey=$publicKey;segmentSeconds=300;fps=5;width=1920;bitrateKbps=1000;maxStorageMB=[int]$quota.Value;minFreeMB=512}
        $cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ($configPath + '.tmp') -Encoding UTF8
        Move-Item -LiteralPath ($configPath + '.tmp') -Destination $configPath -Force
        $script:recordingConfig = [pscustomobject]$cfg
        $password.Clear(); $confirm.Clear()
        $status.Text = '已启用：确认远程连接后自动录屏。请妥善备份私钥与密码。'
    } catch { $status.Text = '保存失败: ' + $_.Exception.Message }
})
$play.Add_Click({
    Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + (Join-Path $PSScriptRoot 'remote-guard-play.ps1') + '"') -WindowStyle Hidden
})
try { [Windows.Forms.Application]::Run($form) } finally { $password.Clear(); $confirm.Clear(); $form.Dispose() }
