function Write-RpaStateJson($Value,[string]$Path) {
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Value -Depth 20),(New-Object Text.UTF8Encoding($false)))
        # Windows 的短暂文件占用可能阻止原子替换；只重试保存同一份快照，不重放业务动作。
        for($attempt=0;$attempt -lt 8;$attempt++){
            try{
                if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
                break
            }catch [IO.IOException]{
                $failure=$_.Exception
                while($failure.InnerException){$failure=$failure.InnerException}
                if($attempt -ge 7 -or ($failure.HResult -band 65535) -notin @(5,32,33,1175) -or -not (Test-Path -LiteralPath $temporary)){throw}
                Start-Sleep -Milliseconds 50
            }
        }
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Initialize-ReplyState([string]$StateRoot,[string]$SharedSubmissionRoot) {
    if(-not [IO.Path]::IsPathRooted($StateRoot) -or -not [IO.Path]::IsPathRooted($SharedSubmissionRoot)){throw '状态路径必须为绝对路径。'}
    $script:RpaStateRoot=[IO.Path]::GetFullPath($StateRoot)
    $script:ReplySharedSubmissionRoot=[IO.Path]::GetFullPath($SharedSubmissionRoot)
    foreach($directory in @($script:RpaStateRoot,$script:ReplySharedSubmissionRoot,(Join-Path $StateRoot 'replies'),(Join-Path $StateRoot 'users'),(Join-Path $StateRoot 'control'))){$null=New-Item -ItemType Directory -Path $directory -Force}
    $script:RpaControlRoot=Join-Path $StateRoot 'control'
    # 与视频直接评论共用同一进程句柄锁，覆盖整个桌面流程；崩溃自动释放。
    $script:RpaRunLock=[IO.File]::Open((Join-Path $script:ReplySharedSubmissionRoot 'runner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
}
function Close-ReplyState {
    if($script:RpaRunLock){$script:RpaRunLock.Dispose();$script:RpaRunLock=$null}
}
function Get-ReplyLedgerPath([string]$CandidateId) {
    if($CandidateId -cnotmatch '^[a-f0-9]{64}$'){throw '候选编号格式无效。'}
    return Join-Path $script:RpaStateRoot ('replies\'+$CandidateId+'.json')
}
function Get-ReplyUserLedgerPath([string]$AuthorKey) {
    if($AuthorKey -cnotmatch '^[a-f0-9]{64}$'){throw '用户编号格式无效。'}
    return Join-Path $script:RpaStateRoot ('users\'+$AuthorKey+'.json')
}
function Test-ReplyAlreadyContacted($Candidate) {
    return ((Test-Path -LiteralPath (Get-ReplyLedgerPath $Candidate.CandidateId)) -or (Test-Path -LiteralPath (Get-ReplyUserLedgerPath $Candidate.AuthorKey)))
}
function New-ReplyExclusiveRecord($Value,[string]$Path) {
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 14))
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function New-ReplySubmissionClaim($Candidate,[string]$ReplyText) {
    if(-not $script:RpaRunLock){throw '未持有共享桌面锁，拒绝创建提交标记。'}
    Assert-ReplyCandidate $Candidate
    Assert-ReplyText $ReplyText 300 'ReplyText'
    Assert-ReplyPromotionName $ReplyText
    $candidatePath=Get-ReplyLedgerPath $Candidate.CandidateId
    $userPath=Get-ReplyUserLedgerPath $Candidate.AuthorKey
    if(Test-ReplyAlreadyContacted $Candidate){throw '该评论或用户已有提交记录；未知结果也不得重试。'}
    $record=[ordered]@{
        CandidateId=$Candidate.CandidateId;AuthorKey=$Candidate.AuthorKey;AuthorName=$Candidate.AuthorName;AuthorUrl=$Candidate.AuthorUrl
        VideoId=$Candidate.VideoId;VideoUrl=$Candidate.VideoUrl;CommentId=$Candidate.CommentId;Text=$Candidate.Text;ReplyText=$ReplyText
        Status='Submitting';Time=(Get-Date -Format o);AutomaticRetryAllowed=$false
    }
    # 任意一步中断都留下至少一个禁止重试的账；绝不为失败回滚提交声明。
    New-ReplyExclusiveRecord $record $candidatePath
    New-ReplyExclusiveRecord $record $userPath
    Set-ReplyLastSubmission $Candidate.CandidateId 'Pending' $Candidate.VideoId
    return [pscustomobject]$record
}
function Set-ReplySubmissionStatus([string]$CandidateId,[string]$Status,[string]$Reason) {
    if($Status -notin @('Submitting','Submitted','NeedsVisualReview','Unknown','Failed','Confirmed')){throw '提交账状态无效。'}
    $path=Get-ReplyLedgerPath $CandidateId
    $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $record.Status=$Status
    $record|Add-Member NoteProperty UpdatedAt (Get-Date -Format o) -Force
    $record|Add-Member NoteProperty Reason $Reason -Force
    $record|Add-Member NoteProperty AutomaticRetryAllowed $false -Force
    Write-RpaStateJson $record $path
    Write-RpaStateJson $record (Get-ReplyUserLedgerPath $record.AuthorKey)
}
function Get-ReplyIntervalTime {return [DateTimeOffset]::UtcNow}
function Initialize-ReplySendInterval {
    if(-not $script:RpaRunLock){throw '未持有共享桌面锁，拒绝更改提交冷却。'}
    $path=Join-Path $script:ReplySharedSubmissionRoot 'last-submit.json'
    if(Test-Path -LiteralPath $path){
        $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if($record.Status -eq 'Pending'){
            Write-RpaStateJson ([ordered]@{Time=(Get-ReplyIntervalTime).ToString('o');VideoId=$record.VideoId;CandidateId=$record.CandidateId;Status='RecoveryCooldown'}) $path
        }
        return
    }
    $startPath=Join-Path $script:ReplySharedSubmissionRoot 'send-interval-start.json'
    if(-not (Test-Path -LiteralPath $startPath)){Write-RpaStateJson ([ordered]@{Time=(Get-ReplyIntervalTime).ToString('o');Status='InitialCooldown'}) $startPath}
}
function Get-ReplyCooldownSeconds {
    Initialize-ReplySendInterval
    $path=Join-Path $script:ReplySharedSubmissionRoot 'last-submit.json'
    if(-not (Test-Path -LiteralPath $path)){$path=Join-Path $script:ReplySharedSubmissionRoot 'send-interval-start.json'}
    $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $interval=10
    if($Config -and $Config.Timing.CommentIntervalSeconds){$interval=[int]$Config.Timing.CommentIntervalSeconds}
    if($interval -lt 10){throw '真实提交间隔不能低于 10 秒。'}
    $next=[DateTimeOffset]::Parse($record.Time).AddSeconds($interval)
    if($script:RunReport){$script:RunReport['NextSubmissionAt']=$next.ToString('o')}
    return [Math]::Max(0,($next-(Get-ReplyIntervalTime)).TotalSeconds)
}
function Set-ReplyLastSubmission([string]$CandidateId,[string]$Status='Submitted',[string]$VideoId='') {
    if(-not $script:RpaRunLock){throw '未持有共享桌面锁，拒绝更改提交冷却。'}
    $null=Get-ReplyLedgerPath $CandidateId
    if($Status -notin @('Pending','Submitted','RecoveryCooldown')){throw '共享冷却状态无效。'}
    $now=Get-ReplyIntervalTime
    Write-RpaStateJson ([ordered]@{Time=$now.ToString('o');VideoId=$VideoId;CandidateId=$CandidateId;Skill='douyin-reply-rpa';Status=$Status}) (Join-Path $script:ReplySharedSubmissionRoot 'last-submit.json')
    if($script:RunReport){$interval=10;if($Config -and $Config.Timing.CommentIntervalSeconds){$interval=[Math]::Max(10,[int]$Config.Timing.CommentIntervalSeconds)};$script:RunReport['NextSubmissionAt']=$now.AddSeconds($interval).ToString('o')}
}
function Update-RpaHeartbeat {
    if(-not $script:RunReport -or -not $script:RunDirectory){return}
    $now=[DateTimeOffset]::Now
    if($script:RunReport.HeartbeatAt -and ($now-[DateTimeOffset]::Parse($script:RunReport.HeartbeatAt)).TotalSeconds -lt 2){return}
    $script:RunReport['HeartbeatAt']=$now.ToString('o')
    Write-RpaStateJson $script:RunReport (Join-Path $script:RunDirectory 'result.json')
}
function Set-RpaProgress([string]$Stage) {
    if(-not $script:RunReport -or -not $script:RunDirectory){return}
    $script:RunReport['Stage']=$Stage;$script:RunReport['UpdatedAt']=Get-Date -Format o;$script:RunReport['HeartbeatAt']=Get-Date -Format o
    Write-RpaStateJson $script:RunReport (Join-Path $script:RunDirectory 'result.json')
}
function Assert-RpaRunning {
    if(Test-Path -LiteralPath (Join-Path $script:RpaControlRoot 'stop')){throw [OperationCanceledException]::new('已收到停止指令。')}
    if(('DingRpa' -as [type]) -and ([DingRpa]::GetAsyncKeyState(0x1b) -band 0x8000) -ne 0){throw [OperationCanceledException]::new('检测到 Escape，已停止。')}
    Update-RpaHeartbeat
}
function Wait-RpaDelay([double]$Seconds) {
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        Assert-RpaRunning
        while(Test-Path -LiteralPath (Join-Path $script:RpaControlRoot 'pause')){
            Assert-RpaRunning
            if($script:RunReport -and -not $script:RunReport.Paused){$script:RunReport['Paused']=$true;Set-RpaProgress $script:RunReport.Stage}
            Start-Sleep -Milliseconds 200
        }
        if($script:RunReport -and $script:RunReport.Paused){$script:RunReport['Paused']=$false;Set-RpaProgress $script:RunReport.Stage}
        if([DateTime]::UtcNow -ge $until){break}
        Start-Sleep -Milliseconds 150
    }while($true)
}
