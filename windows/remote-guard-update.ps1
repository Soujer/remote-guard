param([string]$InstallRoot=$PSScriptRoot,[switch]$Auto,[int]$WaitForPid=0,[switch]$Relaunch)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'update-common.ps1')
. (Join-Path $PSScriptRoot 'recording-common.ps1')
$lock = New-Object Threading.Mutex($false,'Local\RemoteGuardUpdate')
if (-not $lock.WaitOne(0)) { $lock.Dispose(); exit }
$paused=$false; $wasRunning=$false; $flag=$false
$cache=$null;$zipPath=$null;$staged=$null
function Write-UpdateLog([string]$Message) {
    $path=Join-Path $InstallRoot 'update.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) {Move-Item -LiteralPath $path -Destination ($path+'.1') -Force}
    Add-Content -LiteralPath $path -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' '+$Message) -Encoding UTF8
}
try {
    if ($WaitForPid -gt 0) { Wait-Process -Id $WaitForPid -Timeout 30 -ErrorAction SilentlyContinue; if(Get-Process -Id $WaitForPid -ErrorAction SilentlyContinue){exit} }
    if ($Auto) {
        $settings=Join-Path $InstallRoot 'updates.json'
        if ((Test-Path -LiteralPath $settings) -and -not (Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).enabled) {exit}
    }
    $update=Get-GuardUpdate (Get-GuardVersion $InstallRoot)
    if (-not $update) {exit}
    # Do not replace a running GUI or interrupt remote-session recording.
    $apps=@(Get-Process -Name remote-guard,remote-guard-setup -ErrorAction SilentlyContinue | Where-Object {try{(Split-Path $_.Path -Parent) -eq $InstallRoot}catch{$false}})
    if ($apps.Count -gt 0 -or (Get-GuardRecordingSession $InstallRoot) -or @(Get-GuardOwnedProcess $InstallRoot 'remote-guard-recorder.ps1').Count -gt 0) {Write-UpdateLog '发现新版，等待软件关闭且远程会话结束后安装';exit}
    $cache=Join-Path $InstallRoot ('update-cache\'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($cache)
    $zipPath=Join-Path $cache $update.ZipName
    $hashText=[string](Invoke-WebRequest -Uri $update.HashUrl -UseBasicParsing -TimeoutSec 30).Content
    $expected=Get-GuardExpectedHash $hashText $update.ZipName
    # Bound the response while streaming, even if the server omits Content-Length.
    Add-Type -AssemblyName System.Net.Http
    $client=New-Object Net.Http.HttpClient
    try {
        $client.Timeout=[TimeSpan]::FromMinutes(3)
        $response=$client.GetAsync($update.ZipUrl,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            [void]$response.EnsureSuccessStatusCode()
            if($response.Content.Headers.ContentLength -gt 32MB){throw '更新包超过大小限制'}
            $downloadStream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$output=[IO.File]::Create($zipPath)
            try {$buffer=New-Object byte[] 65536;$total=0;while(($count=$downloadStream.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$count;if($total -gt 32MB){throw '更新包超过大小限制'};$output.Write($buffer,0,$count)}}finally{$output.Dispose();$downloadStream.Dispose()}
        }finally{$response.Dispose()}
    }finally{$client.Dispose()}
    if((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -ine $expected){throw '更新包 SHA-256 校验失败'}
    $staged=Join-Path $cache 'verified';Expand-GuardUpdate $zipPath $staged ([version]$update.Version)
    if (Get-GuardRecordingSession $InstallRoot) {Write-UpdateLog '下载完成，但远程会话已开始，延后安装';exit}
    $task=Get-ScheduledTask -TaskName remote-guard -ErrorAction SilentlyContinue
    $wasRunning=($task -and $task.State -ne 'Disabled' -and $task.Actions.Arguments -like ('*'+$InstallRoot+'\remote-guard-launcher.vbs*'))
    # A fresh check plus the stop marker closes the race with a recorder starting during installation.
    $apps=@(Get-Process -Name remote-guard,remote-guard-setup -ErrorAction SilentlyContinue | Where-Object {try{(Split-Path $_.Path -Parent) -eq $InstallRoot}catch{$false}})
    if($apps.Count -gt 0){Write-UpdateLog '主程序已打开，延后安装';exit}
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'updating.flag'),$update.Version);$flag=$true
    $paused=$true;Stop-GuardRuntime $InstallRoot
    $backup=Install-GuardFiles $staged $InstallRoot
    Write-UpdateLog ('已更新至 '+$update.Version+'；备份: '+$backup)
} catch {Write-UpdateLog ('更新失败（保留配置与录像）: '+$_.Exception.Message)}
finally {
    if($paused -and $wasRunning){try{Start-GuardRuntime $InstallRoot}catch{Write-UpdateLog ('恢复监控失败: '+$_.Exception.Message)}}
    if($flag){Remove-Item -LiteralPath (Join-Path $InstallRoot 'updating.flag') -ErrorAction SilentlyContinue}
    # Remove only exact temporary paths created by this invocation, never user data or backups.
    if($cache){
        $cacheBase=[IO.Path]::GetFullPath((Join-Path $InstallRoot 'update-cache')).TrimEnd('\')+'\'
        if([IO.Path]::GetFullPath($cache).StartsWith($cacheBase,[StringComparison]::OrdinalIgnoreCase)){
            if($zipPath){Remove-Item -LiteralPath $zipPath -ErrorAction SilentlyContinue}
            if($staged){foreach($name in (Get-GuardPackageFiles)){Remove-Item -LiteralPath (Join-Path $staged $name) -ErrorAction SilentlyContinue};Remove-Item -LiteralPath $staged -ErrorAction SilentlyContinue}
            Remove-Item -LiteralPath $cache -ErrorAction SilentlyContinue
        }
    }
    $lock.ReleaseMutex();$lock.Dispose()
    if($Relaunch){Start-Process -FilePath (Join-Path $InstallRoot 'remote-guard.exe') -WindowStyle Hidden}
}
