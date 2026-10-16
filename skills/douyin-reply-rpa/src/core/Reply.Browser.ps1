function Get-ReplyBrowserProfilePath($EnvInfo) {
    return [IO.Path]::GetFullPath((Join-Path $EnvInfo.DataRoot 'browser-profile'))
}
function Open-ReplyBrowser($EnvInfo) {
    if((Get-ReplyStatus $EnvInfo '').Running){throw '请先暂停现有回复任务，再打开测试浏览器。'}
    if(Test-Path -LiteralPath (Join-Path $EnvInfo.StateRoot 'interactive-launch.json')){throw '存在待确认的任务启动，暂不打开测试浏览器。'}
    if((Get-ReplyCallerSessionId) -le 0){throw 'OpenBrowser 需要在当前账号的交互桌面会话调用。'}
    if(-not ('DingRpa' -as [type])){Add-Type -Path (Join-Path $EnvInfo.SharedRoot 'native\DingRpa.cs')}
    if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw '请先解锁 Default 桌面。'}
    . (Join-Path $EnvInfo.SharedRoot 'douyin\Browser.ps1')
    $profile=Get-ReplyBrowserProfilePath $EnvInfo
    $null=New-Item -ItemType Directory -Path $profile -Force
    if((Get-Item -LiteralPath $profile -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '独立 profile 目录不能是链接。'}
    $existing=@([DingRpa]::ListWindows() | Where-Object {$_.Visible -and (Test-DouyinProcessProfile $_.ProcessId $profile)})
    if($existing.Count -gt 1){throw '独立 profile 已有多个窗口，请保留一个窗口。'}
    $restarted=$false
    if($existing.Count -eq 1){
        $identity=Get-CimInstance Win32_Process -Filter ('ProcessId='+$existing[0].ProcessId) -ErrorAction Stop
        if($identity.CommandLine -notmatch '(?:^|\s)--no-proxy-server(?=\s|$)'){
            # Chrome 会复用同一数据目录的进程；旧进程必须正常退出后，新参数才能生效。
            $process=Get-Process -Id $existing[0].ProcessId -ErrorAction Stop
            if(-not (Test-DouyinProcessProfile $process.Id $profile) -or $process.MainWindowHandle.ToInt64() -ne $existing[0].Handle){throw '无法确认唯一测试窗口，停止重启。'}
            if(-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)){throw '测试浏览器尚未正常退出；不强制结束进程，请处理窗口中的提示后重试。'}
            $existing=@();$restarted=$true
        }
    }
    $reused=($existing.Count -eq 1)
    if(-not $reused){
        $paths=@((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),(Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))
        $executable=@($paths | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf} | Select-Object -First 1)
        if($executable.Count -ne 1){throw '未找到 Chrome 安装程序。'}
        $arguments='--user-data-dir='+(ConvertTo-ReplyArgument $profile)+' --no-proxy-server --no-first-run --no-default-browser-check --force-renderer-accessibility --new-window https://www.douyin.com/'
        # 用户明确要求可操作的独立测试浏览器，因此此处显示浏览器窗口。
        $null=Start-Process -FilePath $executable[0] -ArgumentList $arguments -WindowStyle Normal -PassThru
        $timer=[Diagnostics.Stopwatch]::StartNew()
        do{
            Start-Sleep -Milliseconds 300
            $existing=@([DingRpa]::ListWindows() | Where-Object {$_.Visible -and (Test-DouyinProcessProfile $_.ProcessId $profile)})
        }while($existing.Count -eq 0 -and $timer.Elapsed.TotalSeconds -lt 20)
        if($existing.Count -ne 1){throw '测试浏览器窗口尚未唯一确认；不会改用个人浏览器。'}
    }
    $window=$existing[0]
    $identity=Get-CimInstance Win32_Process -Filter ('ProcessId='+$window.ProcessId) -ErrorAction Stop
    if($identity.CommandLine -notmatch '(?:^|\s)--no-proxy-server(?=\s|$)'){throw '测试浏览器未携带直连参数，停止后续操作。'}
    return [pscustomobject]@{Ok=$true;Action='OpenBrowser';UserDataDirectory=$profile;ProcessId=$window.ProcessId;WindowHandle=$window.Handle;Reused=$reused;RestartedForDirectConnection=$restarted;NetworkMode='Direct';BusinessTaskStarted=$false}
}
