param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.3.2',
    [string]$OutputDirectory,
    [string]$EncoderDirectory
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $EncoderDirectory) { $EncoderDirectory = Join-Path $repo 'release/recording-test-tools' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'release' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
# Old updaters first select v1.3.1, which understands bundled packages and their limits.
$windowsZip = Join-Path $OutputDirectory ('remote-guard-windows-bundled-v' + $Version + '.zip')
$macosTar = Join-Path $OutputDirectory ('remote-guard-macos-v' + $Version + '.tar.gz')
$checksums = Join-Path $OutputDirectory ('SHA256SUMS-v' + $Version + '.txt')
foreach ($path in @($windowsZip, $macosTar, $checksums)) {
    if (Test-Path -LiteralPath $path) { throw ('Output already exists: ' + $path) }
}
$commit = (& git -C $repo rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the source commit' }
if (@(& git -C $repo status --porcelain --untracked-files=no).Count -gt 0) {
    throw 'Commit tracked source changes before building a release'
}
Import-Module ps2exe -ErrorAction Stop
foreach ($name in @('ffmpeg.exe','LICENSE','SOURCE.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $EncoderDirectory $name) -PathType Leaf)) { throw ('Missing offline encoder input: ' + $name) }
}
$codecHash=(Get-FileHash -LiteralPath (Join-Path $EncoderDirectory 'ffmpeg.exe') -Algorithm SHA256).Hash
if ($codecHash -ne '3256173F3F8BFFD7DF12227C68ADF68025EDB1832273A9530688A7BB1ED8EDEC') { throw 'Encoder differs from the pinned FFmpeg 9.0.2 build' }
$staging = Join-Path $OutputDirectory ('.build-v' + $Version + '-' + [guid]::NewGuid().ToString('N'))
$windows = Join-Path $staging 'remote-guard-windows'
$macos = Join-Path $staging 'remote-guard-macos'
[void](New-Item -ItemType Directory -Path $windows, $macos)
$windowsFiles = @('remote-guard.ps1', 'remote-guard-instant.ps1', 'remote-guard-setup.ps1', 'remote-guard-launcher.vbs', 'remote-guard-instant-launcher.vbs', 'recording-common.ps1', 'RecordingCrypto.cs', 'DesktopRuntime.cs', 'recording-ui.ps1', 'update-common.ps1', 'remote-guard-update.ps1', 'remote-guard-recorder.ps1', 'remote-guard-recording-setup.ps1', 'remote-guard-play.ps1', 'Install-RecordingEncoder.ps1')
foreach ($name in $windowsFiles) {
    Copy-Item -LiteralPath (Join-Path (Join-Path $repo 'windows') $name) -Destination (Join-Path $windows $name)
}
foreach ($name in @('remote-guard-macos.sh', 'install-macos.sh', 'push-channels.conf.example')) {
    $content = [IO.File]::ReadAllText((Join-Path (Join-Path $repo 'macos') $name)) -replace "`r`n", "`n"
    [IO.File]::WriteAllText((Join-Path $macos $name), $content, [Text.UTF8Encoding]::new($false))
}
foreach ($directory in @($windows, $macos)) {
    foreach ($name in @('README.md', 'LICENSE')) {
        Copy-Item -LiteralPath (Join-Path $repo $name) -Destination (Join-Path $directory $name)
    }
    [IO.File]::WriteAllText((Join-Path $directory 'VERSION'), ('version=' + $Version + "`ncommit=" + $commit + "`n"), [Text.UTF8Encoding]::new($false))
}
$payload = Join-Path $staging 'runtime.zip'
Compress-Archive -Path (Join-Path $windows '*') -DestinationPath $payload -CompressionLevel Optimal
$embedded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($payload))
$source = [IO.File]::ReadAllText((Join-Path $windows 'remote-guard-setup.ps1'))
$injection = '$script:GuardBuildVersion = ''' + $Version + '''' + "`r`n" + '$script:GuardBuildCommit = ''' + $commit + '''' + "`r`n" + '$script:GuardEmbeddedPayload = ''' + $embedded + ''''
$compiledSource = Join-Path $staging 'compiled-main.ps1'
[IO.File]::WriteAllText($compiledSource, $source.Replace('# BUILD_PAYLOAD', $injection), [Text.UTF8Encoding]::new($true))
$exe = Join-Path $windows 'remote-guard.exe'
$encoderBundle=Join-Path $staging 'encoder.zip'
$encoderInput=Join-Path $staging 'encoder-input';[void][IO.Directory]::CreateDirectory($encoderInput)
foreach($name in @('ffmpeg.exe','LICENSE','SOURCE.txt')){Copy-Item -LiteralPath (Join-Path $EncoderDirectory $name) -Destination (Join-Path $encoderInput $name)}
$sourceInfo="`r`nBundled FFmpeg 9.0.2 (GPLv3), unmodified Gyan essentials executable.`r`nCorresponding source: https://github.com/FFmpeg/FFmpeg/commit/946fcce07b`r`nSource archive: https://github.com/FFmpeg/FFmpeg/archive/946fcce07b.tar.gz`r`nBuild and dependency information: https://www.gyan.dev/ffmpeg/builds/`r`nFFmpeg executable SHA256="+$codecHash+"`r`n"
[IO.File]::AppendAllText((Join-Path $encoderInput 'SOURCE.txt'),$sourceInfo,[Text.UTF8Encoding]::new($false))
$encoderFiles=@('ffmpeg.exe','LICENSE','SOURCE.txt') | ForEach-Object { Join-Path $encoderInput $_ }
Compress-Archive -LiteralPath $encoderFiles -DestinationPath $encoderBundle -CompressionLevel Optimal
$bundleTarget='%LOCALAPPDATA%\RemoteGuard\payload\'+$Version+'-'+$commit+'\encoder.zip'
Invoke-PS2EXE -inputFile $compiledSource -outputFile $exe -noConsole -STA -x64 -version ($Version + '.0') -title 'remote-guard' -product 'remote-guard' -description 'Remote Guard desktop with offline recording' -embedFiles @{$bundleTarget=$encoderBundle}
Copy-Item -LiteralPath $exe -Destination (Join-Path $windows 'remote-guard-setup.exe')
if (-not (Test-Path -LiteralPath $exe)) { throw 'Installer compilation failed' }
$binary = [IO.File]::ReadAllBytes($exe)
$peOffset = [BitConverter]::ToInt32($binary, 0x3c)
if ([BitConverter]::ToUInt16($binary, $peOffset + 92) -ne 2) { throw 'Installer must use the Windows GUI subsystem' }
foreach ($name in $windowsFiles) {
    if ((Get-FileHash -LiteralPath (Join-Path (Join-Path $repo 'windows') $name)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $windows $name)).Hash) {
        throw ('Packaged source differs: ' + $name)
    }
}
Compress-Archive -Path (Join-Path $windows '*') -DestinationPath $windowsZip -CompressionLevel Optimal
if ((Get-Item -LiteralPath $exe).Length -gt 64MB -or (Get-Item -LiteralPath $windowsZip).Length -gt 100MB) { throw 'Bundled release exceeds updater or release-asset size limits' }
& tar.exe -czf $macosTar -C $staging 'remote-guard-macos'
if ($LASTEXITCODE -ne 0) { throw 'macOS archive creation failed' }
$standalone = Join-Path $OutputDirectory ('remote-guard-v' + $Version + '.exe')
if (Test-Path -LiteralPath $standalone) { throw ('Output already exists: ' + $standalone) }
Copy-Item -LiteralPath $exe -Destination $standalone
$lines = foreach ($path in @($windowsZip, $macosTar, $standalone)) {
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($path)
}
[IO.File]::WriteAllLines($checksums, $lines, [Text.UTF8Encoding]::new($false))
foreach ($path in @($windowsZip, $macosTar, $standalone, $checksums)) {
    Get-Item -LiteralPath $path | Select-Object FullName, Length
}
