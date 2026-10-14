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
                if(-not $relevant){continue}
                $null=Add-DouyinKeywordObservations -Title $title
                if($found.ContainsKey($id) -or $script:Visited.ContainsKey($id) -or (Test-Path -LiteralPath (Get-RpaLedgerPath $id))){continue}
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
    return Submit-DouyinPreparedComment $Video
}

function Submit-DouyinPreparedComment($Video) {
    # 搜索、打开和准备草稿可以与发送冷却重叠；只在真正提交之前等待。
    Wait-DouyinSendInterval
    Ensure-DouyinForeground
    $card=Get-CommentCard
    if(-not $card){throw '发送等待后评论侧栏已不可用，未提交。'}
    $editor=Get-CommentEditor $card
    if(-not $editor.Current.HasKeyboardFocus){throw '发送等待后评论编辑器已失焦，未提交。'}
    if((Get-UiaValue $editor) -cne $Config.Comment){throw '提交前草稿已变化。'}
    $sender=Get-DouyinSendButton $editor
    Ensure-DouyinForeground
    if(-not $editor.Current.HasKeyboardFocus){throw '提交前评论编辑器已失焦，未提交。'}
    if((Get-UiaValue $editor) -cne $Config.Comment){throw '提交前草稿已变化。'}
    Assert-RpaRunning
    $null=New-RpaSubmissionClaim $Video $Config.Comment
    $script:PendingVideoId=$Video.VideoId
    $submitPath=Join-Path $script:RpaStateRoot 'last-submit.json'
    # 先持久化不确定提交，再单次点击；异常退出后的恢复必须重新冷却。
    Write-RpaStateJson ([ordered]@{Time=(Get-DouyinIntervalTime).ToString('o');VideoId=$Video.VideoId;Status='Pending'}) $submitPath
    Set-RpaProgress 'Submitting'
    Invoke-DouyinClick $sender
    $submittedAt=Get-DouyinIntervalTime
    Write-RpaStateJson ([ordered]@{Time=$submittedAt.ToString('o');VideoId=$Video.VideoId;Status='Submitted'}) $submitPath
    $script:RunReport['NextSubmissionAt']=$submittedAt.AddSeconds($Config.Timing.CommentIntervalSeconds).ToString('o')
    return Complete-DouyinSubmission $Video
}
function Invoke-DouyinLoop([bool]$Publish,[bool]$Continuous,[int]$MaxVideos) {
    $script:Visited=@{};$processed=0;$cycle=0
    Initialize-DouyinKeywordPool
    Update-DouyinKeywordProgress
    if($Publish){Initialize-DouyinSendInterval}
    do {
        $cycle++;$newCount=0
        foreach($topic in @(Get-DouyinSearchBatch -MaxTerms 12)){
            Wait-RpaDelay 0
            $script:RunReport['CurrentSearchTerm']=$topic
            Set-RpaProgress ('Searching: '+$topic)
            Write-Host ('搜索选题：'+$topic)
            try{
                Initialize-DouyinBrowserWithRecovery $Continuous
                $videos=@(Find-DouyinVideos $topic)
                Complete-DouyinSearchTerm -Term $topic
                Update-DouyinKeywordProgress
            }catch [OperationCanceledException]{throw}catch{
                if(-not $Continuous){throw}
                Write-DouyinRecoverableError 'SearchSkipped' $_.Exception.Message
                continue
            }
            foreach($video in $videos){
                if($script:Visited.ContainsKey($video.VideoId) -or (Test-Path -LiteralPath (Get-RpaLedgerPath $video.VideoId))){continue}
                $script:Visited[$video.VideoId]=$true;$newCount++
                Write-Host ('处理视频：'+$video.VideoId+'；'+$video.Title)
                try{
                    $status=Invoke-DouyinVideo $video $Publish
                }catch [OperationCanceledException]{throw}catch{
                    if(-not $Continuous){throw}
                    $reason=$_.Exception.Message
                    if($script:PendingVideoId){Set-RpaSubmissionStatus $script:PendingVideoId 'NeedsVisualReview' ('提交步骤异常，保留记录并跳过：'+$reason);$script:PendingVideoId=$null}
                    $status='Skipped';$script:RunReport.Skipped++
                    Write-DouyinRecoverableError 'VideoSkipped' $reason
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
        Write-Host ('第 '+$cycle+' 轮完成；本轮发现 '+$newCount+' 条未处理视频。')
        if($Config.Timing.EmptyQueueWaitSeconds -gt 0){
            Set-RpaProgress 'WaitingForNextCycle'
            $script:RunReport['NextCycleAt']=[DateTimeOffset]::Now.AddSeconds($Config.Timing.EmptyQueueWaitSeconds).ToString('o')
            Wait-RpaDelay $Config.Timing.EmptyQueueWaitSeconds
        }else{
            $script:RunReport['NextCycleAt']=$null
            Set-RpaProgress 'ContinuingSearch'
            Wait-RpaDelay 0
        }
    }while($true)
}
function Update-DouyinKeywordProgress {
    $stats=Get-DouyinKeywordStats
    $script:RunReport['KeywordTotal']=$stats.Total
    $script:RunReport['KeywordPending']=$stats.Pending
    $script:RunReport['KeywordCompleted']=$stats.Completed
}
