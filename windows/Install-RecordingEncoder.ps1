param([Parameter(Mandatory=$true)][string]$Directory)
$ErrorActionPreference = 'Stop'
# Download on demand rather than adding a large third-party binary to every release.
$base = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('remote-guard-encoder-' + [guid]::NewGuid().ToString('N') + '.zip')
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $checksum = [string](Invoke-WebRequest -Uri ($base + '.sha256') -UseBasicParsing -TimeoutSec 30).Content
    if ($checksum -notmatch '^\s*([a-fA-F0-9]{64})(\s|$)') { throw '下载源未提供有效的 SHA-256 校验值' }
    $expected = $Matches[1]
    Invoke-WebRequest -Uri $base -OutFile $temp -UseBasicParsing -TimeoutSec 600
    $hasher=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($temp)
    try{$actual=[BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$hasher.Dispose()}
    if ($actual -ine $expected) { throw 'FFmpeg 下载校验失败，请重试' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [void][IO.Directory]::CreateDirectory($Directory)
    $zip = [IO.Compression.ZipFile]::OpenRead($temp)
    try {
        foreach ($name in @('ffmpeg.exe','ffplay.exe','LICENSE')) {
            $entries = @($zip.Entries | Where-Object { $_.FullName -match ('(^|/)' + [regex]::Escape($name) + '$') })
            if ($entries.Count -ne 1) { throw ('下载包中缺少或存在重复文件: ' + $name) }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], (Join-Path $Directory $name), $true)
        }
    } finally { $zip.Dispose() }
    [IO.File]::WriteAllText((Join-Path $Directory 'SOURCE.txt'), ($base + "`r`nSHA256=" + $expected + "`r`nGPL FFmpeg build; sources and license: https://www.gyan.dev/ffmpeg/builds/"))
    return (Join-Path $Directory 'ffmpeg.exe')
} finally { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
