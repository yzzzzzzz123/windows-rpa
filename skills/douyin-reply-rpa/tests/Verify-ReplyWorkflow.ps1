[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$skillRoot=Split-Path $PSScriptRoot -Parent
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $skillRoot '..\..'))
$workspace=Join-Path $repositoryRoot 'artifacts\work'
$testRoot=Join-Path $workspace ('reply-workflow-test-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot -Force
. (Join-Path $skillRoot 'src\workflows\Reply.Workflow.ps1')
$script:Checks=0
$candidate=[pscustomobject]@{CandidateId=('a'*64);AuthorKey=('b'*64);VideoId='7000000000000000001';CommentId='7000000000000000002';VideoUrl='https://www.douyin.com/video/7000000000000000001';VideoTitle='AI 视频';AuthorName='候选用户';AuthorUrl='https://www.douyin.com/user/fixture';Text='AI 视频怎么剪辑？';ReplyText='你说的 AI 剪辑流程，可以了解一下 Sparnow。';Reason='询问 AI 剪辑方法。'}
function Add-Trace([string]$Value){$script:Trace.Add($Value)}
function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
function Assert-Rejected([scriptblock]$Body,[string]$Message){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert-True $rejected $Message}
function Count-Trace([string]$Value){return @($script:Trace|Where-Object {$_ -ceq $Value}).Count}
function Reset-Case([string]$Mode='Publish'){
    $script:Trace=New-Object 'Collections.Generic.List[string]'
    $script:AlreadyContacted=$false;$script:FailClick=$false;$script:FailReadyAt=0;$script:ReadyCalls=0;$script:FailWait=$false;$script:CooldownReads=0;$script:PendingCandidateId=$null;$script:PauseAtReady=0;$script:PostSendChallenge=$false;$script:FailHumanGate=$false
    $script:Config=[pscustomobject]@{Mode=$Mode;Replies=@($candidate)}
    $script:RunDirectory=$testRoot
    $script:RpaControlRoot=Join-Path $testRoot 'control'
    $null=New-Item -ItemType Directory -Path $script:RpaControlRoot -Force
    $pause=Join-Path $script:RpaControlRoot 'pause';if(Test-Path -LiteralPath $pause){Remove-Item -LiteralPath $pause -Force}
    $script:RunReport=[ordered]@{Submitted=0;Previewed=0;Skipped=0;Processed=0;Stage='Fixture';Paused=$false}
}
function Wait-RpaDelay([double]$Seconds){Add-Trace ('Delay:'+ $Seconds);if($script:FailWait){throw [OperationCanceledException]::new('模拟等待中停止。')};$pause=Join-Path $script:RpaControlRoot 'pause';if(Test-Path -LiteralPath $pause){Add-Trace 'Resume';Remove-Item -LiteralPath $pause -Force}}
function Get-ReplyCooldownSeconds {$script:CooldownReads++;Add-Trace 'Cooldown';if($script:CooldownReads -eq 1){return 2};return 0}
function Get-DouyinChallenge {Add-Trace 'Challenge';if($script:PostSendChallenge -and (Count-Trace 'Click') -gt 0){return '模拟发送后安全验证'};return $null}
function Wait-DouyinHumanGate([string]$Reason){Add-Trace 'HumanGate';if(-not $script:PostSendChallenge){throw '夹具不应进入人工验证码流程。'};if($script:FailHumanGate){throw [OperationCanceledException]::new('模拟验证码等待中停止。')}}
function Assert-ReplyReadyToSubmit($Candidate){$script:ReadyCalls++;Add-Trace 'Ready';if($script:ReadyCalls -eq $script:PauseAtReady){[IO.File]::WriteAllText((Join-Path $script:RpaControlRoot 'pause'),'fixture')};if($script:ReadyCalls -eq $script:FailReadyAt){throw '模拟回复对象或草稿核验失败。'};return 'sender'}
function New-ReplySubmissionClaim($Candidate,[string]$ReplyText){Add-Trace 'Claim';return [pscustomobject]@{Status='Submitting'}}
function Invoke-DouyinClick($Element){Add-Trace 'Click';if($script:FailClick){throw '模拟点击结果未知。'}}
function Set-ReplyLastSubmission([string]$CandidateId,[string]$Status,[string]$VideoId){Add-Trace ('LastSubmission:'+ $Status)}
function Set-ReplySubmissionStatus([string]$CandidateId,[string]$Status,[string]$Reason){Add-Trace ('Ledger:'+ $Status)}
function Set-RpaProgress([string]$Stage){Add-Trace ('Stage:'+ $Stage);$script:RunReport.Stage=$Stage}
function Test-ReplyAlreadyContacted($Candidate){Add-Trace 'Dedup';return $script:AlreadyContacted}
function Open-ReplyTarget($Candidate){Add-Trace 'OpenTarget';return 'card'}
function Save-DouyinEvidence([string]$Stage){Add-Trace ('Evidence:'+ $Stage)}
function Write-RpaStateJson($Value,[string]$Path){Add-Trace 'WriteEvidence'}
function Write-ReplyDraft($Candidate,$Card){Add-Trace 'WriteDraft'}
function Open-DouyinUrl([string]$Url){throw '提交流程不应刷新或导航去检查发布可见性。'}
function Get-DouyinNodes($Root){throw '提交流程不应读取页面来查验发布可见性。'}
function Complete-DouyinSubmission($Video){throw '回复流程不应调用顶层评论的发布可见性核验。'}
try{
    # 活动持续目标优先未查看视频；独立任务和其他 JobId 不继承历史。
    $script:RpaStateRoot=Join-Path $testRoot 'priority-state'
    $null=New-Item -ItemType Directory -Path $script:RpaStateRoot -Force
    $script:RunReport=[ordered]@{JobId='fixture-discover'}
    $goalPath=Join-Path $script:RpaStateRoot 'persistent-goal.json'
    $goal=[ordered]@{Status='Active';CurrentJobId='fixture-discover';VisitedVideoIds=@('7000000000000000003','invalid-id')}
    [IO.File]::WriteAllText($goalPath,($goal|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $videos=@(
        [pscustomobject]@{VideoId='7000000000000000003';Title='已查看的新视频'},
        [pscustomobject]@{VideoId='7000000000000000001';Title='未查看的旧视频'},
        [pscustomobject]@{VideoId='7000000000000000002';Title='未查看的新视频'}
    )
    $history=Get-ReplyDiscoveryVisitHistory
    Assert-True ($history.Count -eq 1 -and $history.ContainsKey('7000000000000000003')) '活动目标历史未绑定当前任务或未过滤无效视频编号。'
    $ordered=@(Sort-ReplyDiscoveryVideos $videos $history)
    Assert-True (($ordered.VideoId -join ',') -ceq '7000000000000000002,7000000000000000001,7000000000000000003') '已查看视频仍抢在未查看视频之前，或新视频内部未保留时间顺序。'
    $ordered=@(Sort-ReplyDiscoveryVideos $videos @{})
    Assert-True (($ordered.VideoId -join ',') -ceq '7000000000000000003,7000000000000000002,7000000000000000001') '无历史的普通发现改变了原有时间顺序。'
    $ordered=@(Sort-ReplyDiscoveryVideos $videos @{'7000000000000000001'=$true;'7000000000000000002'=$true;'7000000000000000003'=$true})
    Assert-True ($ordered.Count -eq 3 -and $ordered[0].VideoId -ceq '7000000000000000003') '全部已查看时丢弃了视频，无法继续发现新评论。'
    $goal.Status='Paused'
    [IO.File]::WriteAllText($goalPath,($goal|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    Assert-True ((Get-ReplyDiscoveryVisitHistory).Count -eq 0) '非活动目标的历史影响了当前发现。'
    $goal.Status='Active';$goal.CurrentJobId='different-job'
    [IO.File]::WriteAllText($goalPath,($goal|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    Assert-True ((Get-ReplyDiscoveryVisitHistory).Count -eq 0) '其他JobId的持续目标历史泄漏到当前任务。'
    [IO.File]::WriteAllText($goalPath,'{invalid-json',(New-Object Text.UTF8Encoding($false)))
    Assert-True ((Get-ReplyDiscoveryVisitHistory).Count -eq 0 -and [IO.File]::ReadAllText($goalPath) -ceq '{invalid-json') '损坏历史未安全回退，或读取时改写了历史。'
    $script:RpaStateRoot=Join-Path $testRoot 'another-state'
    Assert-True ((Get-ReplyDiscoveryVisitHistory).Count -eq 0) '其他DataRoot的历史影响了当前任务。'

    Reset-Case 'Preview'
    Invoke-ReplyBatch
    Assert-True ($script:RunReport.Previewed -eq 1 -and $script:RunReport.Processed -eq 1) 'Preview 未完成目标核验计数。'
    Assert-True ((Count-Trace 'OpenTarget') -eq 1 -and (Count-Trace 'Evidence:target-verified') -eq 1) 'Preview 未定位原评论并保留证据。'
    Assert-True ((Count-Trace 'WriteDraft') -eq 0 -and (Count-Trace 'Claim') -eq 0 -and (Count-Trace 'Click') -eq 0 -and (Count-Trace 'Cooldown') -eq 0 -and $script:RunReport.Submitted -eq 0) 'Preview 存在输入或提交副作用。'

    Reset-Case
    $script:AlreadyContacted=$true
    Invoke-ReplyBatch
    Assert-True ($script:RunReport.Skipped -eq 1 -and (Count-Trace 'OpenTarget') -eq 0 -and (Count-Trace 'WriteDraft') -eq 0 -and (Count-Trace 'Claim') -eq 0 -and (Count-Trace 'Click') -eq 0) '已联系用户未在桌面操作前跳过。'

    Reset-Case
    Invoke-ReplyBatch
    Assert-True ($script:RunReport.Submitted -eq 1 -and $script:RunReport.Processed -eq 1 -and (Count-Trace 'Click') -eq 1) '正常回复必须只执行一次发送点击。'
    $events=$script:Trace.ToArray()
    $waitIndex=[Array]::IndexOf($events,'Cooldown');$claimIndex=[Array]::IndexOf($events,'Claim');$clickIndex=[Array]::IndexOf($events,'Click')
    Assert-True ($waitIndex -ge 0 -and $waitIndex -lt $claimIndex -and $claimIndex -lt $clickIndex) '冷却、预提交标记和点击顺序错误。'
    Assert-True ((Count-Trace 'Ready') -eq 2 -and (Count-Trace 'Ledger:Submitted') -eq 1 -and (Count-Trace 'Ledger:Unknown') -eq 0 -and (Count-Trace 'LastSubmission:Submitted') -eq 1 -and -not $script:PendingCandidateId) '提交前后双重核验或账本状态错误。'
    $afterClick=@($events[($clickIndex+1)..($events.Length-1)])
    Assert-True (@($afterClick|Where-Object {$_ -in @('OpenTarget','WriteDraft','Ready','Evidence:target-verified','Evidence:draft-verified')}).Count -eq 0) '发送后不应刷新、重新输入或回读发布可见性。'

    Reset-Case
    $script:FailClick=$true
    Assert-Rejected {Submit-ReplyDraft $candidate} '点击异常未传递给任务。'
    Assert-True ((Count-Trace 'Click') -eq 1 -and (Count-Trace 'Claim') -eq 1 -and (Count-Trace 'Ledger:Unknown') -eq 1 -and (Count-Trace 'Ledger:Submitted') -eq 0 -and $script:RunReport.Submitted -eq 0 -and -not $script:PendingCandidateId) '点击结果不明时未保留 Unknown 或发生重试。'

    Reset-Case
    $script:FailReadyAt=1
    Assert-Rejected {Submit-ReplyDraft $candidate} '首次提交核验失败被忽略。'
    Assert-True ((Count-Trace 'Claim') -eq 0 -and (Count-Trace 'Click') -eq 0 -and (Count-Trace 'Ledger:Unknown') -eq 0) '首次核验失败后仍创建发送声明或点击。'

    Reset-Case
    $script:FailReadyAt=2
    Assert-Rejected {Submit-ReplyDraft $candidate} '预提交后核验失败被忽略。'
    Assert-True ((Count-Trace 'Claim') -eq 1 -and (Count-Trace 'Click') -eq 0 -and (Count-Trace 'Ledger:Unknown') -eq 1 -and $script:RunReport.Submitted -eq 0 -and -not $script:PendingCandidateId) '预提交后二次核验失败未保留 Unknown。'

    Reset-Case
    $script:FailWait=$true
    Assert-Rejected {Submit-ReplyDraft $candidate} '冷却中停止被忽略。'
    Assert-True ((Count-Trace 'Claim') -eq 0 -and (Count-Trace 'Click') -eq 0) '等待中停止后仍提交。'

    Reset-Case
    $script:PauseAtReady=1
    Submit-ReplyDraft $candidate
    $events=$script:Trace.ToArray()
    Assert-True ((Count-Trace 'Resume') -eq 1 -and (Count-Trace 'Ready') -eq 3 -and [Array]::IndexOf($events,'Resume') -lt [Array]::IndexOf($events,'Claim') -and (Count-Trace 'Click') -eq 1) '预提交前暂停没有等待恢复后重新核验目标。'

    Reset-Case
    $script:PauseAtReady=2
    Assert-Rejected {Submit-ReplyDraft $candidate} '预提交后核验期间暂停被忽略。'
    Assert-True ((Count-Trace 'Claim') -eq 1 -and (Count-Trace 'Click') -eq 0 -and (Count-Trace 'Ledger:Unknown') -eq 1 -and -not $script:PendingCandidateId) '预提交后收到暂停仍点击或未保存 Unknown。'

    Reset-Case
    $script:PostSendChallenge=$true
    Submit-ReplyDraft $candidate
    Assert-True ((Count-Trace 'HumanGate') -eq 1 -and (Count-Trace 'Click') -eq 1 -and (Count-Trace 'Ledger:Submitted') -eq 1 -and (Count-Trace 'Ledger:Unknown') -eq 0 -and $script:RunReport.Submitted -eq 1) '发送后验证码没有等待人工处理或错误覆盖已提交状态。'

    Reset-Case
    $script:PostSendChallenge=$true;$script:FailHumanGate=$true
    Assert-Rejected {Submit-ReplyDraft $candidate} '验证码等待异常未传递给任务。'
    Assert-True ((Count-Trace 'HumanGate') -eq 1 -and (Count-Trace 'Click') -eq 1 -and (Count-Trace 'Ledger:Submitted') -eq 1 -and (Count-Trace 'Ledger:Unknown') -eq 0 -and $script:RunReport.Submitted -eq 1 -and -not $script:PendingCandidateId) '验证码等待中停止错误地把已提交降为 Unknown 或再次点击。'

    [pscustomobject]@{Status='Passed';Checks=$script:Checks;NewVideoPriority=$true;RevisitedFallback=$true;JobBoundHistory=$true;PreviewNoInput=$true;ContactedSkipped=$true;CooldownBeforeClaimBeforeClick=$true;SingleClick=$true;UnknownNoRetry=$true;ReadyFailureStops=$true;PauseDuringReady=$true;PostSendChallengePreservesSubmitted=$true;NoPostSendVisibilityCheck=$true;DesktopActions=0;Submitted=0}
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=[IO.Path]::GetFullPath($workspace)+'\'
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notmatch '^reply-workflow-test-[a-f0-9]{32}$'){throw '拒绝清理未知工作流测试目录。'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
