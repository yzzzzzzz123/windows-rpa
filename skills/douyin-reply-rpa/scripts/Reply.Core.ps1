. (Join-Path $PSScriptRoot '..\src\core\Reply.Configuration.ps1')
. (Join-Path $PSScriptRoot '..\src\core\Reply.Session.ps1')
function Read-ReplyJson([string]$Path) {
    for($attempt=0;$attempt -lt 4;$attempt++){
        $stream=$null;$reader=$null
        try{
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
            $json=$reader.ReadToEnd();break
        }catch [IO.IOException]{
            if($attempt -ge 3 -or ($_.Exception.HResult -band 65535) -notin @(2,3,32,33)){throw}
            Start-Sleep -Milliseconds 20
        }finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
    }
    return ($json | ConvertFrom-Json)
}
function Write-ReplyJson($Value,[string]$Path) {
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Value -Depth 20),(New-Object Text.UTF8Encoding($false)))
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Get-ReplyEnvironment([string]$DataRoot) {
    $skillRoot=Split-Path $PSScriptRoot -Parent
    for($depth=0;$depth -lt 8;$depth++){
        $item=Get-Item -LiteralPath $skillRoot -Force
        if(-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){break}
        $target=@($item.Target)[0]
        if(-not $target){throw '无法解析 Skill 目录链接。'}
        if(-not [IO.Path]::IsPathRooted($target)){$target=Join-Path (Split-Path $skillRoot -Parent) $target}
        $skillRoot=[IO.Path]::GetFullPath($target)
    }
    if((Get-Item -LiteralPath $skillRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Skill 目录链接层数过多。'}
    $shared=Join-Path $skillRoot 'shared'
    if(-not (Test-Path -LiteralPath (Join-Path $shared 'Runtime.ps1'))){$shared=[IO.Path]::GetFullPath((Join-Path $skillRoot '..\..\shared'))}
    . (Join-Path $shared 'Runtime.ps1')
    $layout=Get-RpaLayout $skillRoot
    if(-not $DataRoot){$DataRoot=$layout.DataRoot}
    $data=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DataRoot)
    $state=Join-Path $data 'state'
    $sharedSubmission=if($layout.RepositoryRoot){Join-Path $layout.RepositoryRoot 'data\douyin-rpa\state'}else{$state}
    return [pscustomobject]@{SkillRoot=$skillRoot;RuntimeRoot=$skillRoot;SharedRoot=$layout.SharedRoot;RepositoryRoot=$layout.RepositoryRoot;VersionPath=$layout.VersionPath;DataRoot=$data;StateRoot=$state;SharedSubmissionRoot=$sharedSubmission;JobsRoot=(Join-Path $data 'jobs')}
}
function Get-ReplyJobPath($EnvInfo,[string]$JobId) {
    if($JobId -cnotmatch '^\d{8}_\d{9}-[a-f0-9]{12}$'){throw 'JobId 格式无效。'}
    return Join-Path $EnvInfo.JobsRoot $JobId
}
function Test-ReplyProcess($Job) {
    if(-not $Job.ProcessId -or -not $Job.ProcessStartTicks){return $false}
    try{$process=Get-Process -Id $Job.ProcessId -ErrorAction Stop;return ($process.ProcessName -eq 'powershell' -and $process.StartTime.ToUniversalTime().Ticks.ToString() -eq $Job.ProcessStartTicks)}catch{return $false}
}
function Get-ReplyStatus($EnvInfo,[string]$JobId) {
    if(-not $JobId){
        $latest=Join-Path $EnvInfo.DataRoot 'latest.json'
        if(-not (Test-Path -LiteralPath $latest)){return [pscustomobject]@{Ok=$true;Status='NoRuns';Running=$false;DataRoot=$EnvInfo.DataRoot;StateRoot=$EnvInfo.StateRoot}}
        $JobId=(Read-ReplyJson $latest).JobId
    }
    $directory=Get-ReplyJobPath $EnvInfo $JobId
    $job=Read-ReplyJson (Join-Path $directory 'job.json')
    if($job.JobId -cne $JobId -or $job.DataRoot -ne $EnvInfo.DataRoot -or $job.StateRoot -ne $EnvInfo.StateRoot){throw '任务身份或状态路径不匹配。'}
    $alive=Test-ReplyProcess $job
    $reportPath=Join-Path $directory 'evidence\result.json';$candidatesPath=Join-Path $directory 'evidence\candidates.json'
    $report=if(Test-Path -LiteralPath $reportPath){Read-ReplyJson $reportPath}else{$null}
    $workerPath=Join-Path $directory 'worker-result.json'
    $worker=if(Test-Path -LiteralPath $workerPath){Read-ReplyJson $workerPath}else{$null}
    $status=if($report){$report.Status}elseif($worker){$worker.Status}elseif($alive){'Starting'}else{'Interrupted'}
    if(-not $alive -and $status -in @('Starting','Running','WaitingForVerification','Paused')){$status='Interrupted'}
    $pause=Test-Path -LiteralPath (Join-Path $job.StateRoot 'control\pause')
    $stop=Test-Path -LiteralPath (Join-Path $job.StateRoot 'control\stop')
    if($alive -and $report.Paused){$status='Paused'}
    $heartbeatAge=if($report.HeartbeatAt){[Math]::Max(0,[Math]::Round(([DateTimeOffset]::Now-[DateTimeOffset]::Parse($report.HeartbeatAt)).TotalSeconds,1))}else{$null}
    return [pscustomobject]@{
        Ok=$true;JobId=$JobId;Mode=$job.Mode;Running=[bool]$alive;Status=$status;Stage=$report.Stage;UpdatedAt=$report.UpdatedAt
        HeartbeatAt=$report.HeartbeatAt;HeartbeatAgeSeconds=$heartbeatAge;Health=$(if(-not $alive){'Stopped'}elseif($null -eq $heartbeatAge){'Unknown'}elseif($heartbeatAge -gt 60){'Stalled'}else{'Responsive'})
        ProcessId=$job.ProcessId;Paused=[bool]($alive -and $report.Paused);PauseRequested=[bool]($alive -and $pause);StopRequested=[bool]($alive -and $stop)
        Submitted=[int]$report.Submitted;Previewed=[int]$report.Previewed;Skipped=[int]$report.Skipped;Processed=[int]$report.Processed;CandidateCount=[int]$report.CandidateCount
        NextSubmissionAt=$report.NextSubmissionAt;Reason=$(if($report.Reason){$report.Reason}elseif($worker.Reason){$worker.Reason}elseif($status -eq 'Interrupted'){'进程已退出且没有完整结束报告；未知提交不得自动重试。'}else{$null})
        ReportPath=$reportPath;CandidatesPath=$candidatesPath;LogPath=(Join-Path $directory 'stdout.log');ErrorLogPath=(Join-Path $directory 'stderr.log');DataRoot=$EnvInfo.DataRoot;StateRoot=$job.StateRoot;SharedSubmissionRoot=$job.SharedSubmissionRoot
    }
}
function Get-ReplyCandidates($EnvInfo,[string]$JobId) {
    $status=Get-ReplyStatus $EnvInfo $JobId
    if(-not $status.JobId){return [pscustomobject]@{Ok=$true;Status='NoRuns';Candidates=@()}}
    $candidates=@()
    if(Test-Path -LiteralPath $status.CandidatesPath){$candidates=@(Read-ReplySourceCandidates $EnvInfo $status.JobId)}
    return [pscustomobject]@{Ok=$true;JobId=$status.JobId;Status=$status.Status;Running=$status.Running;CandidatesPath=$status.CandidatesPath;Candidates=$candidates}
}
function Read-ReplySourceCandidates($EnvInfo,[string]$SourceJobId) {
    $directory=Get-ReplyJobPath $EnvInfo $SourceJobId
    $path=Join-Path $directory 'evidence\candidates.json'
    foreach($part in @($EnvInfo.JobsRoot,$directory,(Join-Path $directory 'evidence'),$path)){
        if((Get-Item -LiteralPath $part -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '候选来源不能通过链接跳出本任务数据目录。'}
    }
    $sourceJob=Read-ReplyJson (Join-Path $directory 'job.json')
    if($sourceJob.JobId -cne $SourceJobId -or $sourceJob.DataRoot -ne $EnvInfo.DataRoot -or $sourceJob.Mode -ne 'Discover'){throw '候选来源必须是同一 DataRoot 下的 Discover 任务。'}
    $source=Read-ReplyJson $path
    $candidates=if($null -eq $source){@()}elseif($source -is [pscustomobject] -and $source.PSObject.Properties.Name -contains 'Candidates'){@($source.Candidates)}else{@($source)}
    if($candidates.Count -gt 1000){throw '候选来源超过数量上限。'}
    $ids=@{}
    foreach($candidate in $candidates){
        Assert-ReplyCandidate $candidate
        if($ids.ContainsKey($candidate.CandidateId)){throw '候选来源存在重复 CandidateId。'}
        $ids[$candidate.CandidateId]=$true
    }
    return $candidates
}
function New-ReplyConfiguration($Task,$EnvInfo,[string]$ConfigPath) {
    if($Task -isnot [pscustomobject]){throw '任务必须是 JSON 对象。'}
    if($Task.Mode -notin @('Discover','Preview','Publish')){throw 'Mode 必须为 Discover、Preview 或 Publish。'}
    $allowed=if($Task.Mode -eq 'Discover'){@('Mode','SearchTerms','MatchAny','MaxVideos','MaxCommentsPerVideo','MaxScrollRounds')}else{@('Mode','SourceJobId','Replies')}
    foreach($name in $Task.PSObject.Properties.Name){if($name -notin $allowed){throw ('未知或不适用的任务字段：'+$name)}}
    $config=Read-ReplyJson (Join-Path $EnvInfo.RuntimeRoot 'config\reply.json')
    foreach($pair in @(@('Mode',$Task.Mode),@('SourceJobId',$null),@('Replies',@()))){$config|Add-Member NoteProperty $pair[0] $pair[1] -Force}
    if($Task.Mode -eq 'Discover'){
        foreach($name in @('SearchTerms','MatchAny','MaxVideos','MaxCommentsPerVideo','MaxScrollRounds')){if($Task.PSObject.Properties.Name -contains $name){$config.$name=$Task.$name}}
    }else{
        if($Task.Replies -isnot [array] -or $Task.Replies.Count -lt 1 -or $Task.Replies.Count -gt 10){throw 'Replies 必须为 1 至 10 项数组。'}
        $candidates=@(Read-ReplySourceCandidates $EnvInfo $Task.SourceJobId)
        $normalized=@(foreach($reply in $Task.Replies){
            if($reply -isnot [pscustomobject]){throw '每条 Replies 必须为 JSON 对象。'}
            foreach($name in $reply.PSObject.Properties.Name){if($name -notin @('CandidateId','ReplyText','Reason')){throw ('回复不允许覆盖候选资料：'+$name)}}
            $matches=@($candidates | Where-Object {$_.CandidateId -ceq $reply.CandidateId})
            if($matches.Count -ne 1){throw 'CandidateId 不在指定来源候选中。'}
            $candidate=$matches[0] | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $candidate|Add-Member NoteProperty ReplyText $reply.ReplyText -Force
            $candidate|Add-Member NoteProperty Reason $reply.Reason -Force
            $candidate|Add-Member NoteProperty SourceJobId $Task.SourceJobId -Force
            $candidate
        })
        $config.SourceJobId=$Task.SourceJobId;$config.Replies=$normalized
    }
    $null=Assert-ReplyConfiguration $config
    Write-ReplyJson $config $ConfigPath
    return $config
}
function ConvertTo-ReplyArgument([string]$Value) {
    if($Value -match '["\r\n]' -or $Value.EndsWith('\')){throw '进程参数路径包含不支持的字符。'}
    return '"'+$Value+'"'
}
function Invoke-ReplyControl($EnvInfo,[string]$Action,[string]$JobId,$Active) {
    $current=Get-ReplyStatus $EnvInfo $JobId
    if(-not $current.Running){throw '该任务已经结束；控制指令不会重新启动它。'}
    if(-not $Active -or $Active.JobId -cne $current.JobId -or $Active.DataRoot -ne $EnvInfo.DataRoot -or -not (Test-ReplyProcess $Active)){throw '任务不是此状态目录的当前实例，拒绝控制其他任务。'}
    $control=Join-Path $current.StateRoot 'control'
    if($Action -eq 'Resume'){
        if(Test-Path -LiteralPath (Join-Path $control 'stop')){throw '已请求停止的任务不能恢复。'}
        $pause=Join-Path $control 'pause';if(Test-Path -LiteralPath $pause){Remove-Item -LiteralPath $pause -Force}
    }elseif($Action -in @('Pause','Stop')){
        $name=if($Action -eq 'Pause'){'pause'}else{'stop'}
        [IO.File]::WriteAllText((Join-Path $control $name),(Get-Date -Format o))
    }else{throw '未知控制指令。'}
    $output=Get-ReplyStatus $EnvInfo $current.JobId
    $output|Add-Member NoteProperty ControlRequested $Action
    return $output
}
