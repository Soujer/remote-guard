function Get-GuardVersion([string]$Directory) {
    $path = Join-Path $Directory 'VERSION'
    if (Test-Path -LiteralPath $path) {
        $text = [IO.File]::ReadAllText($path)
        if ($text -match '(?m)^version=(\d+\.\d+\.\d+)\s*$') { return [version]$Matches[1] }
    }
    return [version]'0.0.0'
}

function Get-GuardPackageFiles {
    return @('remote-guard.exe','remote-guard-setup.exe','remote-guard-setup.ps1','remote-guard.ps1','remote-guard-instant.ps1','remote-guard-launcher.vbs','remote-guard-instant-launcher.vbs','recording-common.ps1','RecordingCrypto.cs','DesktopRuntime.cs','recording-ui.ps1','update-common.ps1','remote-guard-update.ps1','remote-guard-recorder.ps1','remote-guard-recording-setup.ps1','remote-guard-play.ps1','Install-RecordingEncoder.ps1','README.md','LICENSE','VERSION')
}

function Select-GuardUpdate([array]$Releases, [version]$Current) {
    $candidates = @()
    foreach ($release in $Releases) {
        if ($release.prerelease -or $release.draft -or [string]$release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') { continue }
        $version = [version]$Matches[1]
        if ($version -le $Current) { continue }
        $zipName = 'remote-guard-windows-v' + $version + '.zip'
        $hashName = 'SHA256SUMS-v' + $version + '.txt'
        $zip = @($release.assets | Where-Object name -eq $zipName)
        $hash = @($release.assets | Where-Object name -eq $hashName)
        if ($zip.Count -ne 1 -or $hash.Count -ne 1) { continue }
        $prefix = 'https://gitee.com/Soujer/remote-guard/releases/download/' + $release.tag_name + '/'
        if ($zip[0].browser_download_url -cne ($prefix + $zipName) -or $hash[0].browser_download_url -cne ($prefix + $hashName)) { continue }
        $candidates += [pscustomobject]@{Version=$version.ToString();ZipName=$zipName;ZipUrl=$zip[0].browser_download_url;HashUrl=$hash[0].browser_download_url}
    }
    return $candidates | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
}

function Get-GuardUpdate([version]$Current) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Gitee's list is not guaranteed to be in version order. Ignore incomplete and prerelease uploads.
    $releases = Invoke-RestMethod -Uri 'https://gitee.com/api/v5/repos/Soujer/remote-guard/releases?per_page=100&page=1' -TimeoutSec 20 -ErrorAction Stop
    return Select-GuardUpdate @($releases) $Current
}

function Get-GuardExpectedHash([string]$Text, [string]$Name) {
    $lines = @($Text -split '\r?\n' | Where-Object { $_ -match ('^[a-fA-F0-9]{64}  ' + [regex]::Escape($Name) + '$') })
    if ($lines.Count -ne 1) { throw '校验清单缺少唯一的 Windows 安装包校验值' }
    return $lines[0].Substring(0,64)
}

function Expand-GuardUpdate([string]$ZipPath, [string]$Destination, [version]$ExpectedVersion) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $allowed = @(Get-GuardPackageFiles)
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $seen = @{}; $total = [long]0
        foreach ($entry in $zip.Entries) {
            if ($allowed -cnotcontains $entry.FullName -or $seen.ContainsKey($entry.FullName.ToLowerInvariant())) { throw '安装包包含重复、未知文件或不安全路径' }
            $seen[$entry.FullName.ToLowerInvariant()] = $true
            $total += $entry.Length
            if ($entry.Length -gt 16MB -or $total -gt 64MB) { throw '安装包解压大小超限' }
        }
        foreach ($name in $allowed) { if (-not $seen.ContainsKey($name.ToLowerInvariant())) { throw ('安装包缺少文件: ' + $name) } }
        [void][IO.Directory]::CreateDirectory($Destination)
        foreach ($entry in $zip.Entries) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $Destination $entry.FullName),$false) }
    } finally { $zip.Dispose() }
    if ((Get-GuardVersion $Destination) -ne $ExpectedVersion) { throw '安装包版本与发行版不一致' }
    $versionText = [IO.File]::ReadAllText((Join-Path $Destination 'VERSION'))
    if ($versionText -notmatch '(?m)^commit=[a-f0-9]{40}\s*$') { throw '安装包缺少源码版本信息' }
    foreach ($name in @('remote-guard.exe','remote-guard-setup.exe')) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $Destination $name))
        if ($bytes.Length -lt 256 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { throw '无效的 Windows 主程序' }
    }
}

function Get-GuardOwnedProcess([string]$Directory, [string]$FileName) {
    $path = Join-Path ([IO.Path]::GetFullPath($Directory)) $FileName
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -match ('(?i)-File\s+"' + [regex]::Escape($path) + '"(?:\s|$)')
    })
}

function Stop-GuardRuntime([string]$Directory) {
    $task = Get-ScheduledTask -TaskName remote-guard -ErrorAction SilentlyContinue
    if ($task -and $task.Actions.Arguments -notlike ('*' + $Directory + '\remote-guard-launcher.vbs*')) { throw '计划任务属于其他安装目录，停止操作已取消' }
    [IO.File]::WriteAllText((Join-Path $Directory 'recording.stop'),'stop')
    if ($task) { Disable-ScheduledTask -TaskName remote-guard | Out-Null; Stop-ScheduledTask -TaskName remote-guard }
    foreach ($name in @('remote-guard.ps1','remote-guard-instant.ps1')) {
        foreach ($process in (Get-GuardOwnedProcess $Directory $name)) { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop }
    }
    $deadline = (Get-Date).AddSeconds(12)
    while (@(Get-GuardOwnedProcess $Directory 'remote-guard-recorder.ps1').Count -gt 0) {
        if ((Get-Date) -ge $deadline) { throw '录屏尚未保存完成，已取消替换文件' }
        Start-Sleep -Milliseconds 250
    }
}

function Start-GuardRuntime([string]$Directory) {
    Remove-Item -LiteralPath (Join-Path $Directory 'recording.stop') -ErrorAction SilentlyContinue
    Enable-ScheduledTask -TaskName remote-guard -ErrorAction Stop | Out-Null
    Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $Directory 'remote-guard-instant-launcher.vbs') + '"') -WindowStyle Hidden
}

function Install-GuardFiles([string]$Source, [string]$Directory) {
    [void][IO.Directory]::CreateDirectory($Directory)
    $names = @(Get-GuardPackageFiles)
    # Validate the complete source set before changing any installed file.
    foreach ($name in $names) { if (-not (Test-Path -LiteralPath (Join-Path $Source $name) -PathType Leaf)) { throw ('缺少程序文件: ' + $name) } }
    if ([IO.Path]::GetFullPath($Source).TrimEnd('\') -eq [IO.Path]::GetFullPath($Directory).TrimEnd('\')) { return }
    $backup = Join-Path $Directory ('backups\update-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($backup)
    $changed = @(); $present = @{}
    try {
        foreach ($name in $names) {
            $target = Join-Path $Directory $name
            if ((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath (Join-Path $Source $name)).Hash) { continue }
            $present[$name] = Test-Path -LiteralPath $target
            if ($present[$name]) { Copy-Item -LiteralPath $target -Destination (Join-Path $backup $name) -ErrorAction Stop }
            $changed += $name
            Copy-Item -LiteralPath (Join-Path $Source $name) -Destination $target -Force -ErrorAction Stop
        }
    } catch {
        $failure = $_
        foreach ($name in $changed) {
            $target = Join-Path $Directory $name
            if ($present[$name]) { Copy-Item -LiteralPath (Join-Path $backup $name) -Destination $target -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $target -ErrorAction SilentlyContinue }
        }
        throw $failure
    }
    return $backup
}

function Register-GuardUpdates([string]$Directory) {
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Directory 'remote-guard-update.ps1') + '" -InstallRoot "' + $Directory + '" -Auto'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10) -RepetitionInterval (New-TimeSpan -Hours 6)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName remote-guard-update -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
}
