param([string]$FFmpeg)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'windows/update-common.ps1')
$script:checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Release([string]$Version,[bool]$Pre=$false){
    return [pscustomobject]@{tag_name=('v'+$Version);prerelease=$Pre;assets=@(
        [pscustomobject]@{name=('remote-guard-windows-v'+$Version+'.zip');browser_download_url=('https://gitee.com/Soujer/remote-guard/releases/download/v'+$Version+'/remote-guard-windows-v'+$Version+'.zip')},
        [pscustomobject]@{name=('SHA256SUMS-v'+$Version+'.txt');browser_download_url=('https://gitee.com/Soujer/remote-guard/releases/download/v'+$Version+'/SHA256SUMS-v'+$Version+'.txt')})}
}
$selected=Select-GuardUpdate @((Release '1.2.0'),(Release '1.10.0'),(Release '9.0.0' $true),(Release '1.9.0')) ([version]'1.3.0')
Assert ($selected.Version -eq '1.10.0') 'Version selection must use numerical version order and exclude prereleases'
Assert ($null -eq (Select-GuardUpdate @((Release '1.2.0')) ([version]'1.3.0'))) 'Never downgrade'
$incomplete=Release '2.0.0';$incomplete.assets=@($incomplete.assets[0])
Assert ($null -eq (Select-GuardUpdate @($incomplete) ([version]'1.3.0'))) 'Skip releases without checksum assets'
$foreign=Release '2.0.0';$foreign.assets[0].browser_download_url='https://evil.example/package.zip'
Assert ($null -eq (Select-GuardUpdate @($foreign) ([version]'1.3.0'))) 'Reject release assets outside the fixed Gitee repository'
$hash='a'*64
Assert ((Get-GuardExpectedHash ($hash+'  remote-guard-windows-v2.0.0.zip') 'remote-guard-windows-v2.0.0.zip') -eq $hash) 'Read exact checksum filename'
$rejected=$false;try{Get-GuardExpectedHash ($hash+'  other.zip') 'remote-guard-windows-v2.0.0.zip'}catch{$rejected=$true};Assert $rejected 'Reject checksums for the wrong asset'

$scratch=Join-Path ([IO.Path]::GetTempPath()) ('remote-guard-desktop-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
Add-Type -AssemblyName System.IO.Compression.FileSystem
try{
    foreach($script in Get-ChildItem (Join-Path $repo 'windows') -Filter '*.ps1'){
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0) ('Script parse failed: '+$script.Name)
    }
    $source=Join-Path $scratch 'source';$target=Join-Path $scratch 'app';[void][IO.Directory]::CreateDirectory($source);[void][IO.Directory]::CreateDirectory($target)
    foreach($name in Get-GuardPackageFiles){[IO.File]::WriteAllText((Join-Path $source $name),('new '+$name));[IO.File]::WriteAllText((Join-Path $target $name),('old '+$name))}
    foreach($name in @('push-channels.json','recording.json','updates.json','private.rgkey','rg-private.rgrec')){[IO.File]::WriteAllText((Join-Path $target $name),'preserve-test-data')}
    $locked=Join-Path $target 'remote-guard-instant.ps1';$handle=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $rejected=$false;try{[void](Install-GuardFiles $source $target)}catch{$rejected=$true}finally{$handle.Dispose()}
    Assert $rejected 'A locked installed file must fail the transaction'
    foreach($name in Get-GuardPackageFiles){Assert ([IO.File]::ReadAllText((Join-Path $target $name)) -eq ('old '+$name)) ('Rollback failed: '+$name)}
    [void](Install-GuardFiles $source $target)
    foreach($name in Get-GuardPackageFiles){Assert ([IO.File]::ReadAllText((Join-Path $target $name)) -eq ('new '+$name)) ('Install failed: '+$name)}
    foreach($name in @('push-channels.json','recording.json','updates.json','private.rgkey','rg-private.rgrec')){Assert ([IO.File]::ReadAllText((Join-Path $target $name)) -eq 'preserve-test-data') ('Private data changed: '+$name)}
    [IO.File]::WriteAllText((Join-Path $source 'VERSION'),"version=2.0.0`ncommit="+('a'*40)+"`n")
    foreach($name in @('remote-guard.exe','remote-guard-setup.exe')){$bytes=New-Object byte[] 256;$bytes[0]=77;$bytes[1]=90;[IO.File]::WriteAllBytes((Join-Path $source $name),$bytes)}
    $zip=Join-Path $scratch 'good.zip';[IO.Compression.ZipFile]::CreateFromDirectory($source,$zip)
    $extracted=Join-Path $scratch 'extracted';Expand-GuardUpdate $zip $extracted ([version]'2.0.0')
    Assert ((Get-GuardVersion $extracted) -eq [version]'2.0.0') 'Verified package must extract completely'
    $rejected=$false;try{Expand-GuardUpdate $zip (Join-Path $scratch 'wrong-version') ([version]'3.0.0')}catch{$rejected=$true};Assert $rejected 'Reject mismatched version manifests'
    foreach($entryName in @('../escape.txt','recording.json','REMOTE-GUARD.EXE')){
        $bad=Join-Path $scratch ([guid]::NewGuid().ToString('N')+'.zip');[IO.File]::Copy($zip,$bad)
        $archive=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Update)
        try{[void]$archive.CreateEntry($entryName)}finally{$archive.Dispose()}
        $rejected=$false;try{Expand-GuardUpdate $bad (Join-Path $scratch ([guid]::NewGuid().ToString('N'))) ([version]'2.0.0')}catch{$rejected=$true}
        Assert $rejected ('Reject unsafe zip entry: '+$entryName)
    }
    Assert (-not(Test-Path -LiteralPath (Join-Path $scratch 'escape.txt'))) 'Zip traversal must not write outside staging'
    if($FFmpeg){
        Add-Type -Path @((Join-Path $repo 'windows/RecordingCrypto.cs'),(Join-Path $repo 'windows/DesktopRuntime.cs'))
        $key=Join-Path $scratch 'test.rgkey';$password='temporary regression password';$public=[RemoteGuard.Vault]::CreateKey($key,$password)
        $clip=Join-Path $scratch 'synthetic.rgrec'
        $capture=[RemoteGuard.Capture]::new($FFmpeg,'-hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=5 -t 1 -c:v libx264 -threads 2 -movflags +frag_keyframe+empty_moov+default_base_moof -f mp4 pipe:1',$public,$clip,2MB)
        try{Start-Sleep -Seconds 1;$capture.Finish()}finally{$capture.Dispose()}
        $preview=[RemoteGuard.Preview]::new($clip,$key,$password,$FFmpeg);$frame=$null;$deadline=(Get-Date).AddSeconds(10)
        try{while(-not $frame -and (Get-Date) -lt $deadline){$frame=$preview.TakeFrame();Start-Sleep -Milliseconds 50};Assert ($frame.Length -eq 640*360*4) 'Embedded player must decode authenticated video frames';Assert (-not $preview.Error) 'Embedded preview must not fail'}finally{$preview.Dispose()}
        $preview=[RemoteGuard.Preview]::new($clip,$key,'wrong password',$FFmpeg);$frame=$null;$deadline=(Get-Date).AddSeconds(10)
        try{while(-not $preview.Done -and (Get-Date) -lt $deadline){if($preview.TakeFrame()){$frame=$true};Start-Sleep -Milliseconds 50};Assert (-not $frame) 'Wrong password must never render a frame';Assert ([bool]$preview.Error) 'Wrong password must be reported'}finally{$preview.Dispose()}
    }
    Write-Output ('Desktop/update regression checks passed: '+$script:checks)
}finally{
    # Enumerate only within the exact newly-created test root; delete individual files, then empty directories.
    $resolved=[IO.Path]::GetFullPath($scratch)
    if(-not $resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'remote-guard-desktop-test-*'){throw 'Unsafe test cleanup path'}
    Get-ChildItem -LiteralPath $resolved -File -Recurse|ForEach-Object{Remove-Item -LiteralPath $_.FullName}
    Get-ChildItem -LiteralPath $resolved -Directory -Recurse|Sort-Object {$_.FullName.Length} -Descending|ForEach-Object{Remove-Item -LiteralPath $_.FullName}
    Remove-Item -LiteralPath $resolved
}
