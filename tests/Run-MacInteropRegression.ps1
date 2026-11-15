param([string]$WriteFixture,[string]$ReadFixture,[string]$FFmpeg)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'windows/RecordingCrypto.cs')
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('remote-guard-interop-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $key=Join-Path $scratch 'test.rgkey';$recording=Join-Path $scratch 'test.rgrec'
    if($WriteFixture){
        $password='Interop123456';$bytes=[Text.Encoding]::UTF8.GetBytes('test-only Windows CNG interoperability fixture')
        $public=[RemoteGuard.Vault]::CreateKey($key,$password)
        $writer=[RemoteGuard.RecordingWriter]::new($recording,$public,1MB)
        try{$writer.Write($bytes,$bytes.Length);$writer.Complete()}finally{$writer.Dispose()}
        $fixture=@{notice='PUBLIC TEST FIXTURE ONLY. This is not a user key or password.';password=$password;key=[Convert]::ToBase64String([IO.File]::ReadAllBytes($key));recording=[Convert]::ToBase64String([IO.File]::ReadAllBytes($recording));plaintext=[Convert]::ToBase64String($bytes)}
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($WriteFixture),($fixture|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        'Generated public Windows interoperability fixture'
    }
    if($ReadFixture){
        $fixture=[IO.File]::ReadAllText([IO.Path]::GetFullPath($ReadFixture))|ConvertFrom-Json
        [IO.File]::WriteAllBytes($key,[Convert]::FromBase64String($fixture.key));[IO.File]::WriteAllBytes($recording,[Convert]::FromBase64String($fixture.recording))
        $output=New-Object IO.MemoryStream
        try{[RemoteGuard.Vault]::Decrypt($recording,$key,$fixture.password,$output);if([Convert]::ToBase64String($output.ToArray()) -cne $fixture.plaintext){throw 'Mac -> Windows plaintext differs'}}finally{$output.Dispose()}
        if($fixture.video -and $FFmpeg){
            [IO.File]::WriteAllBytes($recording,[Convert]::FromBase64String($fixture.video));$output=New-Object IO.MemoryStream
            try{[RemoteGuard.Vault]::Decrypt($recording,$key,$fixture.password,$output);$process=New-Object Diagnostics.Process;$process.StartInfo.FileName=[IO.Path]::GetFullPath($FFmpeg);$process.StartInfo.Arguments='-hide_banner -loglevel error -i pipe:0 -f null -';$process.StartInfo.UseShellExecute=$false;$process.StartInfo.RedirectStandardInput=$true;[void]$process.Start();$output.Position=0;$output.CopyTo($process.StandardInput.BaseStream);$process.StandardInput.Close();$process.WaitForExit();if($process.ExitCode -ne 0){throw 'Mac encrypted video cannot decode on Windows'}}finally{$output.Dispose();if($process){$process.Dispose()}}
        }
        'Mac -> Windows key, encrypted payload and video interoperability verified'
    }
}finally{
    Get-ChildItem -LiteralPath $scratch -File|ForEach-Object{Remove-Item -LiteralPath $_.FullName};Remove-Item -LiteralPath $scratch
}
