function Find-DouyinVideos([string]$Topic) {
    $searchUrl='https://www.douyin.com/search/'+[Uri]::EscapeDataString($Topic)+'?type=video'
    Open-DouyinUrl $searchUrl
    $found=@{};$timer=[Diagnostics.Stopwatch]::StartNew()
    for($round=0;$round -le $Config.Discovery.MaxScrollRounds;$round++){
        do {
            $challenge=Get-DouyinChallenge
            if($challenge){Wait-DouyinHumanGate $challenge}
            $links=@(Get-DouyinNodes $null | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Hyperlink})
            foreach($link in $links){
                $address=Get-UiaValue $link
                if(-not $address -or $address -notmatch '^https://www\.douyin\.com/video/\d{19}/?$'){continue}
                $id=Get-DouyinVideoId $address
                $title=$link.Current.Name
                $relevant=@($Config.MatchAny | Where-Object {$title.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0}).Count -gt 0
                if(-not $relevant -or $found.ContainsKey($id) -or $script:Visited.ContainsKey($id) -or (Test-Path -LiteralPath (Get-RpaLedgerPath $id))){continue}
                $found[$id]=[pscustomobject]@{VideoId=$id;Url=$address;Title=$title;Topic=$Topic}
                if($found.Count -ge $Config.Discovery.MaxVideosPerSearch){break}
            }
            if($found.Count -gt 0 -or $timer.Elapsed.TotalSeconds -ge $Config.Timing.PageWaitSeconds){break}
            Wait-RpaDelay 0.7
        }while($true)
        if($found.Count -ge $Config.Discovery.MaxVideosPerSearch -or $round -eq $Config.Discovery.MaxScrollRounds){break}
        Ensure-DouyinForeground
        $root=Get-DouyinRoot
        $docs=@(Get-DouyinNodes $root | Where-Object {$_.Current.AutomationId -eq 'RootWebArea' -and (Test-UiaInBrowser $_)})
        if($docs.Count -ne 1){throw '无法确认搜索结果滚动区域。'}
        $b=$docs[0].Current.BoundingRectangle
        [DingRpa]::WheelDown($script:BrowserHandle,[int]($b.Left+$b.Width*0.7),[int]($b.Top+$b.Height*0.7))
        Wait-RpaDelay 0.8
    }
    return @($found.Values | Sort-Object VideoId -Descending | Select-Object -First $Config.Discovery.MaxVideosPerSearch)
}
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
function Write-DouyinRecoverableError([string]$Stage,[string]$Reason) {
    $script:RunReport.RecoverableErrors++
    $script:RunReport.LastError=$Reason
    $entry=[ordered]@{Time=(Get-Date -Format o);Stage=$Stage;VideoId=$script:RunReport.LastVideoId;Reason=$Reason}
    Add-Content -LiteralPath (Join-Path $script:RunDirectory 'recoverable-errors.jsonl') -Value (ConvertTo-Json $entry -Compress) -Encoding UTF8
    Write-Host ('跳过本次异常并继续：'+$Reason) -ForegroundColor Yellow
    Set-RpaProgress $Stage
}
function Initialize-DouyinBrowserWithRecovery([bool]$Continuous) {
    do {
        try{Initialize-DouyinBrowser;return}
        catch [OperationCanceledException]{throw}
        catch{
            if(-not $Continuous){throw}
            Write-DouyinRecoverableError 'WaitingForBrowser' $_.Exception.Message
            Wait-RpaDelay 5
        }
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
        Ensure-DouyinForeground
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
function Complete-DouyinSubmission($Video) {
    Set-RpaSubmissionStatus $Video.VideoId 'Submitted' '已执行一次发送动作；按用户要求不刷新、不检查评论可见性，也不自动重发。'
    $script:RunReport.Submitted++
    $script:PendingVideoId=$null
    Set-RpaProgress 'Submitted'
    Wait-RpaDelay 0.6
    $challenge=Get-DouyinChallenge
    if($challenge){Wait-DouyinHumanGate $challenge}
    try{Save-DouyinEvidence 'submitted'}catch [OperationCanceledException]{throw}catch{Write-DouyinRecoverableError 'SubmittedEvidenceUnavailable' $_.Exception.Message}
    return 'Submitted'
}
function Invoke-DouyinVideo($Video,[bool]$Publish) {
    $script:RunReport.LastVideoId=$Video.VideoId
    Set-RpaProgress 'OpeningComments'
    $script:VideoEvidence=Join-Path $script:RunDirectory $Video.VideoId
    $null=New-Item -ItemType Directory -Path $script:VideoEvidence -Force
    Write-RpaStateJson $Video (Join-Path $script:VideoEvidence 'video.json')
    $card=Open-DouyinComments $Video
    Save-DouyinEvidence 'opened'
    if(@(Find-DouyinNamed $Config.Comment $card).Count -gt 0){return 'AlreadyPresent'}
    $placeholders=@(Find-DouyinNamed $Config.Selectors.Placeholder $card)
    if($placeholders.Count -ne 1){throw '评论输入区不为空或不可用。'}
    if(-not $Publish){return 'Previewed'}
    Set-RpaProgress 'PreparingComment'
    Invoke-DouyinClick $placeholders[0]
    Wait-RpaDelay 0.35
    $editor=Get-CommentEditor $card
    if(-not $editor.Current.HasKeyboardFocus -or (Get-UiaValue $editor).Trim().Length -ne 0){throw '编辑器未聚焦或已有草稿，停止输入。'}
    Ensure-DouyinForeground
    if(-not $editor.Current.HasKeyboardFocus){throw '焦点恢复后不是评论编辑器，停止。'}
    foreach($character in $Config.Comment.ToCharArray()){
        Assert-RpaRunning
        if(-not $editor.Current.HasKeyboardFocus){throw '键盘输入期间评论框失焦，停止。'}
        [DingRpa]::TypeUnicodeText($script:BrowserHandle,$character.ToString())
    }
    Wait-RpaDelay 0.5
    if((Get-UiaValue $editor) -cne $Config.Comment){throw '评论文字逐字核对失败，未提交。'}
    Save-DouyinEvidence 'prepared'
    $container=[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($editor)
    $senders=@(Get-DouyinNodes $container | Where-Object {(Test-UiaInBrowser $_) -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Group -and $_.Current.ClassName -in $Config.Selectors.SendButtonClasses})
    if($senders.Count -ne 1){throw '发送按钮结构变化，未提交。'}
    Ensure-DouyinForeground
    if((Get-UiaValue $editor) -cne $Config.Comment){throw '提交前草稿已变化。'}
    $null=New-RpaSubmissionClaim $Video $Config.Comment
    $script:PendingVideoId=$Video.VideoId
    Write-RpaStateJson ([ordered]@{Time=(Get-Date -Format o);VideoId=$Video.VideoId}) (Join-Path $script:RpaStateRoot 'last-submit.json')
    Set-RpaProgress 'Submitting'
    Invoke-DouyinClick $senders[0]
    return Complete-DouyinSubmission $Video
}
function Wait-DouyinSendInterval {
    $path=Join-Path $script:RpaStateRoot 'last-submit.json'
    if(Test-Path -LiteralPath $path){
        $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $next=[DateTimeOffset]::Parse($record.Time).AddSeconds($Config.Timing.CommentIntervalSeconds)
        $remaining=($next-[DateTimeOffset]::Now).TotalSeconds
        if($remaining -gt 0){
            $script:RunReport['NextSubmissionAt']=$next.ToString('o')
            Set-RpaProgress 'WaitingForInterval';Write-Host ('等待发送间隔，剩余 '+[Math]::Ceiling($remaining)+' 秒。')
            while([DateTimeOffset]::Now -lt $next){
                Wait-RpaDelay ([Math]::Min(2,($next-[DateTimeOffset]::Now).TotalSeconds))
                $challenge=Get-DouyinChallenge
                if($challenge){Wait-DouyinHumanGate $challenge;Set-RpaProgress 'WaitingForInterval'}
            }
        }
    }
}
function Invoke-DouyinLoop([bool]$Publish,[bool]$Continuous,[int]$MaxVideos) {
    $script:Visited=@{};$processed=0;$cycle=0
    do {
        $cycle++;$newCount=0
        foreach($topic in $Config.SearchTerms){
            Wait-RpaDelay 0
            Set-RpaProgress ('Searching: '+$topic)
            Write-Host ('搜索选题：'+$topic)
            try{
                Initialize-DouyinBrowserWithRecovery $Continuous
                $videos=@(Find-DouyinVideos $topic)
            }catch [OperationCanceledException]{throw}catch{
                if(-not $Continuous){throw}
                Write-DouyinRecoverableError 'SearchSkipped' $_.Exception.Message
                Wait-RpaDelay 5
                continue
            }
            foreach($video in $videos){
                if($script:Visited.ContainsKey($video.VideoId) -or (Test-Path -LiteralPath (Get-RpaLedgerPath $video.VideoId))){continue}
                $script:Visited[$video.VideoId]=$true;$newCount++
                Write-Host ('处理视频：'+$video.VideoId+'；'+$video.Title)
                try{
                    if($Publish){Wait-DouyinSendInterval}
                    $status=Invoke-DouyinVideo $video $Publish
                }catch [OperationCanceledException]{throw}catch{
                    if(-not $Continuous){throw}
                    $reason=$_.Exception.Message
                    if($script:PendingVideoId){Set-RpaSubmissionStatus $script:PendingVideoId 'NeedsVisualReview' ('提交步骤异常，保留记录并跳过：'+$reason);$script:PendingVideoId=$null}
                    $status='Skipped';$script:RunReport.Skipped++
                    Write-DouyinRecoverableError 'VideoSkipped' $reason
                    Wait-RpaDelay 5
                }
                $processed++
                $script:RunReport.Processed=$processed
                if($status -eq 'Published'){$script:RunReport.Published++}
                if($status -eq 'Previewed'){$script:RunReport.Previewed++}
                $script:RunReport.LastVideoId=$video.VideoId;$script:RunReport.LastVideoStatus=$status
                Write-RpaStateJson $script:RunReport (Join-Path $script:RunDirectory 'result.json')
                if($MaxVideos -gt 0 -and $processed -ge $MaxVideos){return}
            }
        }
        if(-not $Continuous){return}
        Write-Host ('第 '+$cycle+' 轮完成；本轮发现 '+$newCount+' 条未处理视频。等待下一轮。')
        Set-RpaProgress 'WaitingForNextCycle'
        $script:RunReport['NextCycleAt']=[DateTimeOffset]::Now.AddSeconds($Config.Timing.EmptyQueueWaitSeconds).ToString('o')
        Wait-RpaDelay $Config.Timing.EmptyQueueWaitSeconds
    }while($true)
}
