param([string]$FFmpeg)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'windows/recording-common.ps1')
Add-Type -Path (Join-Path $repo 'windows/RecordingCrypto.cs')
$script:checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }; $script:checks++
}
function Reject-Recording([string]$Path, [string]$Key, [string]$Password) {
    $output = New-Object IO.MemoryStream
    $rejected = $false
    try { [RemoteGuard.Vault]::Decrypt($Path,$Key,$Password,$output) } catch { $rejected = $true }
    Assert $rejected 'Invalid recording/key/password must be rejected'
    Assert ($output.Length -eq 0) 'Unauthenticated plaintext must never be released'
    $output.Dispose()
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('remote-guard-recording-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    foreach ($script in Get-ChildItem (Join-Path $repo 'windows') -Filter '*.ps1') {
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0) ('PowerShell parse failed: ' + $script.Name)
    }
    Assert ([RemoteGuard.Vault]::PasswordError('123456789012','123456789012') -eq $null) 'Exactly 12 matching password characters must be accepted'
    Assert ([RemoteGuard.Vault]::PasswordError('一二三四五六七八九十甲乙','一二三四五六七八九十甲乙') -eq $null) 'Twelve matching Chinese characters must be accepted'
    Assert ([RemoteGuard.Vault]::PasswordError(' Abcdef1234 ',' Abcdef1234 ') -eq $null) 'Do not silently trim password whitespace'
    Assert ([RemoteGuard.Vault]::PasswordError('12345678901','12345678901') -like '*不足 12*11*') 'A truly short password must report its length'
    Assert ([RemoteGuard.Vault]::PasswordError('123456789012','') -like '*确认密码*') 'Missing confirmation must request confirmation rather than claim a short password'
    Assert ([RemoteGuard.Vault]::PasswordError('123456789012','123456789013') -like '*不一致*') 'Mismatched passwords must report mismatch rather than length'
    Assert ([RemoteGuard.Vault]::PasswordError('Abcdef123456','abcdef123456') -like '*不一致*') 'Password comparison must be case sensitive'
    $key = Join-Path $scratch 'test.rgkey'
    $password = 'Test12345678'
    $publicKey = [RemoteGuard.Vault]::CreateKey($key,$password)
    Assert ($publicKey -notmatch '<(D|P|Q)>') 'Recording configuration must contain only a public key'
    Assert ([IO.File]::ReadAllText($key) -notmatch 'RSAKeyValue') 'Playback private key must be password encrypted'
    $inputBytes = New-Object byte[] 131079
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($inputBytes); $rng.Dispose()
    $recording = Join-Path $scratch 'test.rgrec'
    $writer = [RemoteGuard.RecordingWriter]::new($recording,$publicKey,1MB)
    try { $writer.Write($inputBytes,$inputBytes.Length); $writer.Complete() } finally { $writer.Dispose() }
    $output = New-Object IO.MemoryStream
    try {
        [RemoteGuard.Vault]::Decrypt($recording,$key,$password,$output)
        Assert ([Convert]::ToBase64String($inputBytes) -ceq [Convert]::ToBase64String($output.ToArray())) 'Round-trip must preserve arbitrary stream bytes'
    } finally { $output.Dispose() }
    Reject-Recording $recording $key 'incorrect password'
    $otherKey = Join-Path $scratch 'other.rgkey'
    [void][RemoteGuard.Vault]::CreateKey($otherKey,$password)
    Reject-Recording $recording $otherKey $password
    $original = [IO.File]::ReadAllBytes($recording)
    foreach ($position in @(0,8,20,425,($original.Length - 1))) {
        $tampered = [byte[]]$original.Clone(); $tampered[$position] = $tampered[$position] -bxor 1
        $path = Join-Path $scratch ('damaged-' + $position + '.rgrec'); [IO.File]::WriteAllBytes($path,$tampered)
        Reject-Recording $path $key $password
    }
    $path = Join-Path $scratch 'truncated.rgrec'; [IO.File]::WriteAllBytes($path,$original[0..($original.Length - 34)])
    Reject-Recording $path $key $password
    $bounded = Join-Path $scratch 'bounded.partial'; $failed=$false
    $writer = [RemoteGuard.RecordingWriter]::new($bounded,$publicKey,4096)
    try { $writer.Write($inputBytes,$inputBytes.Length) } catch { $failed=$true } finally { try { $writer.Dispose() } catch { } }
    Assert $failed 'Hard segment byte limit must stop oversized streams'
    Assert ((Get-Item $bounded).Length -le 4096) 'Encrypted file must never exceed the hard byte limit'

    $now = [datetime]'2026-11-15T08:00:00Z'
    $instant = [pscustomobject]@{schema=3;updated=$now.ToString('o');activeTools=@('UU远程')}
    $main = [pscustomobject]@{lastRun=$now.ToString('o');controlled=$true;tools=@('UU远程')}
    Assert (Test-GuardRecordingSession $instant $null $now) 'Confirmed instantaneous session must start recording without push success'
    $instant.activeTools=$null
    Assert (-not (Test-GuardRecordingSession $instant $null $now)) 'Missing active tool list must never start recording'
    $instant.activeTools=@()
    Assert (-not (Test-GuardRecordingSession $instant $main $now)) 'Instant disconnect must override stale minute-channel UU state'
    $main.tools=@('RDP')
    Assert (Test-GuardRecordingSession $instant $main $now) 'An active RDP session must survive a separate UU disconnect'
    Assert (-not (Test-GuardRecordingSession $instant $main $now.AddMinutes(3))) 'Expired detection data must stop capture'
    Assert (Test-GuardRecordingSession $null $main $now) 'Minute-only detections must start recording'
    $main.controlled=$false
    Assert (-not (Test-GuardRecordingSession $instant $main $now)) 'No active sessions must not record'

    $live = [pscustomobject]@{schema=3;updated=(Get-Date).ToString('o');activeTools=@('UU远程')}
    $live | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scratch 'instant-state.json') -Encoding UTF8
    Assert (Get-GuardRecordingSession $scratch) 'Complete session snapshots must be readable'
    [IO.File]::WriteAllText((Join-Path $scratch 'instant-state.json'), '{')
    Assert (Get-GuardRecordingSession $scratch) 'Temporary malformed snapshots must retain recent confirmed state'
    $live.activeTools=@()
    $live | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scratch 'instant-state.json') -Encoding UTF8
    Assert (-not (Get-GuardRecordingSession $scratch)) 'An explicit disconnect must replace cached active state'

    $storage=Join-Path $scratch 'quota'; [void][IO.Directory]::CreateDirectory($storage)
    $old=Join-Path $storage ('rg-20261115T010000000Z-' + [guid]::NewGuid().ToString('N') + '.rgrec')
    $new=Join-Path $storage ('rg-20261115T020000000Z-' + [guid]::NewGuid().ToString('N') + '.rgrec')
    foreach($path in @($old,$new)) {$file=[IO.File]::Create($path);$file.SetLength(64MB);$file.Dispose()}
    [IO.File]::SetLastWriteTimeUtc($old,[datetime]::UtcNow.AddHours(-1))
    $foreign=Join-Path $storage 'my-important-file.txt';[IO.File]::WriteAllText($foreign,'keep')
    $cfg=[pscustomobject]@{directory=$storage;maxStorageMB=128;minFreeMB=128}
    Limit-GuardRecordingStorage $cfg 1MB
    Assert (-not (Test-Path -LiteralPath $old)) 'Quota must remove oldest recording first'
    Assert (Test-Path -LiteralPath $new) 'Quota must retain newest recording'
    Assert (Test-Path -LiteralPath $foreign) 'Quota must preserve unrelated files'
    $failed=$false;try {Limit-GuardRecordingStorage $cfg 129MB} catch {$failed=$true}
    Assert $failed 'Oversized segment reserve must be rejected before deleting recordings'

    if ($FFmpeg) {
        $clip=Join-Path $scratch 'synthetic.rgrec.partial'
        $captureCfg=[pscustomobject]@{fps=5;width=1280;bitrateKbps=400;segmentSeconds=2}
        $arguments=(Get-GuardRecordingArguments $captureCfg) -replace '-f gdigrab -framerate 5 -draw_mouse 1 -i desktop', '-re -f lavfi -i testsrc2=size=1920x1080:rate=5'
        $capture=[RemoteGuard.Capture]::new($FFmpeg,$arguments,$publicKey,$clip,2MB)
        try {Start-Sleep -Seconds 3;$capture.Finish()} finally {$capture.Dispose()}
        $video=New-Object IO.MemoryStream
        try {
            [RemoteGuard.Vault]::Decrypt($clip,$key,$password,$video)
            Assert ($video.Length -gt 1024) 'Synthetic capture must produce a nonempty encrypted MP4'
            $p=New-Object Diagnostics.Process
            $p.StartInfo=New-Object Diagnostics.ProcessStartInfo($FFmpeg,'-hide_banner -loglevel error -i pipe:0 -f null -')
            $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true;$p.StartInfo.RedirectStandardInput=$true;$p.StartInfo.RedirectStandardError=$true
            [void]$p.Start();$err=$p.StandardError.ReadToEndAsync()
            $video.Position=0;$video.CopyTo($p.StandardInput.BaseStream);$p.StandardInput.Close();$p.WaitForExit()
            Assert ($p.ExitCode -eq 0) ('Decrypted synthetic MP4 must decode: '+$err.Result);$p.Dispose()
        } finally {$video.Dispose()}
        $earlyClip=Join-Path $scratch 'early-stop.partial'
        $longArguments=$arguments -replace '-t 2 ', '-t 60 '
        $capture=[RemoteGuard.Capture]::new($FFmpeg,$longArguments,$publicKey,$earlyClip,2MB)
        try {Start-Sleep -Seconds 2;$capture.Finish()} finally {$capture.Dispose()}
        $earlyVideo=New-Object IO.MemoryStream
        try {[RemoteGuard.Vault]::Decrypt($earlyClip,$key,$password,$earlyVideo);Assert ($earlyVideo.Length -gt 1024) 'Disconnect must finalize an authenticated video before segment timeout'} finally {$earlyVideo.Dispose()}
    }
    Write-Output ('Recording regression checks passed: ' + $script:checks)
} finally {
    # Only remove exact files created by this test, then its two known empty directories.
    Get-ChildItem -LiteralPath $scratch -File | ForEach-Object {Remove-Item -LiteralPath $_.FullName}
    if(Test-Path -LiteralPath (Join-Path $scratch 'quota')) {
        Get-ChildItem -LiteralPath (Join-Path $scratch 'quota') -File | ForEach-Object {Remove-Item -LiteralPath $_.FullName}
        Remove-Item -LiteralPath (Join-Path $scratch 'quota')
    }
    Remove-Item -LiteralPath $scratch
}
