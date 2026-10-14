function Read-SkillJson([string]$Path) {
    # 状态由另一个进程原子替换；允许文件替换，只重试短暂的路径/共享冲突。
    for($attempt=0;$attempt -lt 4;$attempt++){
        $stream=$null;$reader=$null
        try{
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
            $json=$reader.ReadToEnd()
            break
        }catch [IO.IOException]{
            $code=$_.Exception.HResult -band 65535
            if($attempt -ge 3 -or $code -notin @(2,3,32,33)){throw}
            Start-Sleep -Milliseconds 20
        }finally{
            if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}
        }
    }
    return ($json | ConvertFrom-Json)
}
function Write-SkillJson($Value,[string]$Path) {
    $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Value -Depth 14),(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
}
function Get-SkillEnvironment([string]$DataRoot) {
    $skillRoot=Split-Path $PSScriptRoot -Parent
    # Resolve a discovery junction back to the single source and shared data identity.
    for($linkDepth=0;$linkDepth -lt 8;$linkDepth++){
        $item=Get-Item -LiteralPath $skillRoot -Force
        if(-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){break}
        $target=@($item.Target)[0]
        if(-not $target){throw '无法解析 Skill 目录链接。'}
        if(-not [IO.Path]::IsPathRooted($target)){$target=Join-Path (Split-Path $skillRoot -Parent) $target}
        $skillRoot=[IO.Path]::GetFullPath($target)
    }
    $sharedRoot=Join-Path $skillRoot 'shared'
    if(-not (Test-Path -LiteralPath (Join-Path $sharedRoot 'Runtime.ps1'))){$sharedRoot=[IO.Path]::GetFullPath((Join-Path $skillRoot '..\..\shared'))}
    . (Join-Path $sharedRoot 'Runtime.ps1')
    $layout=Get-RpaLayout $skillRoot
    $customData=[bool]$DataRoot
    if(-not $DataRoot){$DataRoot=$layout.DataRoot}
    $data=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DataRoot)
    $runtime=$skillRoot
    if(-not (Test-Path -LiteralPath (Join-Path $runtime 'scripts\Invoke-DouyinRpa.ps1'))){throw '缺少随包运行代码，请重新构建或安装 Skill。'}
    $state=if($customData){Join-Path $data 'state'}else{$layout.StateRoot}
    $settingsPath=Join-Path $data 'settings.json'
    if(Test-Path -LiteralPath $settingsPath){
        $settings=Read-SkillJson $settingsPath
        if(-not $settings.StateRoot -or -not [IO.Path]::IsPathRooted($settings.StateRoot)){throw 'StateRoot 设置必须是绝对路径。'}
        $state=[IO.Path]::GetFullPath($settings.StateRoot)
    }
    return [pscustomobject]@{SkillRoot=$skillRoot;RuntimeRoot=$runtime;SharedRoot=$layout.SharedRoot;VersionPath=$layout.VersionPath;RunsRoot=$layout.RunsRoot;LegacyRoot=$layout.LegacyRoot;DataRoot=$data;StateRoot=$state;JobsRoot=(Join-Path $data 'jobs')}
}
function Get-SkillJobPath($EnvInfo,[string]$JobId) {
    if($JobId -notmatch '^\d{8}_\d{9}-[0-9a-f]{12}$'){throw 'JobId 格式无效。'}
    return Join-Path $EnvInfo.JobsRoot $JobId
}
function Test-SkillProcess($Job) {
    if(-not $Job.ProcessId -or -not $Job.ProcessStartTicks){return $false}
    $process=Get-Process -Id $Job.ProcessId -ErrorAction SilentlyContinue
    return ($null -ne $process -and $process.ProcessName -eq 'powershell' -and $process.StartTime.ToUniversalTime().Ticks.ToString() -eq $Job.ProcessStartTicks)
}
function Get-SkillStatus($EnvInfo,[string]$JobId,[switch]$Lightweight) {
    if(-not $JobId){
        $latest=Join-Path $EnvInfo.DataRoot 'latest.json'
        if(-not (Test-Path -LiteralPath $latest)){return [pscustomobject]@{Ok=$true;Status='NoRuns';Running=$false;DataRoot=$EnvInfo.DataRoot;StateRoot=$EnvInfo.StateRoot}}
        $JobId=(Read-SkillJson $latest).JobId
    }
    $jobDir=Get-SkillJobPath $EnvInfo $JobId
    $job=Read-SkillJson (Join-Path $jobDir 'job.json')
    $alive=Test-SkillProcess $job
    $reportFile=Get-ChildItem -LiteralPath (Join-Path $jobDir 'evidence') -Filter result.json -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $report=if($reportFile){Read-SkillJson $reportFile.FullName}else{$null}
    $workerFile=Join-Path $jobDir 'worker-result.json'
    $worker=if(Test-Path -LiteralPath $workerFile){Read-SkillJson $workerFile}else{$null}
    $status=if($report){$report.Status}elseif($worker){$worker.Status}elseif($alive){'Starting'}else{'Interrupted'}
    if(-not $alive -and $status -in @('Starting','Running','WaitingForVerification')){$status='Interrupted'}
    $pause=Test-Path -LiteralPath (Join-Path $job.StateRoot 'control\pause')
    $stop=Test-Path -LiteralPath (Join-Path $job.StateRoot 'control\stop')
    if($alive -and $report.Paused){$status='Paused'}
    $imageFile=if(-not $Lightweight){Get-ChildItem -LiteralPath (Join-Path $jobDir 'evidence') -Filter '*.png' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1}else{$null}
    $heartbeatAge=if($report.HeartbeatAt){[Math]::Max(0,[Math]::Round(([DateTimeOffset]::Now-[DateTimeOffset]::Parse($report.HeartbeatAt)).TotalSeconds,1))}else{$null}
    $health=if(-not $alive){'Stopped'}elseif($null -eq $heartbeatAge){'Unknown'}elseif($heartbeatAge -gt 60){'Stalled'}else{'Responsive'}
    $monitor=Get-SkillMonitorStatus $EnvInfo
    return [pscustomobject]@{
        Ok=$true;JobId=$JobId;Mode=$job.Mode;Running=[bool]$alive;Status=$status;Stage=$report.Stage;UpdatedAt=$report.UpdatedAt
        HeartbeatAt=$report.HeartbeatAt;HeartbeatAgeSeconds=$heartbeatAge;Health=$health
        CommentIntervalSeconds=$report.CommentIntervalSeconds;NextSubmissionAt=$report.NextSubmissionAt;NextCycleAt=$report.NextCycleAt
        KeywordTotal=$report.KeywordTotal;KeywordPending=$report.KeywordPending;KeywordCompleted=$report.KeywordCompleted;CurrentSearchTerm=$report.CurrentSearchTerm
        MonitorRunning=$monitor.Running;MonitorUpdatedAt=$monitor.UpdatedAt;MonitorPath=$monitor.SnapshotPath
        ProcessId=$job.ProcessId;Paused=[bool]($alive -and $report.Paused);PauseRequested=[bool]($alive -and $pause);StopRequested=[bool]($alive -and $stop)
        Processed=$report.Processed;Submitted=$report.Submitted;Published=$report.Published;Previewed=$report.Previewed;Skipped=$report.Skipped;RecoverableErrors=$report.RecoverableErrors;LastError=$report.LastError;LastVideoId=$report.LastVideoId
        Reason=$(if($report.Reason){$report.Reason}elseif($worker.Reason){$worker.Reason}elseif($status -eq 'Interrupted'){'进程已退出且没有完整结束报告；禁止据此重发。'}else{$null})
        ReportPath=$(if($reportFile){$reportFile.FullName}else{$null});LatestScreenshot=$(if($imageFile){$imageFile.FullName}else{$null})
        LogPath=(Join-Path $jobDir 'stdout.log');ErrorLogPath=(Join-Path $jobDir 'stderr.log');DataRoot=$EnvInfo.DataRoot;StateRoot=$job.StateRoot
    }
}
function Get-SkillMonitorStatus($EnvInfo) {
    $directory=Join-Path $EnvInfo.DataRoot 'monitor'
    $identityPath=Join-Path $directory 'process.json'
    $identity=if(Test-Path -LiteralPath $identityPath){Read-SkillJson $identityPath}else{$null}
    $snapshotPath=Join-Path $directory 'status.json'
    $snapshot=if(Test-Path -LiteralPath $snapshotPath){Read-SkillJson $snapshotPath}else{$null}
    return [pscustomobject]@{Running=[bool]($identity -and (Test-SkillProcess $identity));ProcessId=$identity.ProcessId;UpdatedAt=$snapshot.MonitorUpdatedAt;SnapshotPath=$snapshotPath}
}
function Start-SkillMonitor($EnvInfo,[switch]$Headless) {
    $directory=Join-Path $EnvInfo.DataRoot 'monitor'
    $null=New-Item -ItemType Directory -Path $directory -Force
    $launchLock=[IO.File]::Open((Join-Path $directory 'launch.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $current=Get-SkillMonitorStatus $EnvInfo
        if(-not $Headless){[IO.File]::WriteAllText((Join-Path $directory 'show'),(Get-Date -Format o))}
        if($current.Running){return $current}
        $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments='-NoProfile -NonInteractive -STA -File '+(ConvertTo-SkillArgument (Join-Path $EnvInfo.RuntimeRoot 'scripts\Watch-DouyinRpa.ps1'))+' -DataRoot '+(ConvertTo-SkillArgument $EnvInfo.DataRoot)
        if($Headless){$arguments+=' -Headless'}
        $process=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $directory 'stdout.log') -RedirectStandardError (Join-Path $directory 'stderr.log')
        Write-SkillJson ([ordered]@{ProcessId=$process.Id;ProcessStartTicks=$process.StartTime.ToUniversalTime().Ticks.ToString()}) (Join-Path $directory 'process.json')
        return Get-SkillMonitorStatus $EnvInfo
    }finally{$launchLock.Dispose()}
}
function New-SkillConfiguration($Task,$EnvInfo,[string]$ConfigPath) {
    if($Task -isnot [pscustomobject]){throw '任务必须是 JSON 对象。'}
    $allowed=@('Mode','SearchTerms','MatchAny','Comment','MaxVideos','Continuous','CommentIntervalSeconds','EmptyQueueWaitSeconds')
    foreach($property in $Task.PSObject.Properties.Name){if($property -notin $allowed){throw ('未知任务字段：'+$property)}}
    if($Task.Mode -notin @('Preview','Publish','Inspect','Check')){throw 'Mode 必须为 Preview、Publish、Inspect 或 Check。'}
    $continuous=$false
    if($Task.PSObject.Properties.Name -contains 'Continuous'){
        if($Task.Continuous -isnot [bool]){throw 'Continuous 必须是布尔值。'}
        $continuous=$Task.Continuous
    }
    $max=1
    if($Task.PSObject.Properties.Name -contains 'MaxVideos'){
        $max=$Task.MaxVideos
        if($max -isnot [ValueType] -or $max -is [bool] -or [double]$max -ne [Math]::Truncate([double]$max) -or $max -lt 0 -or $max -gt 1000000){throw 'MaxVideos 必须是 0 至 1000000 的整数。'}
    }
    if(($continuous -and $Task.Mode -ne 'Publish') -or ($max -eq 0 -and -not $continuous)){throw '无上限必须明确选择 Publish、Continuous=true 和 MaxVideos=0。'}
    if($Task.Mode -eq 'Publish' -and $Task.PSObject.Properties.Name -notcontains 'Comment'){throw '真实发布任务必须显式提供 Comment。'}
    $config=Read-SkillJson (Join-Path $EnvInfo.RuntimeRoot 'config\douyin.json')
    foreach($name in @('SearchTerms','MatchAny','Comment')){if($Task.PSObject.Properties.Name -contains $name){$config.$name=$Task.$name}}
    foreach($name in @('SearchTerms','MatchAny')){if($config.$name -isnot [array]){throw ($name+' 必须为数组。')}}
    foreach($name in @('CommentIntervalSeconds','EmptyQueueWaitSeconds')){if($Task.PSObject.Properties.Name -contains $name){$config.Timing.$name=$Task.$name}}
    Write-SkillJson $config $ConfigPath
    . (Join-Path $EnvInfo.RuntimeRoot 'src\core\Douyin.Configuration.ps1')
    $null=Read-DouyinConfiguration $ConfigPath
    return [pscustomobject]@{Mode=$Task.Mode;Continuous=[bool]$continuous;MaxVideos=[int]$max}
}
function ConvertTo-SkillArgument([string]$Value) {
    if($Value -match '["\r\n]' -or $Value.EndsWith('\')){throw '进程参数路径包含不支持的字符。'}
    return '"'+$Value+'"'
}
