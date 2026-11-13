param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.1.0',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'release' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
$windowsZip = Join-Path $OutputDirectory ('remote-guard-windows-v' + $Version + '.zip')
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
$staging = Join-Path $OutputDirectory ('.build-v' + $Version + '-' + [guid]::NewGuid().ToString('N'))
$windows = Join-Path $staging 'remote-guard-windows'
$macos = Join-Path $staging 'remote-guard-macos'
[void](New-Item -ItemType Directory -Path $windows, $macos)
$windowsFiles = @('remote-guard.ps1', 'remote-guard-instant.ps1', 'remote-guard-setup.ps1', 'remote-guard-launcher.vbs', 'remote-guard-instant-launcher.vbs')
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
$exe = Join-Path $windows 'remote-guard-setup.exe'
Invoke-PS2EXE -inputFile (Join-Path $windows 'remote-guard-setup.ps1') -outputFile $exe -noConsole -requireAdmin -STA -version ($Version + '.0') -title 'remote-guard' -product 'remote-guard' -description 'Remote connection monitor setup'
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
& tar.exe -czf $macosTar -C $staging 'remote-guard-macos'
if ($LASTEXITCODE -ne 0) { throw 'macOS archive creation failed' }
$lines = foreach ($path in @($windowsZip, $macosTar)) {
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($path)
}
[IO.File]::WriteAllLines($checksums, $lines, [Text.UTF8Encoding]::new($false))
foreach ($path in @($windowsZip, $macosTar, $checksums)) {
    Get-Item -LiteralPath $path | Select-Object FullName, Length
}
