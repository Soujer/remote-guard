param(
    [Parameter(Mandatory=$true)][string]$Directory,
    [string]$BundlePath = (Join-Path $PSScriptRoot 'encoder.zip')
)
$ErrorActionPreference = 'Stop'
# Pinned Gyan FFmpeg 9.0.2 essentials build. No network requests at runtime.
$expected='3256173F3F8BFFD7DF12227C68ADF68025EDB1832273A9530688A7BB1ED8EDEC'
function Encoder-Hash([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
    try{[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$sha.Dispose()}
}
$target=Join-Path $Directory 'ffmpeg.exe'
if((Test-Path -LiteralPath $target -PathType Leaf) -and (Encoder-Hash $target) -eq $expected){return $target}
if(-not(Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
    # Compatibility scripts in an installed ZIP can ask the bundled application to release its codec.
    $app=Join-Path (Split-Path $Directory -Parent) 'remote-guard.exe'
    if(Test-Path -LiteralPath $app -PathType Leaf){
        $process=Start-Process -FilePath $app -ArgumentList ('-InstallEncoder -InstallRoot "'+(Split-Path $Directory -Parent)+'"') -WindowStyle Hidden -Wait -PassThru
        if($process.ExitCode -eq 0 -and (Test-Path -LiteralPath $target) -and (Encoder-Hash $target) -eq $expected){return $target}
    }
    throw '内置组件资源缺失，请重新打开最新版 remote-guard.exe 释放组件'
}
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead($BundlePath)
$staging=$null
try {
    $allowed=@('ffmpeg.exe','LICENSE','SOURCE.txt');$seen=@{};$total=[long]0
    foreach($entry in $archive.Entries){
        if($allowed -cnotcontains $entry.FullName -or $seen.ContainsKey($entry.FullName)){throw '内置组件包含重复文件或不安全路径'}
        $seen[$entry.FullName]=$true;$total+=$entry.Length
        if($entry.Length -gt 128MB -or ($entry.FullName -ne 'ffmpeg.exe' -and $entry.Length -gt 1MB) -or $total -gt 130MB){throw '内置组件大小异常'}
    }
    foreach($name in $allowed){if(-not $seen.ContainsKey($name)){throw ('内置组件缺少文件: '+$name)}}
    [void][IO.Directory]::CreateDirectory($Directory)
    $staging=Join-Path $Directory ('.encoder-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    foreach($entry in $archive.Entries){[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $staging $entry.FullName),$false)}
    if((Encoder-Hash (Join-Path $staging 'ffmpeg.exe')) -ne $expected){throw '内置录屏组件 SHA-256 校验失败'}
    # A failed extraction or validation cannot replace an existing encoder.
    foreach($name in $allowed){Move-Item -LiteralPath (Join-Path $staging $name) -Destination (Join-Path $Directory $name) -Force}
    return $target
}finally {
    $archive.Dispose()
    if($staging){
        foreach($name in @('ffmpeg.exe','LICENSE','SOURCE.txt')){Remove-Item -LiteralPath (Join-Path $staging $name) -ErrorAction SilentlyContinue}
        Remove-Item -LiteralPath $staging -ErrorAction SilentlyContinue
    }
}
