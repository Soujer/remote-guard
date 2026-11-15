param([string]$Recording, [string]$KeyFile, [string]$Player)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'RecordingCrypto.cs')
function Select-PlaybackFile([string]$Title, [string]$Filter) {
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = $Title; $dialog.Filter = $Filter
    try { if ($dialog.ShowDialog() -eq 'OK') { return $dialog.FileName } } finally { $dialog.Dispose() }
    return $null
}
try {
    if (-not $Recording) { $Recording = Select-PlaybackFile '选择加密录像' '加密录像 (*.rgrec)|*.rgrec' }
    if (-not $Recording) { exit }
    if (-not $KeyFile) { $KeyFile = Select-PlaybackFile '选择你的播放私钥' '播放私钥 (*.rgkey)|*.rgkey' }
    if (-not $KeyFile) { exit }
    if (-not $Player) {
        try {
            $cfg = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'recording.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $candidate = Join-Path (Split-Path $cfg.ffmpeg -Parent) 'ffplay.exe'
            if (Test-Path -LiteralPath $candidate) { $Player = $candidate }
        } catch { }
    }
    if (-not $Player) { $Player = Select-PlaybackFile '选择 FFplay 播放器（FFmpeg 的 bin 目录）' 'ffplay.exe|ffplay.exe' }
    if (-not $Player) { exit }
    $form = New-Object Windows.Forms.Form
    $form.Text = '解锁录像'; $form.Size = New-Object Drawing.Size(400,160); $form.StartPosition = 'CenterScreen'
    $label = New-Object Windows.Forms.Label; $label.Text = '输入播放私钥的密码'; $label.SetBounds(15,15,350,25)
    $password = New-Object Windows.Forms.TextBox; $password.UseSystemPasswordChar = $true; $password.SetBounds(15,45,350,25)
    $ok = New-Object Windows.Forms.Button; $ok.Text = '播放'; $ok.SetBounds(265,80,100,30); $ok.DialogResult = 'OK'
    $form.Controls.AddRange(@($label,$password,$ok)); $form.AcceptButton = $ok
    try {
        if ($form.ShowDialog() -eq 'OK') { [RemoteGuard.Vault]::Play($Recording,$KeyFile,$password.Text,$Player) }
    } finally { $password.Clear(); $form.Dispose() }
} catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, '录像播放失败') }
