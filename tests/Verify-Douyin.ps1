[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src\core\Douyin.Configuration.ps1')
. (Join-Path $projectRoot 'src\core\RpaState.ps1')
if(-not ('DingRpa' -as [type])){Add-Type -Path (Join-Path $projectRoot 'src\native\DingRpa.cs')}
$testRoot=Join-Path $projectRoot ('work\douyin-tests-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot -Force
$original=Get-Content -LiteralPath (Join-Path $projectRoot 'config\douyin.json') -Raw -Encoding UTF8
$null=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json')
$bad=@($original.Replace('"CommentIntervalSeconds": 10','"CommentIntervalSeconds": 0'),$original.Replace('"MaxScrollRounds": 3','"MaxScrollRounds": 1.5'),$original.Replace('"ProcessName": "chrome"','"ProcessName": "other"'),$original.Replace('"SearchTerms": ["AI视频剪辑", "AI分镜创作", "AI无限画布"]','"SearchTerms": []'))
$rejected=0
foreach($json in $bad){$path=Join-Path $testRoot 'invalid.json'; [IO.File]::WriteAllText($path,$json,(New-Object Text.UTF8Encoding($false)));try{$null=Read-DouyinConfiguration $path}catch{$rejected++}}
if($rejected -ne $bad.Count){throw '无效抖音配置被接受。'}
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
    . (Join-Path $projectRoot 'src\workflows\Douyin.Comment.ps1')
    $Config=Read-DouyinConfiguration (Join-Path $projectRoot 'config\douyin.json');$Config.SearchTerms=@('测试选题')
    $script:RunReport=[ordered]@{Status='Running';Processed=0;Submitted=0;Published=0;Previewed=0;Skipped=0;RecoverableErrors=0;LastError=$null;LastVideoId=$null;LastVideoStatus=$null;Stage='Starting'}
    $script:RunDirectory=$testRoot;$script:PendingVideoId=$null
    function Wait-RpaDelay([double]$Seconds) {}
    function Initialize-DouyinBrowserWithRecovery([bool]$Continuous) {}
    function Wait-DouyinSendInterval {}
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
[pscustomobject]@{Status='Passed';InvalidConfigurationsRejected=$rejected;UntrustedUrlsRejected=$denied;AtomicJsonRoundTrip=$true;DuplicateClaimRejected=$true;InterruptedSubmissionPreserved=$true;SubmissionWithoutReadbackCases=$submissionCases;ContinueAfterVideoFailure=$loopRecovery;SingleRunnerLock=$true;NativeInvalidTargetsRejected=$keyboardDenied;StopSignal=$true;DesktopActions=0}
