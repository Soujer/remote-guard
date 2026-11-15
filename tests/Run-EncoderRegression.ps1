param([string]$BundlePath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$installer=Join-Path $repo 'windows/Install-RecordingEncoder.ps1'
$script:checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Invoke-WebRequest {throw 'Encoder setup must never use the network'}
function Invoke-RestMethod {throw 'Encoder setup must never use the network'}
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('remote-guard-encoder-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $source=Join-Path $scratch 'source';[void][IO.Directory]::CreateDirectory($source)
    foreach($name in @('ffmpeg.exe','LICENSE','SOURCE.txt')){[IO.File]::WriteAllText((Join-Path $source $name),'test data')}
    $fake=Join-Path $scratch 'fake.zip';[IO.Compression.ZipFile]::CreateFromDirectory($source,$fake)
    $target=Join-Path $scratch 'preserve';[void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'ffmpeg.exe'),'existing custom encoder')
    $rejected=$false;try{& $installer -Directory $target -BundlePath $fake}catch{$rejected=$true}
    Assert $rejected 'Untrusted encoder bytes must fail SHA-256 validation'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'ffmpeg.exe')) -eq 'existing custom encoder') 'A failed validation must preserve an existing encoder'
    Assert (@(Get-ChildItem -LiteralPath $target -Directory).Count -eq 0) 'Failed extraction must remove its staging directory'
    foreach($entryName in @('../escape.txt','FFMPEG.EXE','ffmpeg.exe')){
        $bad=Join-Path $scratch ([guid]::NewGuid().ToString('N')+'.zip');[IO.File]::Copy($fake,$bad)
        $archive=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Update)
        try{[void]$archive.CreateEntry($entryName)}finally{$archive.Dispose()}
        $rejected=$false;try{& $installer -Directory (Join-Path $scratch ([guid]::NewGuid().ToString('N'))) -BundlePath $bad}catch{$rejected=$true}
        Assert $rejected ('Reject unsafe or duplicate encoder entry: '+$entryName)
    }
    Assert (-not(Test-Path -LiteralPath (Join-Path $scratch 'escape.txt'))) 'Archive traversal must never write outside staging'
    if($BundlePath){
        $directory=Join-Path $scratch 'offline install'
        $encoder=& $installer -Directory $directory -BundlePath $BundlePath
        Assert ((Get-FileHash -LiteralPath $encoder).Hash -eq '3256173F3F8BFFD7DF12227C68ADF68025EDB1832273A9530688A7BB1ED8EDEC') 'First offline extraction must release the pinned encoder'
        Assert (Test-Path -LiteralPath (Join-Path $directory 'LICENSE')) 'Include the encoder license'
        Assert (Test-Path -LiteralPath (Join-Path $directory 'SOURCE.txt')) 'Include corresponding source information'
        $written=[IO.File]::GetLastWriteTimeUtc($encoder)
        [void](& $installer -Directory $directory -BundlePath (Join-Path $scratch 'missing.zip'))
        Assert ([IO.File]::GetLastWriteTimeUtc($encoder) -eq $written) 'Repeat startup must reuse a verified encoder without rewriting it'
        [IO.File]::WriteAllText($encoder,'damaged encoder')
        [void](& $installer -Directory $directory -BundlePath $BundlePath)
        Assert ((Get-Item -LiteralPath $encoder).Length -eq 105423872) 'Offline bundle must repair a damaged encoder'
    }
    Write-Output ('Offline encoder regression checks passed: '+$script:checks)
}finally{
    $resolved=[IO.Path]::GetFullPath($scratch)
    if(-not $resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'remote-guard-encoder-test-*'){throw 'Unsafe test cleanup path'}
    Get-ChildItem -LiteralPath $resolved -File -Recurse|ForEach-Object{Remove-Item -LiteralPath $_.FullName}
    Get-ChildItem -LiteralPath $resolved -Directory -Recurse|Sort-Object {$_.FullName.Length} -Descending|ForEach-Object{Remove-Item -LiteralPath $_.FullName}
    Remove-Item -LiteralPath $resolved
}
