[CmdletBinding()]
param([switch]$InteractiveSmoke)
$ErrorActionPreference='Stop'
$skillRoot=Split-Path $PSScriptRoot -Parent
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $skillRoot '..\..'))
$workspace=Join-Path $repositoryRoot 'artifacts\work'
$testRoot=Join-Path $workspace ('reply-core-test-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot -Force
. (Join-Path $skillRoot 'scripts\Reply.Core.ps1')
. (Join-Path $skillRoot 'src\core\Reply.State.ps1')
$script:Checks=0;$fixtureId=$null;$fixtureEntry=$null;$fixtureData=$null
function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
function Assert-Rejected([scriptblock]$Body,[string]$Message){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert-True $rejected $Message}
function Copy-Json($Value){return ($Value|ConvertTo-Json -Depth 20|ConvertFrom-Json)}
function New-Candidate([string]$CommentId,[string]$Author){
    $video='7000000000000000001';$url='https://www.douyin.com/user/'+$Author
    return [pscustomobject]@{CandidateId=(Get-ReplyIdentityHash ($video+'|'+$CommentId));CommentId=$CommentId;VideoId=$video;VideoUrl=('https://www.douyin.com/video/'+$video);VideoTitle='AI 视频制作流程';AuthorKey=(Get-ReplyIdentityHash $url);AuthorName=$Author;AuthorUrl=$url;Text="这个视频如何分镜？`n想学这种做法。🤔";LocatorClass='fixture-comment'}
}
function Call-Fixture([string]$Action,[string]$Id,[string]$TaskPath){
    $parameters=@{Action=$Action;DataRoot=$fixtureData}
    if($Id){$parameters.JobId=$Id};if($TaskPath){$parameters.TaskFile=$TaskPath};if($Action -eq 'Start'){$parameters.LaunchMode=$(if($InteractiveSmoke){'Interactive'}else{'Local'})}
    $output=& $fixtureEntry @parameters
    return ($output|ConvertFrom-Json)
}
function Wait-Fixture([string]$Id,[scriptblock]$Predicate){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do{$status=Call-Fixture 'Status' $Id;if(& $Predicate $status){return $status};Start-Sleep -Milliseconds 150}while($timer.Elapsed.TotalSeconds -lt 15)
    throw ('离线任务等待超时：'+($status|ConvertTo-Json -Compress -Depth 8))
}
try{
    $data=Join-Path $testRoot 'data'
    $environment=[pscustomobject]@{RuntimeRoot=$skillRoot;DataRoot=$data;StateRoot=(Join-Path $data 'state');JobsRoot=(Join-Path $data 'jobs');SharedSubmissionRoot=(Join-Path $testRoot 'shared-state')}
    $sourceId='20261013_120000000-0123456789ab'
    $sourceDirectory=Get-ReplyJobPath $environment $sourceId
    $sourceEvidence=Join-Path $sourceDirectory 'evidence'
    $null=New-Item -ItemType Directory -Path $sourceEvidence -Force
    Write-ReplyJson ([ordered]@{JobId=$sourceId;DataRoot=$data;StateRoot=$environment.StateRoot;Mode='Discover';ProcessId=$null;ProcessStartTicks=$null}) (Join-Path $sourceDirectory 'job.json')
    $first=New-Candidate '7000000000000000101' 'userA'
    $sameAuthor=New-Candidate '7000000000000000102' 'userA'
    $otherAuthor=New-Candidate '7000000000000000103' 'userB'
    $candidatePath=Join-Path $sourceEvidence 'candidates.json'
    Write-ReplyJson @($first,$sameAuthor,$otherAuthor) $candidatePath
    $configPath=Join-Path $testRoot 'normalized.json'
    $discover=New-ReplyConfiguration ([pscustomobject]@{Mode='Discover'}) $environment $configPath
    Assert-True ($discover.Browser.UserDataDirectory -ceq (Join-Path $data 'browser-profile')) '回复任务没有绑定独立 profile。'
    Assert-True ($discover.MaxVideos -eq 1 -and $discover.MaxCommentsPerVideo -eq 30 -and $discover.MaxScrollRounds -eq 3) '发现任务默认单视频边界错误。'
    Assert-True ($discover.Timing.CommentIntervalSeconds -eq 10) '定向回复默认间隔不是 10 秒。'
    foreach($interval in @(9,0,$true,10.5)){
        $invalidInterval=Copy-Json $discover;$invalidInterval.Timing.CommentIntervalSeconds=$interval
        Assert-Rejected {Assert-ReplyConfiguration $invalidInterval} '低于 10 秒或非整数的发送间隔未被拒绝。'
    }
    $valid=[pscustomobject]@{Mode='Publish';SourceJobId=$sourceId;Replies=@([pscustomobject]@{CandidateId=$first.CandidateId;ReplyText='你问的分镜流程，可以了解一下 Sparnow。';Reason='原评论明确询问 AI 视频分镜制作方式。'})}
    $normalized=New-ReplyConfiguration $valid $environment $configPath
    Assert-True ($normalized.Replies.Count -eq 1 -and $normalized.Replies[0].Text -ceq $first.Text -and $normalized.Replies[0].AuthorUrl -ceq $first.AuthorUrl -and $normalized.Replies[0].CommentId -ceq $first.CommentId -and $normalized.Replies[0].LocatorClass -ceq 'fixture-comment') '候选原评论、用户身份或定位字段未保真。'
    Assert-True ((Read-ReplyConfiguration $configPath).Replies[0].ReplyText -ceq $valid.Replies[0].ReplyText) '中文配置回读不一致。'
    $invalid=@(
        [pscustomobject]@{Mode='Discover';MaxVideos=0},[pscustomobject]@{Mode='Discover';MaxVideos=$true},
        [pscustomobject]@{Mode='Discover';MaxVideos=1.5},[pscustomobject]@{Mode='Discover';MaxCommentsPerVideo=101},
        [pscustomobject]@{Mode='Discover';MaxScrollRounds=11},[pscustomobject]@{Mode='Discover';MatchAny='剪辑'},
        [pscustomobject]@{Mode='Discover';SearchTerms=@("输入`n多行")},[pscustomobject]@{Mode='Discover';UnsafeOverride=$true},
        [pscustomobject]@{Mode='Publish'},[pscustomobject]@{Mode='Publish';SourceJobId='..\elsewhere';Replies=$valid.Replies},
        [pscustomobject]@{Mode='Publish';SourceJobId=$sourceId;SourcePath='c:\elsewhere.json';Replies=$valid.Replies}
    )
    foreach($task in $invalid){Assert-Rejected {New-ReplyConfiguration $task $environment $configPath} '无效任务字段或限额未拒绝。'}
    foreach($value in @('无品牌回复',"Sparnow`n不允许换行",('Sparnow'+('长'*301)))){$task=Copy-Json $valid;$task.Replies[0].ReplyText=$value;Assert-Rejected {New-ReplyConfiguration $task $environment $configPath} '无效回复文案未拒绝。'}
    $task=Copy-Json $valid;$task.Replies[0].Reason='';Assert-Rejected {New-ReplyConfiguration $task $environment $configPath} '空选择理由未拒绝。'
    $task=Copy-Json $valid;$task.Replies[0]|Add-Member NoteProperty AuthorName '伪造用户';Assert-Rejected {New-ReplyConfiguration $task $environment $configPath} '任务覆盖候选用户未拒绝。'
    $task=Copy-Json $valid;$task.Replies+=Copy-Json $valid.Replies[0];Assert-Rejected {New-ReplyConfiguration $task $environment $configPath} '同评论重复回复未拒绝。'
    $task=Copy-Json $valid;$duplicate=Copy-Json $valid.Replies[0];$duplicate.CandidateId=$sameAuthor.CandidateId;$task.Replies+=$duplicate;Assert-Rejected {New-ReplyConfiguration $task $environment $configPath} '同用户跨评论重复回复未拒绝。'
    $tampered=Copy-Json $first;$tampered.CommentId='7000000000000000999';Write-ReplyJson @($tampered) $candidatePath
    Assert-Rejected {New-ReplyConfiguration $valid $environment $configPath} '来源评论哈希不匹配未拒绝。'
    $tampered=Copy-Json $first;$tampered.AuthorUrl+='/';$tampered.AuthorKey=Get-ReplyIdentityHash $tampered.AuthorUrl;Write-ReplyJson @($tampered) $candidatePath
    Assert-Rejected {New-ReplyConfiguration $valid $environment $configPath} '作者主页尾斜杠能绕过用户身份规范。'
    Write-ReplyJson @($first,$first) $candidatePath
    Assert-Rejected {New-ReplyConfiguration $valid $environment $configPath} '来源重复 CandidateId 未拒绝。'
    Write-ReplyJson @() $candidatePath
    Assert-True (@(Read-ReplySourceCandidates $environment $sourceId).Count -eq 0) '空候选来源不能正确读取。'
    $emptyCandidates=Get-ReplyCandidates $environment $sourceId
    Assert-True ($emptyCandidates.Candidates -is [array] -and $emptyCandidates.Candidates.Count -eq 0) 'Candidates 接口空结果未保持数组，影响持续派发。'
    Write-ReplyJson @($first,$sameAuthor,$otherAuthor) $candidatePath
    Assert-Rejected {Get-ReplyJobPath $environment '..\outside'} '任务路径遍历未拒绝。'

    Initialize-ReplyState $environment.StateRoot $environment.SharedSubmissionRoot
    $lockPath=Join-Path $environment.SharedSubmissionRoot 'runner.lock'
    Assert-Rejected {$probe=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$probe.Dispose()} '共享桌面锁允许并发运行。'
    $Config=[pscustomobject]@{Timing=[pscustomobject]@{CommentIntervalSeconds=10}}
    $script:RunReport=[ordered]@{Stage='OfflineIntervalFixture'}
    $script:FakeNow=[DateTimeOffset]::UtcNow
    function Get-ReplyIntervalTime {return $script:FakeNow}
    Assert-True ((Get-ReplyCooldownSeconds) -eq 10) '无历史首发冷却不是 10 秒。'
    $script:FakeNow=$script:FakeNow.AddSeconds(4)
    Assert-True ((Get-ReplyCooldownSeconds) -eq 6) '首发没有按已流逝时间等待剩余间隔。'
    $script:FakeNow=$script:FakeNow.AddSeconds(7)
    Assert-True ((Get-ReplyCooldownSeconds) -eq 0) '过期首发冷却未解除。'
    $claim=New-ReplySubmissionClaim $first $valid.Replies[0].ReplyText
    Assert-True ((Test-ReplyAlreadyContacted $first) -and (Test-ReplyAlreadyContacted $sameAuthor) -and -not (Test-ReplyAlreadyContacted $otherAuthor)) '评论和用户双维去重错误。'
    Assert-True ((Read-ReplyJson (Join-Path $environment.SharedSubmissionRoot 'last-submit.json')).Status -eq 'Pending') '发送前未持久化共享未知提交标记。'
    Assert-Rejected {New-ReplySubmissionClaim $first $valid.Replies[0].ReplyText} '重复评论提交未拒绝。'
    Assert-Rejected {New-ReplySubmissionClaim $sameAuthor $valid.Replies[0].ReplyText} '相同用户新评论提交未拒绝。'
    Set-ReplySubmissionStatus $first.CandidateId 'Unknown' '模拟发送动作后进程中断。'
    $ledger=Read-ReplyJson (Get-ReplyLedgerPath $first.CandidateId)
    $userLedger=Read-ReplyJson (Get-ReplyUserLedgerPath $first.AuthorKey)
    Assert-True ($ledger.Status -eq 'Unknown' -and -not $ledger.AutomaticRetryAllowed -and $userLedger.Status -eq 'Unknown') '未知提交结果未保留双账禁止重试。'
    Assert-Rejected {New-ReplySubmissionClaim $first $valid.Replies[0].ReplyText} '未知提交被允许重试。'
    Assert-True ((Get-ReplyCooldownSeconds) -eq 10) '未知 Pending 恢复未按 10 秒冷却。'
    $script:FakeNow=$script:FakeNow.AddSeconds(4)
    Assert-True ((Get-ReplyCooldownSeconds) -eq 6) 'Pending 恢复后的冷却被反复重置。'
    $script:FakeNow=$script:FakeNow.AddSeconds(20)
    Set-ReplyLastSubmission $first.CandidateId 'Submitted' $first.VideoId
    Assert-True (([DateTimeOffset]::Parse($script:RunReport.NextSubmissionAt)) -eq $script:FakeNow.AddSeconds(10)) '提交后返回的截止时间仍被截断为 60 秒。'
    Assert-True ((Get-ReplyCooldownSeconds) -eq 10) '点击后冷却未从实际提交时刻按 10 秒计算。'
    $Config.Timing.CommentIntervalSeconds=60
    Assert-True ((Get-ReplyCooldownSeconds) -eq 60) '明确设置的较长发送间隔未被保留。'
    $script:FakeNow=$script:FakeNow.AddSeconds(61)
    Assert-True ((Get-ReplyCooldownSeconds) -eq 0) '跨 Skill 共享提交冷却未正确结束。'
    $Config.Timing.CommentIntervalSeconds=9
    Assert-Rejected {Get-ReplyCooldownSeconds} '运行时允许低于 10 秒的真实提交间隔。'
    $Config.Timing.CommentIntervalSeconds=10
    # 模拟只写完评论账就中断，残留也必须保持禁止重试。
    $partial=New-Candidate '7000000000000000104' 'userC'
    New-ReplyExclusiveRecord ([ordered]@{Status='Submitting'}) (Get-ReplyLedgerPath $partial.CandidateId)
    Assert-Rejected {New-ReplySubmissionClaim $partial $valid.Replies[0].ReplyText} '部分落账被误当作可重试。'
    Close-ReplyState

    # 复制到临时自包含目录；唯一 worker 为无桌面等待夹具。
    $fixture=Join-Path $testRoot '中文 skill''s & $ 目录'
    foreach($sub in @('scripts','src\core','src\native','config')){$null=New-Item -ItemType Directory -Path (Join-Path $fixture $sub) -Force}
    foreach($file in @('scripts\Reply.Core.ps1','scripts\Invoke-DouyinReplySkill.ps1','scripts\Invoke-DouyinReplySession.ps1','src\core\Reply.Session.ps1','src\core\Reply.Browser.ps1','src\native\ReplySession.cs','src\core\Reply.Configuration.ps1','src\core\Reply.State.ps1','config\reply.json')){Copy-Item -LiteralPath (Join-Path $skillRoot $file) -Destination (Join-Path $fixture $file)}
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'shared') -Destination (Join-Path $fixture 'shared') -Recurse
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Destination (Join-Path $fixture 'VERSION')
    Write-ReplyJson ([ordered]@{Name='douyin-reply-rpa'}) (Join-Path $fixture 'bundle.json')
    $fixtureWorker=@'
[CmdletBinding()]
param([string]$JobFile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Reply.Core.ps1')
. (Join-Path $PSScriptRoot '..\src\core\Reply.State.ps1')
$job=Read-ReplyJson $JobFile
$script:RunDirectory=$job.EvidenceRoot
$script:RunReport=[ordered]@{Status='Running';Stage='OfflineFixture';Paused=$false;Submitted=0;Reason=$null}
try{
    Initialize-ReplyState $job.StateRoot $job.SharedSubmissionRoot
    Set-RpaProgress 'OfflineFixture'
    Wait-RpaDelay 40
    $script:RunReport.Status='Completed'
}catch [OperationCanceledException]{$script:RunReport.Status='Stopped'}catch{$script:RunReport.Status='Failed';$script:RunReport.Reason=$_.Exception.Message}finally{$script:RunReport.Paused=$false;Set-RpaProgress 'Finished';Close-ReplyState}
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'scripts\Invoke-DouyinReplyWorker.ps1'),$fixtureWorker,(New-Object Text.UTF8Encoding($true)))
    $fixtureEntry=Join-Path $fixture 'scripts\Invoke-DouyinReplySkill.ps1'
    $fixtureData=Join-Path $testRoot 'fixture-data'
    $taskPath=Join-Path $testRoot 'discover-task.json'
    Write-ReplyJson ([pscustomobject]@{Mode='Discover';SearchTerms=@('中文视频分镜')}) $taskPath
    $described=Call-Fixture 'Describe'
    Assert-True ($described.Ok -and $described.Paths.SharedSubmissionRoot -eq (Join-Path $fixtureData 'state')) '独立包共享状态路径不正确。'
    $started=Call-Fixture 'Start' '' $taskPath
    Assert-True ($started.Ok -and $started.JobId) ('离线任务启动失败：'+$started.Error)
    $fixtureId=$started.JobId
    if($InteractiveSmoke){
        $receipts=@(Get-ChildItem -LiteralPath (Join-Path $fixtureData 'launches') -Filter receipt.json -Recurse -File)
        Assert-True ($receipts.Count -eq 1 -and (Read-ReplyJson $receipts[0].FullName).SessionId -gt 0) '无桌面夹具没有在交互用户会话中启动。'
        $launch=Split-Path (Split-Path $receipts[0].FullName -Parent) -Leaf
        $service=New-Object -ComObject Schedule.Service;$service.Connect()
        $missing=$false;try{$null=$service.GetFolder('\').GetTask('Codex-DouyinReply-'+$launch)}catch{$missing=$true}
        Assert-True $missing '单次启动桥接任务未清理。'
    }
    $null=Wait-Fixture $fixtureId {param($s)$s.Status -eq 'Running'}
    $duplicate=Call-Fixture 'Start' '' $taskPath
    Assert-True (-not $duplicate.Ok) '同目录重复任务未拒绝。'
    $snapshot=Read-ReplyJson (Join-Path $fixtureData ('jobs\'+$fixtureId+'\config.json'))
    Assert-True ($snapshot.SearchTerms[0] -ceq '中文视频分镜') '后台任务 UTF8 中文配置丢失。'
    $null=Call-Fixture 'Pause' $fixtureId
    $paused=Wait-Fixture $fixtureId {param($s)$s.Status -eq 'Paused' -and $s.Paused}
    Start-Sleep -Milliseconds 2300
    $heartbeat=Call-Fixture 'Status' $fixtureId
    Assert-True ($heartbeat.HeartbeatAt -gt $paused.HeartbeatAt -and $heartbeat.UpdatedAt -eq $paused.UpdatedAt) '暂停心跳未保持或错误变更进展时间。'
    $fixtureEnv=[pscustomobject]@{DataRoot=$fixtureData;StateRoot=(Join-Path $fixtureData 'state');JobsRoot=(Join-Path $fixtureData 'jobs')}
    $wrongActive=Read-ReplyJson (Join-Path $fixtureEnv.StateRoot 'skill-active.json');$wrongActive.JobId=$sourceId
    Assert-Rejected {Invoke-ReplyControl $fixtureEnv 'Stop' $fixtureId $wrongActive} '其他任务身份能控制当前任务。'
    $null=Call-Fixture 'Resume' $fixtureId
    $null=Wait-Fixture $fixtureId {param($s)-not $s.Paused -and -not $s.PauseRequested}
    # 在同一派发锁中模拟 Stop 后 Resume，保证旧 stop 标记绝不被清掉。
    $active=Read-ReplyJson (Join-Path $fixtureEnv.StateRoot 'skill-active.json')
    [IO.File]::WriteAllText((Join-Path $fixtureEnv.StateRoot 'control\stop'),'test')
    $resume=Call-Fixture 'Resume' $fixtureId
    Assert-True (-not $resume.Ok -and (Test-Path -LiteralPath (Join-Path $fixtureEnv.StateRoot 'control\stop'))) 'Resume 清除了 Stop 标记。'
    $stopped=Wait-Fixture $fixtureId {param($s)-not $s.Running}
    Assert-True ($stopped.Status -eq 'Stopped') '任务没有响应停止。'
    $retired=Call-Fixture 'Pause' $fixtureId
    Assert-True (-not $retired.Ok) '已结束任务允许控制。'
    $identity=Read-ReplyJson (Join-Path $fixtureData ('jobs\'+$fixtureId+'\job.json'));$identity.ProcessId=$PID;$identity.ProcessStartTicks='1'
    Assert-True (-not (Test-ReplyProcess $identity)) '复用 PID 被误认为原进程。'
    [pscustomobject]@{Status='Passed';Checks=$script:Checks;Configuration=$true;CanonicalSource=$true;DualDeduplication=$true;UnknownNoRetry=$true;SharedLockAndCooldown=$true;Controls=$true;Utf8=$true;InteractiveSmoke=[bool]$InteractiveSmoke;DesktopActions=0;Submitted=0}
}finally{
    Close-ReplyState
    if($fixtureId -and $fixtureEntry){$remaining=Call-Fixture 'Status' $fixtureId;if($remaining.Running){$null=Call-Fixture 'Stop' $fixtureId;$null=Wait-Fixture $fixtureId {param($s)-not $s.Running}}}
    $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=[IO.Path]::GetFullPath($workspace)+'\'
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notmatch '^reply-core-test-[a-f0-9]{32}$'){throw '拒绝清理未知测试目录。'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
