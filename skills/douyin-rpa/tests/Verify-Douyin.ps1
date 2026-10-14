[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$testWorkspace=Join-Path $repositoryRoot 'artifacts\work'
. (Join-Path $repositoryRoot 'shared\douyin\Urls.ps1')
. (Join-Path $projectRoot 'src\core\Douyin.Configuration.ps1')
. (Join-Path $projectRoot 'src\core\RpaState.ps1')
if(-not ('DingRpa' -as [type])){Add-Type -Path (Join-Path $repositoryRoot 'shared\native\DingRpa.cs')}
$testRoot=Join-Path $testWorkspace ('douyin-tests-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot -Force
$original=Get-Content -LiteralPath (Join-Path $projectRoot 'config\douyin.json') -Raw -Encoding UTF8
$null=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json')
$bad=@(
    ($original -replace '"CommentIntervalSeconds"\s*:\s*\d+','"CommentIntervalSeconds": 0'),
    ($original -replace '"CommentIntervalSeconds"\s*:\s*\d+','"CommentIntervalSeconds": 59'),
    ($original -replace '"MaxScrollRounds"\s*:\s*\d+','"MaxScrollRounds": 1.5'),
    ($original -replace '"ProcessName"\s*:\s*"chrome"','"ProcessName": "other"'),
    ($original -replace '"SearchTerms"\s*:\s*\[[^\]]*\]','"SearchTerms": []')
)
$rejected=0
foreach($json in $bad){$path=Join-Path $testRoot 'invalid.json'; [IO.File]::WriteAllText($path,$json,(New-Object Text.UTF8Encoding($false)));try{$null=Read-DouyinConfiguration $path}catch{$rejected++}}
if($rejected -ne $bad.Count){throw '无效抖音配置被接受。'}
$zeroWaitConfig=$original | ConvertFrom-Json
$zeroWaitConfig.Timing.CommentIntervalSeconds=60;$zeroWaitConfig.Timing.EmptyQueueWaitSeconds=0
$zeroWaitConfig.SearchTerms=@(1..25|ForEach-Object{'AI视频测试选题'+$_})
$validTimingPath=Join-Path $testRoot 'valid-unbounded-seeds.json'
Write-RpaStateJson $zeroWaitConfig $validTimingPath
$acceptedTiming=Read-DouyinConfiguration $validTimingPath
if($acceptedTiming.Timing.EmptyQueueWaitSeconds -ne 0 -or $acceptedTiming.SearchTerms.Count -ne 25){throw '零轮间或超过 20 个合法种子词被错误拒绝。'}
$zeroWaitConfig.MatchAny=@(1..21|ForEach-Object{'测试主题'+$_})
$tooManyThemesPath=Join-Path $testRoot 'invalid-themes.json';Write-RpaStateJson $zeroWaitConfig $tooManyThemesPath
$themesRejected=$false;try{$null=Read-DouyinConfiguration $tooManyThemesPath}catch{$themesRejected=$true}
if(-not $themesRejected){throw '主题过滤词数量上限意外被移除。'}
$urls=@('https://douyin.com.evil.example/video/1234567890123456789','https://www.douyin.com@evil.example/video/1234567890123456789','http://www.douyin.com/video/1234567890123456789','https://www.douyin.com:444/video/1234567890123456789')
$denied=0;foreach($url in $urls){try{$null=ConvertTo-DouyinUri $url}catch{$denied++}}
if($denied -ne $urls.Count){throw '非预期来源的 URL 被接受。'}
foreach($url in @('douyin.com/jingxuan?modal_id=1234567890123456789','https://www.douyin.com/video/1234567890123456789')){if((Get-DouyinVideoId $url) -ne '1234567890123456789'){throw '视频编号规范化失败。'}}
$jsonPath=Join-Path $testRoot 'state.json'
Write-RpaStateJson ([ordered]@{Text='中文原文';Items=@('一','二');Status='Initial'}) $jsonPath
Write-RpaStateJson ([ordered]@{Text='中文更新';Items=@('一','二');Status='Updated'}) $jsonPath
$read=Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
if($read.Text -cne '中文更新' -or $read.Status -ne 'Updated' -or $read.Items.Count -ne 2){throw '原子状态覆盖或中文回读失败。'}
$script:RpaStateRoot=Join-Path $testRoot 'state'
$null=New-Item -ItemType Directory -Path (Join-Path $script:RpaStateRoot 'videos') -Force
$video=[pscustomobject]@{VideoId='1234567890123456789';Url='https://www.douyin.com/video/1234567890123456789';Title='测试目标';Topic='测试选题'}
$null=New-RpaSubmissionClaim $video '测试评论'
$duplicateDenied=$false;try{$null=New-RpaSubmissionClaim $video '测试评论'}catch{$duplicateDenied=$true}
if(-not $duplicateDenied){throw '相同视频的重复提交记录没有被阻止。'}
$pending=Get-Content -LiteralPath (Get-RpaLedgerPath $video.VideoId) -Raw -Encoding UTF8 | ConvertFrom-Json
if($pending.Status -ne 'Submitting' -or $pending.AutomaticRetryAllowed -ne $false){throw '中断后的不确定提交记录丢失。'}
Set-RpaSubmissionStatus $video.VideoId 'Published' '测试核验'
$published=Get-Content -LiteralPath (Get-RpaLedgerPath $video.VideoId) -Raw -Encoding UTF8 | ConvertFrom-Json
if($published.Status -ne 'Published' -or $published.Reason -ne '测试核验'){throw '提交状态更新失败。'}
$submissionCases=& {
    . (Join-Path $repositoryRoot 'shared\douyin\Comments.ps1')
    . (Join-Path $projectRoot 'src\workflows\Douyin.Comment.ps1')
    $Config=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json')
    $script:RunDirectory=$testRoot
    function Set-RpaProgress([string]$Stage) {$script:RunReport.Stage=$Stage}
    function Write-DouyinRecoverableError([string]$Stage,[string]$Reason) {$script:RunReport.RecoverableErrors++}
    function Save-DouyinEvidence([string]$Stage) {if($script:SubmissionCase -eq 'screenshot-error'){throw '模拟截图异常。'}}
    function Wait-RpaDelay([double]$Seconds) {if($script:RunReport.Status -eq 'WaitingForVerification'){$script:CaptchaWaitObserved=$true}}
    function Get-DouyinChallenge {if($script:CaptchaQueue.Count -gt 0){return $script:CaptchaQueue.Dequeue()};return $null}
    function Get-CommentCard {throw '提交后不应检查评论列表。'}
    function Invoke-DouyinClick($Element) {throw '提交完成后不得再次点击发送。'}
    function Open-DouyinUrl([string]$Url) {throw '提交后不得导航刷新。'}
    function Open-DouyinComments($Video) {throw '提交后不得重新打开评论。'}
    $index=0
    foreach($case in @('normal','captcha','screenshot-error')){
        $index++;$script:SubmissionCase=$case;$script:CaptchaWaitObserved=$false
        $script:CaptchaQueue=New-Object Collections.Queue
        if($case -eq 'captcha'){$script:CaptchaQueue.Enqueue('请输入验证码');$script:CaptchaQueue.Enqueue('请输入验证码')}
        $script:RunReport=[ordered]@{Status='Running';Stage='Submitting';Reason=$null;Submitted=0;RecoverableErrors=0}
        $target=[pscustomobject]@{VideoId=('123456789012345679'+$index);Url='https://www.douyin.com/';Title='离线提交';Topic='测试选题'}
        $null=New-RpaSubmissionClaim $target '测试评论'
        $script:PendingVideoId=$target.VideoId
        $result=Complete-DouyinSubmission $target
        $record=Get-Content -LiteralPath (Get-RpaLedgerPath $target.VideoId) -Raw -Encoding UTF8 | ConvertFrom-Json
        if($result -ne 'Submitted' -or $record.Status -ne 'Submitted' -or $script:PendingVideoId -or $script:RunReport.Submitted -ne 1){throw '提交计数、记录或任务状态错误。'}
        if(($case -eq 'captcha') -ne $script:CaptchaWaitObserved){throw '验证码等待条件错误。'}
        if($case -eq 'screenshot-error' -and $script:RunReport.RecoverableErrors -ne 1){throw '截图失败未按可恢复异常继续。'}
        $retryDenied=$false;try{$null=New-RpaSubmissionClaim $target '测试评论'}catch{$retryDenied=$true}
        if(-not $retryDenied){throw '已提交的评论仍允许重复提交。'}
    }
    return $index
}
$loopRecovery=& {
    . (Join-Path $repositoryRoot 'shared\douyin\Comments.ps1')
    . (Join-Path $projectRoot 'src\workflows\Douyin.Comment.ps1')
    $Config=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json');$Config.SearchTerms=@('测试选题')
    $script:RunReport=[ordered]@{Status='Running';Processed=0;Submitted=0;Published=0;Previewed=0;Skipped=0;RecoverableErrors=0;LastError=$null;LastVideoId=$null;LastVideoStatus=$null;Stage='Starting'}
    $script:RunDirectory=$testRoot;$script:PendingVideoId=$null
    function Wait-RpaDelay([double]$Seconds) {}
    function Initialize-DouyinBrowserWithRecovery([bool]$Continuous) {}
    function Wait-DouyinSendInterval {}
    function Initialize-DouyinKeywordPool {}
    function Get-DouyinSearchBatch([int]$MaxTerms=12) {return $Config.SearchTerms}
    function Complete-DouyinSearchTerm([string]$Term) {}
    function Get-DouyinKeywordStats {return [pscustomobject]@{Total=1;Pending=1;Completed=0}}
    function Find-DouyinVideos([string]$Topic) {
        foreach($id in @('1234567890123456811','1234567890123456812')){[pscustomobject]@{VideoId=$id;Url='https://www.douyin.com/video/'+$id;Title='测试目标';Topic=$Topic}}
    }
    function Invoke-DouyinVideo($Video,[bool]$Publish) {
        if($Video.VideoId -eq '1234567890123456811'){$null=New-RpaSubmissionClaim $Video '测试评论';$script:PendingVideoId=$Video.VideoId;throw '模拟一次发送步骤异常。'}
        $script:RunReport.Submitted++;return 'Submitted'
    }
    Invoke-DouyinLoop $true $true 2
    $first=Get-Content -LiteralPath (Get-RpaLedgerPath '1234567890123456811') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($script:RunReport.Processed -ne 2 -or $script:RunReport.Skipped -ne 1 -or $script:RunReport.Submitted -ne 1 -or $script:PendingVideoId -or $first.Status -ne 'NeedsVisualReview'){throw '单条异常没有保留去重记录并继续下一条。'}
    return $true
}
$intervalCases=& {
    . (Join-Path $repositoryRoot 'shared\douyin\Comments.ps1')
    . (Join-Path $projectRoot 'src\workflows\Douyin.Comment.ps1')
    $Config=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json');$Config.Timing.CommentIntervalSeconds=60
    $script:RpaStateRoot=Join-Path $testRoot 'interval-state';$null=New-Item -ItemType Directory -Path $script:RpaStateRoot -Force
    $script:IntervalNow=[DateTimeOffset]::Parse('2026-10-13T00:00:00Z');$script:IntervalWaited=0;$script:CancelInterval=$false
    $script:RunReport=[ordered]@{Status='Running';Stage='PreparingComment'}
    function Get-DouyinIntervalTime {return $script:IntervalNow}
    function Wait-RpaDelay([double]$Seconds) {
        if($script:CancelInterval){throw [OperationCanceledException]::new('模拟等待期间停止。')}
        $script:IntervalWaited+=$Seconds;$script:IntervalNow=$script:IntervalNow.AddSeconds($Seconds)
    }
    function Get-DouyinChallenge {return $null}
    function Set-RpaProgress([string]$Stage) {$script:RunReport.Stage=$Stage}
    Initialize-DouyinSendInterval
    $startPath=Join-Path $script:RpaStateRoot 'send-interval-start.json'
    $started=Get-Content -LiteralPath $startPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:IntervalNow=$script:IntervalNow.AddSeconds(20)
    # 模拟重启：只能读取既有首发起点，搜索准备已经消耗的时间不再重复等待。
    Initialize-DouyinSendInterval
    $restarted=Get-Content -LiteralPath $startPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Wait-DouyinSendInterval
    if($started.Time -ne $restarted.Time -or $script:IntervalWaited -ne 40){throw '首发冷却被重启重置、绕过或没有与准备时间重叠。'}
    $submitPath=Join-Path $script:RpaStateRoot 'last-submit.json'
    # 兼容历史只有 Time/VideoId、没有 Status 的最后发送记录。
    Write-RpaStateJson ([ordered]@{Time=$script:IntervalNow.AddSeconds(-15).ToString('o');VideoId='1234567890123456820'}) $submitPath
    $script:IntervalWaited=0;Wait-DouyinSendInterval
    if($script:IntervalWaited -ne 45){throw '跨运行没有依据最后一次实际提交补足 60 秒。'}
    Write-RpaStateJson ([ordered]@{Time=$script:IntervalNow.AddHours(-2).ToString('o');VideoId='1234567890123456821';Status='Pending'}) $submitPath
    $script:IntervalWaited=0;Initialize-DouyinSendInterval
    $recoveryStart=Get-Content -LiteralPath $submitPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:IntervalNow=$script:IntervalNow.AddSeconds(20)
    Initialize-DouyinSendInterval
    Wait-DouyinSendInterval
    $recovered=Get-Content -LiteralPath $submitPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($script:IntervalWaited -ne 40 -or $recovered.Status -ne 'RecoveryCooldown' -or $recovered.Time -ne $recoveryStart.Time){throw '不确定提交恢复时没有保留完整冷却，或重启改变了恢复起点。'}
    Write-RpaStateJson ([ordered]@{Time=$script:IntervalNow.ToString('o');Status='Submitted'}) $submitPath
    $script:CancelInterval=$true;$cancelled=$false
    try{Wait-DouyinSendInterval}catch [OperationCanceledException]{$cancelled=$true}
    if(-not $cancelled){throw '发送等待不能响应取消。'}
    return 4
}
$sendGateCases=& {
    . (Join-Path $repositoryRoot 'shared\douyin\Comments.ps1')
    . (Join-Path $projectRoot 'src\workflows\Douyin.Comment.ps1')
    $Config=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json');$Config.Timing.CommentIntervalSeconds=60
    $script:RpaStateRoot=Join-Path $testRoot 'send-gate-state';$null=New-Item -ItemType Directory -Path (Join-Path $script:RpaStateRoot 'videos') -Force
    $script:RunReport=[ordered]@{Status='Running';Stage='PreparingComment';Submitted=0}
    $script:SendGateNow=[DateTimeOffset]::Parse('2026-10-13T01:00:00Z')
    function Get-DouyinIntervalTime {return $script:SendGateNow}
    function Set-RpaProgress([string]$Stage) {$script:RunReport.Stage=$Stage}
    function Assert-RpaRunning {if($script:SendGateCase -eq 'cancel-before-claim'){throw [OperationCanceledException]::new('提交前停止。')}}
    function Wait-DouyinSendInterval {
        $script:SendGateEvents.Add('wait')
        if($script:SendGateCase -eq 'cancel-wait'){throw [OperationCanceledException]::new('等待期间停止。')}
        $script:SendGateNow=$script:SendGateNow.AddSeconds(60)
    }
    function Ensure-DouyinForeground {
        $script:SendGateEvents.Add('identity-url')
        if($script:SendGateCase -eq 'url-changed'){throw '视频编号改变。'}
    }
    function Get-CommentCard {$script:SendGateEvents.Add('card');return [pscustomobject]@{Kind='fresh-card'}}
    function Get-CommentEditor($Card) {
        $script:SendGateEvents.Add('editor')
        if($Card.Kind -ne 'fresh-card'){throw '没有重新定位评论侧栏。'}
        return [pscustomobject]@{Current=[pscustomobject]@{HasKeyboardFocus=($script:SendGateCase -ne 'focus-lost')}}
    }
    function Get-UiaValue($Element) {if($script:SendGateCase -eq 'draft-changed'){return '已变化草稿'};return $Config.Comment}
    function Get-DouyinSendButton($Editor) {
        $script:SendGateEvents.Add('sender')
        if($script:SendGateCase -eq 'sender-changed'){throw '发送按钮不唯一。'}
        return [pscustomobject]@{Kind='fresh-sender'}
    }
    function Invoke-DouyinClick($Element) {
        $script:SendGateEvents.Add('click');$script:SendGateClicks++
        if($Element.Kind -ne 'fresh-sender'){throw '点击了旧发送按钮。'}
        $record=Get-Content -LiteralPath (Get-RpaLedgerPath $script:SendGateVideo.VideoId) -Raw -Encoding UTF8 | ConvertFrom-Json
        $attempt=Get-Content -LiteralPath (Join-Path $script:RpaStateRoot 'last-submit.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if($record.Status -ne 'Submitting' -or $attempt.Status -ne 'Pending'){throw '点击前未持久化排他提交及不确定间隔。'}
        $script:SendGateNow=$script:SendGateNow.AddSeconds(3)
        if($script:SendGateCase -eq 'click-unknown'){throw '模拟点击结果未知。'}
    }
    function Complete-DouyinSubmission($Video) {$script:SendGateEvents.Add('complete');return 'Submitted'}
    $count=0
    foreach($case in @('normal','cancel-wait','url-changed','focus-lost','draft-changed','sender-changed','cancel-before-claim','duplicate','click-unknown')){
        $count++;$script:SendGateCase=$case;$script:SendGateClicks=0;$script:PendingVideoId=$null
        $script:SendGateEvents=New-Object 'Collections.Generic.List[string]'
        $script:SendGateVideo=[pscustomobject]@{VideoId=('123456789012345683'+$count);Url='https://www.douyin.com/';Title='离线目标';Topic='测试选题'}
        if($case -eq 'duplicate'){$null=New-RpaSubmissionClaim $script:SendGateVideo $Config.Comment}
        $failed=$false;try{$result=Submit-DouyinPreparedComment $script:SendGateVideo}catch{$failed=$true}
        if($case -eq 'normal'){
            $attempt=Get-Content -LiteralPath (Join-Path $script:RpaStateRoot 'last-submit.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if($failed -or $result -ne 'Submitted' -or $script:SendGateClicks -ne 1 -or $attempt.Status -ne 'Submitted' -or [DateTimeOffset]::Parse($attempt.Time) -ne $script:SendGateNow){throw '单次提交或以点击完成时间计时失效。'}
            if(($script:SendGateEvents -join ',') -ne 'wait,identity-url,card,editor,sender,identity-url,click,complete'){throw '发送等待之后未按顺序重新校验页面、草稿和按钮。'}
        }elseif($case -eq 'click-unknown'){
            $attempt=Get-Content -LiteralPath (Join-Path $script:RpaStateRoot 'last-submit.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if(-not $failed -or $script:SendGateClicks -ne 1 -or $attempt.Status -ne 'Pending' -or -not $script:PendingVideoId){throw '未知提交没有保留排他状态，或发生自动重发。'}
        }elseif(-not $failed -or $script:SendGateClicks -ne 0){throw ('提交保护失效：'+$case)}
    }
    return $count
}
$zeroCycleCases=& {
    . (Join-Path $repositoryRoot 'shared\douyin\Comments.ps1')
    . (Join-Path $projectRoot 'src\workflows\Douyin.Comment.ps1')
    $Config=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json');$Config.SearchTerms=@('测试选题');$Config.Timing.EmptyQueueWaitSeconds=0
    $script:RunDirectory=$testRoot;$script:PendingVideoId=$null
    $script:RunReport=[ordered]@{Status='Running';Processed=0;Submitted=0;Published=0;Previewed=0;Skipped=0;RecoverableErrors=0;LastError=$null;LastVideoId=$null;LastVideoStatus=$null;Stage='Starting';NextCycleAt=$null}
    function Wait-RpaDelay([double]$Seconds) {if($Seconds -ne 0){throw ('出现不必要业务等待：'+$Seconds)}}
    function Initialize-DouyinBrowserWithRecovery([bool]$Continuous) {}
    function Initialize-DouyinSendInterval {}
    function Wait-DouyinSendInterval {throw '不能在搜索或打开视频之前等待发送间隔。'}
    function Initialize-DouyinKeywordPool {}
    function Get-DouyinSearchBatch([int]$MaxTerms=12) {return $Config.SearchTerms}
    function Complete-DouyinSearchTerm([string]$Term) {}
    function Get-DouyinKeywordStats {return [pscustomobject]@{Total=1;Pending=1;Completed=0}}
    function Find-DouyinVideos([string]$Topic) {
        $script:ZeroCycleSearches++
        if($script:ZeroCycleSearches -eq 1){throw '模拟单次搜索失败。'}
        if($script:ZeroCycleSearches -eq 2){return @()}
        foreach($id in @('1234567890123456851','1234567890123456852')){[pscustomobject]@{VideoId=$id;Url='https://www.douyin.com/video/'+$id;Title='离线测试目标';Topic=$Topic}}
    }
    function Invoke-DouyinVideo($Video,[bool]$Publish) {
        if($Video.VideoId -eq '1234567890123456851'){throw '模拟单条准备失败。'}
        $script:RunReport.Submitted++;return 'Submitted'
    }
    $script:ZeroCycleSearches=0
    Invoke-DouyinLoop $true $true 2
    if($script:ZeroCycleSearches -ne 3 -or $script:RunReport.Skipped -ne 1 -or $script:RunReport.Submitted -ne 1 -or $script:RunReport.NextCycleAt){throw '零间隔空轮或单次异常后的继续行为错误。'}
    return 3
}
$keywordWorkflowCases=& {
    . (Join-Path $repositoryRoot 'shared\douyin\Comments.ps1')
    . (Join-Path $projectRoot 'src\workflows\Douyin.Comment.ps1')
    $Config=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json');$Config.Timing.EmptyQueueWaitSeconds=0
    $script:RpaStateRoot=Join-Path $testRoot 'keyword-loop-state';$null=New-Item -ItemType Directory -Path (Join-Path $script:RpaStateRoot 'videos') -Force
    $script:RunDirectory=$testRoot;$script:PendingVideoId=$null
    $script:RunReport=[ordered]@{Status='Running';Processed=0;Submitted=0;Published=0;Previewed=0;Skipped=0;RecoverableErrors=0;LastError=$null;LastVideoId=$null;LastVideoStatus=$null;Stage='Starting';NextCycleAt=$null}
    $script:KeywordLoopCompleted=New-Object 'Collections.Generic.List[string]'
    $script:KeywordLoopBatches=0;$script:KeywordLoopStatsReads=0;$script:KeywordLoopExpanded=$false;$script:KeywordLoopInitialized=$false
    function Initialize-DouyinKeywordPool {$script:KeywordLoopInitialized=$true}
    function Get-DouyinSearchBatch([int]$MaxTerms=12) {
        if(-not $script:KeywordLoopInitialized -or $MaxTerms -ne 12){throw '关键词池初始化或批次大小错误。'}
        $script:KeywordLoopBatches++
        if($script:KeywordLoopBatches -eq 1){return @('AI失败种子','AI成功种子')}
        if($script:KeywordLoopBatches -eq 2){return @('AI新观察选题')}
        throw '关键词批次没有接续到新词。'
    }
    function Complete-DouyinSearchTerm([string]$Term) {$script:KeywordLoopCompleted.Add($Term)}
    function Get-DouyinKeywordStats {
        $script:KeywordLoopStatsReads++
        $total=2;if($script:KeywordLoopExpanded){$total++}
        return [pscustomobject]@{Total=$total;Pending=($total-$script:KeywordLoopCompleted.Count);Completed=$script:KeywordLoopCompleted.Count}
    }
    function Wait-RpaDelay([double]$Seconds) {if($Seconds -ne 0){throw '关键词接续额外等待。'}}
    function Initialize-DouyinBrowserWithRecovery([bool]$Continuous) {}
    function Find-DouyinVideos([string]$Topic) {
        if($Topic -eq 'AI失败种子'){throw '模拟搜索失败，不可标记已完成。'}
        if($Topic -eq 'AI成功种子'){$script:KeywordLoopExpanded=$true;return @()}
        return [pscustomobject]@{VideoId='1234567890123456861';Url='https://www.douyin.com/';Title='离线测试目标';Topic=$Topic}
    }
    function Invoke-DouyinVideo($Video,[bool]$Publish) {if($Publish){throw '测试不得发布。'};return 'Previewed'}
    Invoke-DouyinLoop $false $true 1
    if($script:KeywordLoopBatches -ne 2 -or ($script:KeywordLoopCompleted -join ',') -ne 'AI成功种子,AI新观察选题'){throw '搜索失败被误记完成，或新关键词未接入下一批。'}
    if($script:KeywordLoopStatsReads -lt 3 -or $script:RunReport.KeywordTotal -ne 3 -or $script:RunReport.KeywordPending -ne 1 -or $script:RunReport.KeywordCompleted -ne 2){throw '新增关键词和完成统计未写入任务状态。'}
    return 3
}
$keywordObservationCases=& {
    Add-Type -AssemblyName UIAutomationTypes
    . (Join-Path $repositoryRoot 'shared\douyin\Comments.ps1')
    . (Join-Path $projectRoot 'src\workflows\Douyin.Comment.ps1')
    $Config=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json');$Config.MatchAny=@('AI');$Config.Discovery.MaxScrollRounds=0
    $script:RpaStateRoot=Join-Path $testRoot 'keyword-discovery-state';$null=New-Item -ItemType Directory -Path (Join-Path $script:RpaStateRoot 'videos') -Force
    $script:Visited=@{'1234567890123456871'=$true}
    $ledgerVideo=[pscustomobject]@{VideoId='1234567890123456872';Url='https://www.douyin.com/';Title='离线历史目标';Topic='测试选题'}
    $null=New-RpaSubmissionClaim $ledgerVideo '离线测试评论'
    $script:KeywordObservedTitles=New-Object 'Collections.Generic.List[string]'
    function Open-DouyinUrl([string]$Url) {}
    function Get-DouyinChallenge {return $null}
    function Wait-RpaDelay([double]$Seconds) {throw '离线链接检查不应等待或触发真实页面操作。'}
    function Get-DouyinNodes($Root) {
        foreach($item in @(
            @('1234567890123456871','AI已访问仍应观察'),
            @('1234567890123456872','AI历史去重仍应观察'),
            @('1234567890123456873','非相关标题不应观察'),
            @('1234567890123456874','AI新目标也应观察')
        )){
            [pscustomobject]@{Address=('https://www.douyin.com/video/'+$item[0]);Current=[pscustomobject]@{Name=$item[1];ControlType=[System.Windows.Automation.ControlType]::Hyperlink}}
        }
    }
    function Get-UiaValue($Element) {return $Element.Address}
    function Add-DouyinKeywordObservations([string]$Title) {$script:KeywordObservedTitles.Add($Title);return 1}
    $found=@(Find-DouyinVideos 'AI离线选题')
    if($found.Count -ne 1 -or $found[0].VideoId -ne '1234567890123456874'){throw '关键词观察改变了既有视频去重。'}
    if(($script:KeywordObservedTitles -join ',') -ne 'AI已访问仍应观察,AI历史去重仍应观察,AI新目标也应观察'){throw '已访问标题未继续观察，或无关标题被用于关键词扩展。'}
    return 3
}
$lockPath=Join-Path $testRoot 'exclusive.lock'
$owner=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{$locked=$false;try{$second=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$second.Dispose()}catch{$locked=$true};if(-not $locked){throw '互斥锁没有阻止第二个实例。'}}finally{$owner.Dispose()}
$keyboardDenied=0
try{[DingRpa]::TypeUnicodeText([IntPtr]::Zero,'测试')}catch{$keyboardDenied++}
try{[DingRpa]::PressEnter([IntPtr]::Zero)}catch{$keyboardDenied++}
try{[DingRpa]::ActivateTarget([IntPtr]::Zero,0)}catch{$keyboardDenied++}
if($keyboardDenied -ne 3){throw '无效目标仍可执行原生输入。'}
$script:RpaControlRoot=Join-Path $testRoot 'control';$null=New-Item -ItemType Directory -Path $script:RpaControlRoot -Force
Set-Content -LiteralPath (Join-Path $script:RpaControlRoot 'stop') -Value 'test'
$stopped=$false;try{Assert-RpaRunning}catch [OperationCanceledException]{$stopped=$true}
if(-not $stopped){throw '停止信号没有终止流程。'}
[pscustomobject]@{Status='Passed';InvalidConfigurationsRejected=$rejected;ZeroCycleDelayAccepted=$true;MoreThanTwentySeedsAccepted=$true;ThemeLimitPreserved=$themesRejected;UntrustedUrlsRejected=$denied;AtomicJsonRoundTrip=$true;DuplicateClaimRejected=$true;InterruptedSubmissionPreserved=$true;SubmissionWithoutReadbackCases=$submissionCases;ContinueAfterVideoFailure=$loopRecovery;SendIntervalCases=$intervalCases;PreparedSubmissionSafetyCases=$sendGateCases;NoExtraBusinessDelayCases=$zeroCycleCases;KeywordWorkflowCases=$keywordWorkflowCases;KeywordObservationCases=$keywordObservationCases;SingleRunnerLock=$true;NativeInvalidTargetsRejected=$keyboardDenied;StopSignal=$true;DesktopActions=0}
