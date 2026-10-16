function Find-ReplyVideos([string]$Term) {
    Open-DouyinUrl ('https://www.douyin.com/search/'+[Uri]::EscapeDataString($Term)+'?type=video')
    $found=@{};$timer=[Diagnostics.Stopwatch]::StartNew();$searchReloaded=$false
    do {
        Ensure-DouyinForeground
        $challenge=Get-DouyinChallenge
        if($challenge){Wait-DouyinHumanGate $challenge}
        foreach($link in @(Get-DouyinNodes $null)){
            if($link.Current.ControlType -ne [System.Windows.Automation.ControlType]::Hyperlink){continue}
            $url=Get-UiaValue $link
            if($url -notmatch '^https://www\.douyin\.com/video/(\d{19})/?(?:\?.*)?$'){continue}
            $id=$Matches[1];$title=$link.Current.Name
            if(-not $title -or $title.Length -gt 2000){continue}
            if(@($Config.MatchAny | Where-Object {$title.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0}).Count -eq 0){continue}
            if(-not $found.ContainsKey($id)){$found[$id]=[pscustomobject]@{VideoId=$id;Title=$title;Url=('https://www.douyin.com/video/'+$id);SearchTerm=$Term}}
        }
        if($found.Count -gt 0){break}
        # 仅搜索页在无视频链接且列表仍为加载占位时，允许一次可核验的浏览器重载。
        if(-not $searchReloaded -and $timer.Elapsed.TotalSeconds -ge $Config.Timing.PageWaitSeconds){
            $nodes=@(Get-DouyinNodes $null)
            $placeholders=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and -not $_.Current.Name -and (Test-UiaInBrowser $_)})
            $videoLinks=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Hyperlink -and (Get-UiaValue $_) -match '^https://www\.douyin\.com/video/\d{19}'})
            $reload=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.AutomationId -ceq 'view_1003' -and $_.Current.Name -ceq '重新加载' -and (Test-UiaInBrowser $_)})
            if($placeholders.Count -ge 3 -and $videoLinks.Count -eq 0 -and $reload.Count -eq 1){
                $address=ConvertTo-DouyinUri (Get-UiaValue (Get-DouyinAddressElement))
                if([Uri]::UnescapeDataString($address.AbsolutePath) -cne ('/search/'+$Term)){throw '搜索页地址已变化，停止重载。'}
                Invoke-DouyinClick $reload[0]
                $searchReloaded=$true;$script:RunReport['SearchReloaded']=$true
                $timer.Restart();Wait-RpaDelay 1
            }
        }
        Wait-RpaDelay 0.7
    }while($timer.Elapsed.TotalSeconds -lt ($Config.Timing.PageWaitSeconds+1))
    if($found.Count -eq 0){
        # 空结果也保留原生页面证据，避免把页面异常静默当作候选耗尽。
        $previousEvidence=$script:VideoEvidence
        try{
            $script:VideoEvidence=Join-Path $script:RunDirectory ('search-empty-'+[Guid]::NewGuid().ToString('N'))
            $null=New-Item -ItemType Directory -Path $script:VideoEvidence -Force
            Save-DouyinEvidence 'search-empty'
            $script:RunReport['EmptySearchEvidence']=$script:VideoEvidence
        }catch{$script:RunReport['EmptySearchEvidenceError']=$_.Exception.Message}
        finally{$script:VideoEvidence=$previousEvidence}
    }
    $visited=Get-ReplyDiscoveryVisitHistory
    $script:RunReport['DiscoveryHistoryCount']=$visited.Count
    $script:RunReport['DiscoveryNewVideoCount']=@($found.Values | Where-Object {-not $visited.ContainsKey($_.VideoId)}).Count
    $script:RunReport['DiscoveryRevisitedVideoCount']=@($found.Values | Where-Object {$visited.ContainsKey($_.VideoId)}).Count
    return @(Sort-ReplyDiscoveryVideos @($found.Values) $visited)
}
function Get-ReplyDiscoveryVisitHistory {
    $visited=@{}
    $state=Get-Variable -Name RpaStateRoot -Scope Script -ErrorAction SilentlyContinue
    $report=Get-Variable -Name RunReport -Scope Script -ErrorAction SilentlyContinue
    if(-not $state -or -not $state.Value -or -not $report -or -not $report.Value.JobId){return $visited}
    $path=Join-Path $state.Value 'persistent-goal.json'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $visited}
    try{$goal=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $visited}
    # 只采用当前 DataRoot 中绑定本 JobId 的活动目标，独立发现不继承其他任务的历史。
    if($goal.Status -cne 'Active' -or $goal.CurrentJobId -cne $report.Value.JobId){return $visited}
    foreach($id in @($goal.VisitedVideoIds)){if([string]$id -cmatch '^[0-9]{19}$'){$visited[[string]$id]=$true}}
    return $visited
}
function Sort-ReplyDiscoveryVideos([object[]]$Videos,[hashtable]$Visited) {
    # 先处理未查看的视频；全部已看过时仍允许检查新评论，不把视频历史当作永久黑名单。
    return @($Videos | Sort-Object @{Expression={if($Visited.ContainsKey([string]$_.VideoId)){1}else{0}}},@{Expression='VideoId';Descending=$true})
}
function Invoke-ReplyDiscovery {
    $all=New-Object 'Collections.Generic.List[object]';$seenComments=@{};$seenVideos=@{}
    Write-RpaStateJson @() (Join-Path $script:RunDirectory 'candidates.json')
    foreach($term in $Config.SearchTerms){
        Set-RpaProgress ('Searching: '+$term)
        foreach($video in @(Find-ReplyVideos $term)){
            if($seenVideos.ContainsKey($video.VideoId)){continue}
            $seenVideos[$video.VideoId]=$true
            $script:RunReport['LastVideoId']=$video.VideoId
            Set-RpaProgress 'ReadingComments'
            $script:VideoEvidence=Join-Path $script:RunDirectory $video.VideoId
            $null=New-Item -ItemType Directory -Path $script:VideoEvidence -Force
            Write-RpaStateJson $video (Join-Path $script:VideoEvidence 'video.json')
            try {
                $card=Open-DouyinComments $video;$videoCount=0
                for($round=0;$round -le $Config.MaxScrollRounds;$round++){
                    $snapshot=Get-ReplySnapshot $video
                    Write-RpaStateJson @($snapshot.Nodes | Select-Object Index,Parent,Name,Type,Class,Id,Value,Offscreen,Bounds) (Join-Path $script:VideoEvidence ('comments-'+$round+'.json'))
                    foreach($candidate in $snapshot.Candidates){
                        if($seenComments.ContainsKey($candidate.CandidateId)){continue}
                        $seenComments[$candidate.CandidateId]=$true
                        $plain=Get-ReplyPlainCandidate $candidate
                        Assert-ReplyCandidate $plain
                        if(Test-ReplyAlreadyContacted $plain){continue}
                        $all.Add($plain);$videoCount++
                        if($videoCount -ge $Config.MaxCommentsPerVideo){break}
                    }
                    $script:RunReport['CandidateCount']=$all.Count
                    Write-RpaStateJson $all.ToArray() (Join-Path $script:RunDirectory 'candidates.json')
                    Set-RpaProgress 'CandidatesSaved'
                    if($videoCount -ge $Config.MaxCommentsPerVideo -or $round -eq $Config.MaxScrollRounds){break}
                    Move-ReplyCommentPanel $snapshot.Card -3
                }
            }catch [OperationCanceledException]{throw}catch{
                $script:RunReport['LastError']=$_.Exception.Message
                Add-Content -LiteralPath (Join-Path $script:RunDirectory 'discovery-errors.jsonl') -Value (ConvertTo-Json ([ordered]@{VideoId=$video.VideoId;Reason=$_.Exception.Message}) -Compress) -Encoding UTF8
                $script:RunReport.Skipped++
            }
            $script:RunReport.Processed++
            if($seenVideos.Count -ge $Config.MaxVideos){return}
        }
    }
}
function Wait-ReplySendInterval {
    while(($remaining=Get-ReplyCooldownSeconds) -gt 0){
        Set-RpaProgress 'WaitingForInterval'
        Wait-RpaDelay ([Math]::Min(2,$remaining))
        $challenge=Get-DouyinChallenge
        if($challenge){Wait-DouyinHumanGate $challenge}
    }
    Wait-RpaDelay 0
}
function Write-ReplyDraft($Candidate,$Card) {
    $null=Assert-ReplyRecipient $Candidate $Card
    $editor=Get-CommentEditor $Card
    if((Get-UiaValue $editor).Trim().Length -ne 0){throw '评论框已有草稿，停止输入。'}
    Invoke-DouyinClick $editor
    Wait-RpaDelay 0.2
    if(-not $editor.Current.HasKeyboardFocus){throw '回复编辑器未聚焦。'}
    foreach($character in $Candidate.ReplyText.ToCharArray()){
        Assert-RpaRunning
        if(-not $editor.Current.HasKeyboardFocus){throw '回复输入期间失焦，停止。'}
        [DingRpa]::TypeUnicodeText($script:BrowserHandle,$character.ToString())
    }
    Wait-RpaDelay 0.4
    if((Get-UiaValue $editor) -cne $Candidate.ReplyText){throw '回复草稿逐字核对失败。'}
    Restore-ReplyDraftTargetVisibility $Candidate
    $null=Assert-ReplyRecipient $Candidate $Card
}
function Assert-ReplyReadyToSubmit($Candidate) {
    Ensure-DouyinForeground
    Restore-ReplyDraftTargetVisibility $Candidate
    $card=Get-CommentCard
    if(-not $card){throw '发送前评论区不可用。'}
    $null=Assert-ReplyRecipient $Candidate $card
    $editor=Get-CommentEditor $card
    if(-not $editor.Current.HasKeyboardFocus -or (Get-UiaValue $editor) -cne $Candidate.ReplyText){throw '发送前焦点或回复草稿已变化。'}
    $sender=Get-DouyinSendButton $editor
    return $sender
}
function Submit-ReplyDraft($Candidate) {
    Wait-ReplySendInterval
    do {
        Wait-RpaDelay 0
        $sender=Assert-ReplyReadyToSubmit $Candidate
    }while(Test-Path -LiteralPath (Join-Path $script:RpaControlRoot 'pause'))
    # 账记录先于单次点击持久化；任何异常留下 Unknown，禁止自动重试。
    $null=New-ReplySubmissionClaim $Candidate $Candidate.ReplyText
    $script:PendingCandidateId=$Candidate.CandidateId
    Set-RpaProgress 'Submitting'
    try {
        Wait-RpaDelay 0
        $sender=Assert-ReplyReadyToSubmit $Candidate
        if(Test-Path -LiteralPath (Join-Path $script:RpaControlRoot 'pause')){throw [OperationCanceledException]::new('发送校验期间收到暂停；保留未知声明，未继续点击。')}
        Invoke-DouyinClick $sender
        Set-ReplyLastSubmission $Candidate.CandidateId 'Submitted' $Candidate.VideoId
        Set-ReplySubmissionStatus $Candidate.CandidateId 'Submitted' '已执行一次目标评论回复的发送点击；未刷新或检查发布可见性，不自动重发。'
        $script:RunReport.Submitted++
        $script:PendingCandidateId=$null
        Set-RpaProgress 'Submitted'
    }catch{
        Set-ReplySubmissionStatus $Candidate.CandidateId 'Unknown' $_.Exception.Message
        $script:PendingCandidateId=$null
        throw
    }
    $challenge=Get-DouyinChallenge
    if($challenge){Wait-DouyinHumanGate $challenge}
}
function Invoke-ReplyBatch {
    foreach($candidate in $Config.Replies){
        Wait-RpaDelay 0
        if(Test-ReplyAlreadyContacted $candidate){$script:RunReport.Skipped++;continue}
        $script:RunReport['LastCandidateId']=$candidate.CandidateId
        $script:RunReport['LastVideoId']=$candidate.VideoId
        $script:VideoEvidence=Join-Path $script:RunDirectory $candidate.CandidateId
        $null=New-Item -ItemType Directory -Path $script:VideoEvidence -Force
        Write-RpaStateJson $candidate (Join-Path $script:VideoEvidence 'target.json')
        Set-RpaProgress 'OpeningReplyTarget'
        $card=Open-ReplyTarget $candidate
        Save-DouyinEvidence 'target-verified'
        if($Config.Mode -eq 'Preview'){
            $script:RunReport.Previewed++
        }else{
            Set-RpaProgress 'PreparingReply'
            Write-ReplyDraft $candidate $card
            Save-DouyinEvidence 'draft-verified'
            Submit-ReplyDraft $candidate
        }
        $script:RunReport.Processed++
        Set-RpaProgress 'TargetCompleted'
    }
}
