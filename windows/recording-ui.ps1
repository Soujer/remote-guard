function Load-GuardRecordingView($View) {
    $directory=$View.Root.Text
    $View.Config=$null;$View.Path=$directory
    $View.Enabled.Checked=$false
    $View.Folder.Text=Join-Path $directory 'recordings'
    $View.Encoder.Text=Join-Path $directory 'ffmpeg\ffmpeg.exe'
    $View.Quota.Value=2048
    $View.Password.Clear();$View.Confirm.Clear()
    $path=Join-Path $directory 'recording.json'
    if(Test-Path -LiteralPath $path) {
        $cfg=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $View.Config=$cfg;$View.Enabled.Checked=[bool]$cfg.enabled
        if($cfg.directory){$View.Folder.Text=$cfg.directory}
        if($cfg.ffmpeg){$View.Encoder.Text=$cfg.ffmpeg}
        if($cfg.maxStorageMB){$View.Quota.Value=[decimal]$cfg.maxStorageMB}
    }
    try {
        [void](& (Join-Path $View.Resources 'Install-RecordingEncoder.ps1') -Directory (Join-Path $directory 'ffmpeg'))
        $View.Status.Text='内置组件已就绪。1080p / 1 Mbps，每 5 分钟约 37.5 MB，2 GB 约 4.5～4.8 小时。'
    }catch{$View.Status.Text='内置组件释放失败: '+$_.Exception.Message}
}

function New-GuardRecordingView($Parent,$RootBox,[string]$Resources) {
    $view=[pscustomobject]@{Root=$RootBox;Resources=$Resources;Path='';Config=$null;Enabled=$null;Folder=$null;Encoder=$null;Quota=$null;Password=$null;Confirm=$null;Status=$null;SaveAction=$null}
    function Recording-Label([string]$Text,[int]$Y) {
        $label=New-Object Windows.Forms.Label;$label.Text=$Text;$label.SetBounds(25,$Y,760,25);$Parent.Controls.Add($label)
    }
    $view.Enabled=New-Object Windows.Forms.CheckBox;$view.Enabled.Text='确认远程连接后自动加密录屏（只录画面）';$view.Enabled.SetBounds(25,20,760,28);$Parent.Controls.Add($view.Enabled)
    Recording-Label '录像保存目录' 65
    $view.Folder=New-Object Windows.Forms.TextBox;$view.Folder.SetBounds(25,95,630,27);$Parent.Controls.Add($view.Folder)
    $browse=New-Object Windows.Forms.Button;$browse.Text='浏览';$browse.SetBounds(670,92,110,32);$Parent.Controls.Add($browse)
    Recording-Label '内置录屏组件（无需下载，也可选择已有程序）' 140
    $view.Encoder=New-Object Windows.Forms.TextBox;$view.Encoder.SetBounds(25,170,500,27);$Parent.Controls.Add($view.Encoder)
    $choose=New-Object Windows.Forms.Button;$choose.Text='选择';$choose.SetBounds(540,167,110,32);$Parent.Controls.Add($choose)
    $download=New-Object Windows.Forms.Button;$download.Text='释放组件';$download.SetBounds(670,167,110,32);$Parent.Controls.Add($download)
    Recording-Label '存储上限（MB） · 达到上限会自动删除最旧片段' 215
    $view.Quota=New-Object Windows.Forms.NumericUpDown;$view.Quota.SetBounds(25,245,170,27);$view.Quota.Minimum=128;$view.Quota.Maximum=1048576;$Parent.Controls.Add($view.Quota)
    $passwordLabel=New-Object Windows.Forms.Label;$passwordLabel.Text='私钥密码（至少 12 位；已有密钥可留空）';$passwordLabel.SetBounds(25,290,380,25);$Parent.Controls.Add($passwordLabel)
    $confirmLabel=New-Object Windows.Forms.Label;$confirmLabel.Text='再次输入密码（确认）';$confirmLabel.SetBounds(410,290,370,25);$Parent.Controls.Add($confirmLabel)
    $view.Password=New-Object Windows.Forms.TextBox;$view.Password.UseSystemPasswordChar=$true;$view.Password.SetBounds(25,320,365,27);$Parent.Controls.Add($view.Password)
    $view.Confirm=New-Object Windows.Forms.TextBox;$view.Confirm.UseSystemPasswordChar=$true;$view.Confirm.SetBounds(410,320,370,27);$Parent.Controls.Add($view.Confirm)
    Recording-Label '播放需要私钥文件与密码，丢失后无法恢复。请将私钥另行备份。' 365
    Recording-Label '最高 1080p / 5 帧每秒 / 无音频；只缩放录像，不改变桌面分辨率。' 395
    $save=New-Object Windows.Forms.Button;$save.Text='保存录屏设置';$save.SetBounds(25,440,180,38);$Parent.Controls.Add($save)
    $view.Status=New-Object Windows.Forms.Label;$view.Status.SetBounds(25,500,755,65);$Parent.Controls.Add($view.Status)
    $browse.Add_Click({$d=New-Object Windows.Forms.FolderBrowserDialog;try{if($d.ShowDialog() -eq 'OK'){$view.Folder.Text=$d.SelectedPath}}finally{$d.Dispose()}}.GetNewClosure())
    $choose.Add_Click({$d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='ffmpeg.exe|ffmpeg.exe';try{if($d.ShowDialog() -eq 'OK'){$view.Encoder.Text=$d.FileName}}finally{$d.Dispose()}}.GetNewClosure())
    $download.Add_Click({
        $download.Enabled=$false
        try{$view.Status.Text='正在释放并校验内置组件……';$view.Status.Refresh();$view.Encoder.Text=& (Join-Path $view.Resources 'Install-RecordingEncoder.ps1') -Directory (Join-Path $view.Root.Text 'ffmpeg');$view.Status.Text='内置组件已就绪，无需下载。'}catch{$view.Status.Text='组件释放失败: '+$_.Exception.Message}finally{$download.Enabled=$true}
    }.GetNewClosure())
    $view.SaveAction={
        try {
            if($view.Path -ne $view.Root.Text){throw '安装目录已更改，请重新进入录屏页面后填写'}
            $directory=$view.Root.Text;[void][IO.Directory]::CreateDirectory($directory);$path=Join-Path $directory 'recording.json'
            if(-not $view.Enabled.Checked){
                $cfg=$view.Config;if(-not $cfg){$cfg=[pscustomobject]@{schema=1;enabled=$false}};$cfg.enabled=$false
            }else{
                if(-not(Test-Path -LiteralPath $view.Encoder.Text -PathType Leaf)){throw '请先释放内置组件或选择已有录屏组件'}
                if($view.Folder.Text -notmatch '^[A-Za-z]:\\'){throw '请选择本机磁盘上的绝对路径'}
                $public=$null;if($view.Config){$public=$view.Config.publicKey}
                if(-not $public){
                    $passwordError=[RemoteGuard.Vault]::PasswordError($view.Password.Text,$view.Confirm.Text)
                    if($passwordError){throw $passwordError}
                    $d=New-Object Windows.Forms.SaveFileDialog;$d.Filter='播放私钥 (*.rgkey)|*.rgkey';$d.FileName='remote-guard-playback.rgkey';$d.Title='保存播放私钥'
                    try{if($d.ShowDialog() -ne 'OK'){return};if(Test-Path -LiteralPath $d.FileName){throw '不能覆盖已有私钥'};$public=[RemoteGuard.Vault]::CreateKey($d.FileName,$view.Password.Text)}finally{$d.Dispose()}
                    $view.Config=[pscustomobject]@{publicKey=$public;enabled=$false}
                }
                $cfg=[pscustomobject]@{schema=1;enabled=$true;directory=[IO.Path]::GetFullPath($view.Folder.Text);ffmpeg=[IO.Path]::GetFullPath($view.Encoder.Text);publicKey=$public;segmentSeconds=300;fps=5;width=1920;bitrateKbps=1000;maxStorageMB=[int]$view.Quota.Value;minFreeMB=512}
            }
            $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ($path+'.tmp') -Encoding UTF8
            Move-Item -LiteralPath ($path+'.tmp') -Destination $path -Force
            $view.Config=$cfg;$view.Password.Clear();$view.Confirm.Clear();$view.Status.Text='录屏设置已保存。'
        }catch{$view.Status.Text='保存失败: '+$_.Exception.Message}
    }.GetNewClosure()
    $save.Add_Click($view.SaveAction)
    Load-GuardRecordingView $view
    return $view
}

function New-GuardLibraryView($Parent,$RootBox) {
    # Event handlers run in their own closure module. Capture helper scriptblocks explicitly.
    $view=[pscustomobject]@{Root=$RootBox;Player=$null;Picture=$null;List=$null;Key=$null;Password=$null;Status=$null;Timer=$null;Stop=${function:Stop-GuardPreview};Refresh=${function:Refresh-GuardLibrary};GetFiles=${function:Get-GuardRecordingFiles};RefreshAction=$null;StopAction=$null;FullScreen=$null;ToggleFullScreen=$null;RestoreFullScreen=$null;FullScreenKeyAction=$null;EmbeddedParent=$Parent;EmbeddedBounds=$null;Transport=$null;TransportBounds=$null;Timeline=$null;Time=$null;Rate=$null;Pause=$null;Seeking=$false;SeekAction=$null;ExitFullScreenAction=$null;ExitButton=$null;CurrentFile=$null;DurationSaved=$false;GetDuration=${function:Get-GuardRecordingDuration};SetDuration=${function:Set-GuardRecordingDuration}}
    $view.List=New-Object Windows.Forms.ListView;$view.List.View='Details';$view.List.FullRowSelect=$true;$view.List.MultiSelect=$false;$view.List.SetBounds(20,15,780,135)
    [void]$view.List.Columns.Add('录像时间（本机）',160);[void]$view.List.Columns.Add('时长',90);[void]$view.List.Columns.Add('大小',80);[void]$view.List.Columns.Add('文件名',440);$Parent.Controls.Add($view.List)
    $refresh=New-Object Windows.Forms.Button;$refresh.Text='刷新';$refresh.SetBounds(20,160,85,30);$Parent.Controls.Add($refresh)
    $openFile=New-Object Windows.Forms.Button;$openFile.Text='打开录像';$openFile.SetBounds(115,160,110,30);$Parent.Controls.Add($openFile)
    $keyBrowse=New-Object Windows.Forms.Button;$keyBrowse.Text='选择私钥';$keyBrowse.SetBounds(235,160,110,30);$Parent.Controls.Add($keyBrowse)
    $view.Key=New-Object Windows.Forms.TextBox;$view.Key.ReadOnly=$true;$view.Key.SetBounds(355,162,445,27);$Parent.Controls.Add($view.Key)
    $label=New-Object Windows.Forms.Label;$label.Text='私钥密码';$label.SetBounds(20,205,75,24);$Parent.Controls.Add($label)
    $view.Password=New-Object Windows.Forms.TextBox;$view.Password.UseSystemPasswordChar=$true;$view.Password.SetBounds(100,202,350,27);$Parent.Controls.Add($view.Password)
    $play=New-Object Windows.Forms.Button;$play.Text='播放选中录像';$play.SetBounds(465,200,170,32);$Parent.Controls.Add($play)
    $stop=New-Object Windows.Forms.Button;$stop.Text='停止播放';$stop.SetBounds(650,200,150,32);$Parent.Controls.Add($stop)
    $view.Picture=New-Object Windows.Forms.PictureBox;$view.Picture.BackColor='Black';$view.Picture.SizeMode='Zoom';$view.Picture.SetBounds(20,245,780,250);$Parent.Controls.Add($view.Picture)
    $view.Transport=New-Object Windows.Forms.Panel;$view.Transport.SetBounds(20,500,780,90);$view.Transport.BackColor='WhiteSmoke';$view.Transport.ForeColor='Black';$Parent.Controls.Add($view.Transport)
    $view.Timeline=New-Object Windows.Forms.TrackBar;$view.Timeline.SetBounds(5,0,765,35);$view.Timeline.Maximum=1000;$view.Timeline.TickStyle='None';$view.Timeline.Anchor='Top, Left, Right';$view.Timeline.Enabled=$false;$view.Transport.Controls.Add($view.Timeline)
    $back=New-Object Windows.Forms.Button;$back.Text='后退 10 秒';$back.SetBounds(10,40,100,32);$view.Transport.Controls.Add($back)
    $view.Pause=New-Object Windows.Forms.Button;$view.Pause.Text='暂停';$view.Pause.SetBounds(120,40,85,32);$view.Transport.Controls.Add($view.Pause)
    $forward=New-Object Windows.Forms.Button;$forward.Text='快进 10 秒';$forward.SetBounds(215,40,100,32);$view.Transport.Controls.Add($forward)
    $view.Rate=New-Object Windows.Forms.ComboBox;$view.Rate.DropDownStyle='DropDownList';$view.Rate.SetBounds(330,44,85,27);[void]$view.Rate.Items.AddRange(@('0.5x','1x','1.5x','2x','3x','4x'));$view.Rate.SelectedIndex=1;$view.Transport.Controls.Add($view.Rate)
    $view.Time=New-Object Windows.Forms.Label;$view.Time.Text='00:00:00 / --:--:--';$view.Time.SetBounds(430,47,325,25);$view.Transport.Controls.Add($view.Time)
    $view.SeekAction={if($view.Player -and $view.Player.Ready){$view.Player.Seek($view.Timeline.Value/1000.0*$view.Player.Duration)}}.GetNewClosure()
    $view.Timeline.Add_MouseDown({$view.Seeking=$true}.GetNewClosure())
    $view.Timeline.Add_MouseUp({$view.Seeking=$false;& $view.SeekAction}.GetNewClosure())
    $view.Timeline.Add_Scroll({if(-not $view.Seeking){& $view.SeekAction}}.GetNewClosure())
    $view.Pause.Add_Click({if($view.Player){$view.Player.SetPaused(-not $view.Player.Paused)}}.GetNewClosure())
    $back.Add_Click({if($view.Player){$view.Player.Seek($view.Player.Position-10)}}.GetNewClosure())
    $forward.Add_Click({if($view.Player){$view.Player.Seek($view.Player.Position+10)}}.GetNewClosure())
    $view.Rate.Add_SelectedIndexChanged({if($view.Player){$view.Player.SetRate([double]::Parse($view.Rate.Text.TrimEnd('x'),[Globalization.CultureInfo]::InvariantCulture))}}.GetNewClosure())
    $view.Status=New-Object Windows.Forms.Label;$view.Status.SetBounds(20,600,650,35);$view.Status.Text='选择录像、私钥并输入密码；双击画面可全屏，Esc 退出。';$Parent.Controls.Add($view.Status)
    $fullButton=New-Object Windows.Forms.Button;$fullButton.Text='全屏';$fullButton.SetBounds(690,595,110,32);$Parent.Controls.Add($fullButton)
    $view.RestoreFullScreen={
        if(-not $view.FullScreen){return}
        $full=$view.FullScreen;$view.FullScreen=$null
        $view.Picture.Dock='None';$view.EmbeddedParent.Controls.Add($view.Picture);$view.Picture.Bounds=$view.EmbeddedBounds
        $view.Transport.Dock='None';$view.EmbeddedParent.Controls.Add($view.Transport);$view.Transport.Bounds=$view.TransportBounds
        $view.ExitButton=$null
        $full.Dispose()
    }.GetNewClosure()
    # Bind at the outer scope; a closure created inside ToggleFullScreen loses $view.
    $view.ExitFullScreenAction={param($sender,$eventArgs) & $view.RestoreFullScreen}.GetNewClosure()
    $view.FullScreenKeyAction={param($sender,$eventArgs)
        if($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Escape){$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true;& $view.RestoreFullScreen}
    }.GetNewClosure()
    $view.ToggleFullScreen={param([bool]$Show=$true)
        if($view.FullScreen){& $view.RestoreFullScreen;return}
        $full=New-Object Windows.Forms.Form;$full.Text='录像播放';$full.FormBorderStyle='None';$full.BackColor='Black';$full.ForeColor='White';$full.KeyPreview=$true
        $full.StartPosition='Manual';$full.Bounds=[Windows.Forms.Screen]::FromControl($view.Picture).Bounds
        $view.EmbeddedBounds=$view.Picture.Bounds;$view.TransportBounds=$view.Transport.Bounds;$view.FullScreen=$full
        $view.Picture.Dock='Fill';$full.Controls.Add($view.Picture)
        $view.Transport.Dock='Bottom';$full.Controls.Add($view.Transport);$view.Transport.BringToFront()
        $header=New-Object Windows.Forms.Panel;$header.Height=50;$header.BackColor='Black';$header.Dock='Top';$full.Controls.Add($header);$header.BringToFront()
        $exit=New-Object Windows.Forms.Button;$exit.Text='退出全屏（Esc）';$exit.BackColor='WhiteSmoke';$exit.ForeColor='Black';$exit.UseVisualStyleBackColor=$false;$exit.FlatStyle='Standard'
        $exit.SetBounds(($full.ClientSize.Width-170),8,150,34);$exit.Anchor='Top, Right';$header.Controls.Add($exit);$view.ExitButton=$exit
        $exit.Add_Click($view.ExitFullScreenAction)
        $full.Add_KeyDown($view.FullScreenKeyAction)
        $full.Add_FormClosing($view.ExitFullScreenAction)
        if($Show){$full.Show($view.EmbeddedParent.FindForm());$full.Activate()}
    }.GetNewClosure()
    $fullButton.Add_Click({& $view.ToggleFullScreen $true}.GetNewClosure())
    $view.Picture.Add_DoubleClick({& $view.ToggleFullScreen $true}.GetNewClosure())
    $view.RefreshAction={& $view.Refresh $view}.GetNewClosure()
    $refresh.Add_Click($view.RefreshAction)
    $openFile.Add_Click({
        $d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='加密录像 (*.rgrec)|*.rgrec'
        try{if($d.ShowDialog() -eq 'OK'){$file=Get-Item -LiteralPath $d.FileName;$item=New-Object Windows.Forms.ListViewItem($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'));$seconds=& $view.GetDuration $file.FullName;[void]$item.SubItems.Add($(if($seconds){[TimeSpan]::FromSeconds($seconds).ToString('hh\:mm\:ss')}else{'待读取'}));[void]$item.SubItems.Add(('{0:N1} MB' -f ($file.Length/1MB)));[void]$item.SubItems.Add($file.Name);$item.Tag=$file.FullName;[void]$view.List.Items.Add($item);$item.Selected=$true}}finally{$d.Dispose()}
    }.GetNewClosure())
    $keyBrowse.Add_Click({$d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='播放私钥 (*.rgkey)|*.rgkey';try{if($d.ShowDialog() -eq 'OK'){$view.Key.Text=$d.FileName}}finally{$d.Dispose()}}.GetNewClosure())
    $view.StopAction={& $view.Stop $view;$view.Status.Text='播放已停止。'}.GetNewClosure()
    $stop.Add_Click($view.StopAction)
    $play.Add_Click({
        try {
            & $view.Stop $view
            if($view.List.SelectedItems.Count -ne 1){throw '请先选择录像'}
            if(-not(Test-Path -LiteralPath $view.Key.Text -PathType Leaf)){throw '请选择播放私钥'}
            $encoder=Join-Path $view.Root.Text 'ffmpeg\ffmpeg.exe'
            $configPath=Join-Path $view.Root.Text 'recording.json'
            if(Test-Path -LiteralPath $configPath){$cfg=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json;if($cfg.ffmpeg){$encoder=$cfg.ffmpeg}}
            if(-not(Test-Path -LiteralPath $encoder)){throw '请先在录屏页面释放内置组件（无需启用录屏即可播放）'}
            $view.CurrentFile=[string]$view.List.SelectedItems[0].Tag;$view.DurationSaved=$false
            $view.Player=[RemoteGuard.Preview]::new($view.CurrentFile,$view.Key.Text,$view.Password.Text,$encoder)
            $view.Player.SetRate([double]::Parse($view.Rate.Text.TrimEnd('x'),[Globalization.CultureInfo]::InvariantCulture))
            $view.Password.Clear();$view.Status.Text='正在验证并解锁录像……';$view.Timer.Start()
        }catch{$view.Password.Clear();$view.Status.Text='播放失败: '+$_.Exception.Message}
    }.GetNewClosure())
    $view.Timer=New-Object Windows.Forms.Timer;$view.Timer.Interval=100
    $view.Timer.Add_Tick({
        try {
            if(-not $view.Player){return}
            if($view.Player.Error){$errorText=$view.Player.Error;& $view.Stop $view;$view.Status.Text='播放失败: '+$errorText;return}
            $frame=$view.Player.TakeFrame()
            if($frame){
                $bitmap=New-Object Drawing.Bitmap([RemoteGuard.Preview]::Width,[RemoteGuard.Preview]::Height,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $data=$bitmap.LockBits([Drawing.Rectangle]::new(0,0,[RemoteGuard.Preview]::Width,[RemoteGuard.Preview]::Height),[Drawing.Imaging.ImageLockMode]::WriteOnly,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
                try{[Runtime.InteropServices.Marshal]::Copy($frame,0,$data.Scan0,$frame.Length)}finally{$bitmap.UnlockBits($data)}
                $old=$view.Picture.Image;$view.Picture.Image=$bitmap;if($old){$old.Dispose()};$view.Status.Text='正在播放（5 帧/秒，无声音）。'
            }
            if($view.Player.Ready){
                $view.Timeline.Enabled=$true;$duration=$view.Player.Duration;$position=$view.Player.Position
                if(-not $view.Seeking){$view.Timeline.Value=[int][math]::Min(1000,[math]::Max(0,$position/$duration*1000))}
                $view.Time.Text=[TimeSpan]::FromSeconds($position).ToString('hh\:mm\:ss')+' / '+[TimeSpan]::FromSeconds($duration).ToString('hh\:mm\:ss')
                $view.Pause.Text=if($view.Player.Paused){'继续'}else{'暂停'}
                $view.Status.Text=if($view.Player.Done){'播放结束，可拖动进度或点击继续重播。'}elseif($view.Player.Paused){'已暂停。'}else{'正在播放（'+$view.Rate.Text+'）。'}
                if(-not $view.DurationSaved){
                    $view.DurationSaved=$true
                    try{& $view.SetDuration $view.CurrentFile $duration}catch{ }
                    foreach($item in $view.List.Items){if($item.Tag -eq $view.CurrentFile){$item.SubItems[1].Text=[TimeSpan]::FromSeconds($duration).ToString('hh\:mm\:ss')}}
                }
            }
        }catch{& $view.Stop $view;$view.Status.Text='播放失败: '+$_.Exception.Message}
    }.GetNewClosure())
    return $view
}

function Stop-GuardPreview($View) {
    if($View.FullScreen){& $View.RestoreFullScreen}
    $View.Timer.Stop();$View.Timeline.Enabled=$false;$View.Timeline.Value=0;$View.Seeking=$false
    if($View.Player){$View.Player.Dispose();$View.Player=$null}
    $old=$View.Picture.Image;$View.Picture.Image=$null;if($old){$old.Dispose()}
}

function Refresh-GuardLibrary($View) {
    $View.List.Items.Clear()
    try {
        $cfg=Get-Content -LiteralPath (Join-Path $View.Root.Text 'recording.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        if(-not(Test-Path -LiteralPath $cfg.directory)){return}
        foreach($file in @(& $View.GetFiles $cfg.directory | Where-Object Extension -eq '.rgrec' | Sort-Object LastWriteTimeUtc -Descending)) {
            $item=New-Object Windows.Forms.ListViewItem($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'));$seconds=& $view.GetDuration $file.FullName;[void]$item.SubItems.Add($(if($seconds){[TimeSpan]::FromSeconds($seconds).ToString('hh\:mm\:ss')}else{'待读取'}));[void]$item.SubItems.Add(('{0:N1} MB' -f ($file.Length/1MB)));[void]$item.SubItems.Add($file.Name);$item.Tag=$file.FullName;[void]$View.List.Items.Add($item)
        }
    }catch{$View.Status.Text='尚无可读取的录像，请先配置录屏。'}
}
