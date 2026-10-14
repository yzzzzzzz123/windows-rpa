# 两个抖音 Skill 共用的评论区控件与发送冷却；具体目标筛选、回复/顶层评论提交归各自 Skill。
# 先加载 shared/douyin/Urls.ps1、Browser.ps1，以及 UIAutomationClient/UIAutomationTypes 与 DingRpa。
# 调用方提供 Config.Selectors、Config.Timing、RunReport、RunDirectory、RpaStateRoot，
# 并提供 Assert-RpaRunning、Wait-RpaDelay、Set-RpaProgress、Write-RpaStateJson。
# Open-DouyinComments 保留顶层评论 Placeholder 检查；回复目标的定位/核验由回复 Skill 实现。
function Wait-DouyinHumanGate([string]$Reason) {
    Write-Host ('等待人工处理验证码：'+$Reason+'。完成后继续后续视频，不重复提交当前视频。') -ForegroundColor Yellow
    $script:RunReport.Status='WaitingForVerification';$script:RunReport.Reason=$Reason
    $script:RunReport.Stage='WaitingForVerification'
    Write-RpaStateJson $script:RunReport (Join-Path $script:RunDirectory 'result.json')
    do {
        Wait-RpaDelay 2
        try{$challenge=Get-DouyinChallenge}catch [OperationCanceledException]{throw}catch{$script:RunReport.LastError=$_.Exception.Message;continue}
        if(-not $challenge){$script:RunReport.Status='Running';$script:RunReport.Reason=$null;Set-RpaProgress 'VerificationCompleted';return}
    }while($true)
}
function Get-CommentCard {
    $root=Get-DouyinRoot
    $nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$Config.Selectors.CommentCardAutomationId)))
    $visible=@($nodes | Where-Object {(Test-UiaInBrowser $_) -and $_.Current.BoundingRectangle.Width -gt 100})
    if($visible.Count -gt 1){throw '多个评论侧栏同时可见，停止。'}
    if($visible.Count -eq 1){return $visible[0]}
    return $null
}
function Open-DouyinComments($Video) {
    Open-DouyinUrl ('https://www.douyin.com/jingxuan?modal_id='+$Video.VideoId)
    $script:ExpectedVideoId=$Video.VideoId
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        try { Ensure-DouyinForeground }
        catch {
            # 地址栏可能先完成导航，UIA Document 随后才更新；只等待这一种加载竞态。
            if($_.Exception.Message -eq '网页文档与地址栏的视频编号未同时通过校验。' -and $timer.Elapsed.TotalSeconds -lt $Config.Timing.PageWaitSeconds){Wait-RpaDelay 0.4;continue}
            throw
        }
        $challenge=Get-DouyinChallenge
        if($challenge){Wait-DouyinHumanGate $challenge}
        $nodes=@(Get-DouyinNodes $null)
        # Pause only when the currently exposed player explicitly shows a pause icon.
        $pauseIcons=@($nodes | Where-Object {(Test-UiaInBrowser $_) -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Image -and ($_.Current.ClassName -split ' ') -contains 'xg-icon-pause'})
        if($pauseIcons.Count -eq 1){Invoke-DouyinClick $pauseIcons[0]; Wait-RpaDelay 0.15}
        $card=Get-CommentCard
        if($card -and @(Find-DouyinNamed $Config.Selectors.Placeholder $card).Count -eq 1){return $card}
        $buttons=@($nodes | Where-Object {(Test-UiaInBrowser $_) -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Group -and ($_.Current.ClassName -split ' ') -contains $Config.Selectors.CommentButtonClassToken})
        if($buttons.Count -gt 1){throw '评论入口不唯一，停止。'}
        if($buttons.Count -eq 1){Invoke-DouyinClick $buttons[0]; Wait-RpaDelay 0.8; $card=Get-CommentCard; if($card){return $card}}
        Wait-RpaDelay 0.4
    }while($timer.Elapsed.TotalSeconds -lt $Config.Timing.PageWaitSeconds)
    throw '评论区未能在限定时间内打开。'
}
function Get-CommentEditor($Card) {
    $nodes=$Card.FindAll([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty,$Config.Selectors.EditorClass)))
    $visible=@($nodes | Where-Object {Test-UiaInBrowser $_})
    if($visible.Count -ne 1){throw '没有唯一的评论编辑器。'}
    return $visible[0]
}
function Get-DouyinSendButton($Editor) {
    $container=[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($Editor)
    $senders=@(Get-DouyinNodes $container | Where-Object {(Test-UiaInBrowser $_) -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Group -and $_.Current.ClassName -in $Config.Selectors.SendButtonClasses})
    if($senders.Count -ne 1){throw '发送按钮结构变化，未提交。'}
    return $senders[0]
}
function Get-DouyinIntervalTime {return [DateTimeOffset]::UtcNow}
function Initialize-DouyinSendInterval {
    $path=Join-Path $script:RpaStateRoot 'last-submit.json'
    if(Test-Path -LiteralPath $path){
        $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if($record.Status -eq 'Pending'){
            Write-RpaStateJson ([ordered]@{Time=(Get-DouyinIntervalTime).ToString('o');VideoId=$record.VideoId;Status='RecoveryCooldown'}) $path
        }
        return
    }
    $startPath=Join-Path $script:RpaStateRoot 'send-interval-start.json'
    if(-not (Test-Path -LiteralPath $startPath)){
        Write-RpaStateJson ([ordered]@{Time=(Get-DouyinIntervalTime).ToString('o');Status='InitialCooldown'}) $startPath
    }
}
function Wait-DouyinSendInterval {
    Initialize-DouyinSendInterval
    $path=Join-Path $script:RpaStateRoot 'last-submit.json'
    if(-not (Test-Path -LiteralPath $path)){$path=Join-Path $script:RpaStateRoot 'send-interval-start.json'}
    $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $next=[DateTimeOffset]::Parse($record.Time).AddSeconds($Config.Timing.CommentIntervalSeconds)
    $script:RunReport['NextSubmissionAt']=$next.ToString('o')
    $remaining=($next-(Get-DouyinIntervalTime)).TotalSeconds
    if($remaining -gt 0){
        Set-RpaProgress 'WaitingForInterval';Write-Host ('等待发送间隔，剩余 '+[Math]::Ceiling($remaining)+' 秒。')
        while(($remaining=($next-(Get-DouyinIntervalTime)).TotalSeconds) -gt 0){
            Wait-RpaDelay ([Math]::Min(2,$remaining))
            $challenge=Get-DouyinChallenge
            if($challenge){Wait-DouyinHumanGate $challenge;Set-RpaProgress 'WaitingForInterval'}
        }
    }
    Wait-RpaDelay 0
}
