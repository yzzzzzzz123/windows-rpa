function Get-ReplyControlNodes($Root) {
    $walker=[System.Windows.Automation.TreeWalker]::ControlViewWalker
    $queue=New-Object 'Collections.Generic.Queue[object]'
    $queue.Enqueue(@{Element=$Root;Parent=-1})
    $nodes=New-Object 'Collections.Generic.List[object]'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($queue.Count -gt 0){
        Assert-RpaRunning
        if($nodes.Count % 25 -eq 0){Assert-DouyinIdentity}
        if($nodes.Count -ge 3000 -or $timer.Elapsed.TotalSeconds -gt 30){throw '评论控件读取超出范围，拒绝使用不完整快照。'}
        $next=$queue.Dequeue();$element=$next.Element;$current=$element.Current;$index=$nodes.Count
        $nodes.Add([pscustomobject]@{Index=$index;Parent=$next.Parent;Name=$current.Name;Type=$current.ControlType.ProgrammaticName;Class=$current.ClassName;Id=$current.AutomationId;Value=(Get-UiaValue $element);Offscreen=$current.IsOffscreen;Bounds=$current.BoundingRectangle.ToString();Element=$element})
        $child=$walker.GetFirstChild($element)
        while($child){
            Assert-RpaRunning
            if($queue.Count+$nodes.Count -ge 3000 -or $timer.Elapsed.TotalSeconds -gt 30){throw '评论控件读取超出范围，拒绝使用不完整快照。'}
            $queue.Enqueue(@{Element=$child;Parent=$index});$child=$walker.GetNextSibling($child)
        }
    }
    return $nodes.ToArray()
}
function Get-ReplySnapshot($Video) {
    Ensure-DouyinForeground
    $card=Get-CommentCard
    if(-not $card){throw '评论区不可见。'}
    $nodes=@(Get-ReplyControlNodes $card)
    $candidates=@(ConvertFrom-ReplyCommentNodes -Nodes $nodes -VideoId $Video.VideoId -VideoTitle $Video.Title -VideoUrl ('https://www.douyin.com/video/'+$Video.VideoId))
    return [pscustomobject]@{Card=$card;Nodes=$nodes;Candidates=$candidates}
}
function Get-ReplyPlainCandidate($Candidate) {
    return $Candidate | Select-Object CandidateId,AuthorKey,CommentId,VideoId,VideoTitle,VideoUrl,AuthorName,AuthorUrl,Text
}
function Assert-ReplyTargetMatch($Expected,$Actual) {
    foreach($name in @('CandidateId','CommentId','VideoId','AuthorKey','AuthorUrl','AuthorName','Text')){
        if($Expected.$name -cne $Actual.$name){throw ('原评论或作者已变化：'+$name+'；停止回复。')}
    }
}
function Move-ReplyCommentPanel($Card,[int]$Notches) {
    Ensure-DouyinForeground
    if(-not (Test-UiaInBrowser $Card)){throw '评论滚动区域不可见。'}
    $b=$Card.Current.BoundingRectangle
    [DingRpa]::WheelNotches($script:BrowserHandle,[int]($b.Left+$b.Width*0.7),[int]($b.Top+$b.Height*0.45),$Notches)
    Wait-RpaDelay 0.5
}
function Get-ReplyInputAnchor($Card) {
    # 未激活的空输入区只暴露 placeholder；点击具体评论回复后才出现编辑器。
    $editors=@($Card.FindAll([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty,$Config.Selectors.EditorClass))) | Where-Object {Test-UiaInBrowser $_})
    if($editors.Count -gt 1){throw '评论编辑器不唯一。'}
    if($editors.Count -eq 1){return [pscustomobject]@{Element=$editors[0];Editor=$editors[0]}}
    $placeholders=@(Find-DouyinNamed $Config.Selectors.Placeholder $Card)
    if($placeholders.Count -ne 1){throw '没有唯一的空评论占位区或编辑器。'}
    return [pscustomobject]@{Element=$placeholders[0];Editor=$null}
}
function Get-ReplyFooterTop($InputElement) {
    $walker=[System.Windows.Automation.TreeWalker]::ControlViewWalker;$node=$InputElement
    for($depth=0;$depth -lt 12;$depth++){
        $parent=$walker.GetParent($node)
        if(-not $parent){break}
        if($parent.Current.AutomationId -ceq $Config.Selectors.CommentCardAutomationId){return $node.Current.BoundingRectangle.Top}
        $node=$parent
    }
    throw '输入区不属于已确认的评论侧栏。'
}
function Assert-ReplyInputEmpty($Card) {
    $inputState=Get-ReplyInputAnchor $Card
    if($inputState.Editor){
        $value=Get-UiaValue $inputState.Editor
        if($null -eq $value -or $value.Trim().Length -ne 0){throw '评论框已有草稿或内容不可读取，停止输入。'}
    }
}
function Find-ReplyLiveTarget($Candidate,[switch]$RequireVisible) {
    $video=[pscustomobject]@{VideoId=$Candidate.VideoId;Title=$Candidate.VideoTitle}
    $snapshot=Get-ReplySnapshot $video
    $found=@($snapshot.Candidates | Where-Object {$_.CommentId -ceq $Candidate.CommentId})
    if($found.Count -ne 1){return $null}
    Assert-ReplyTargetMatch $Candidate $found[0]
    $replyNode=@($snapshot.Nodes | Where-Object {$_.Index -eq $found[0].ReplyNodeIndex})
    if($replyNode.Count -ne 1){throw '回复按钮引用不唯一。'}
    $element=$replyNode[0].Element
    $live=[pscustomobject]@{Snapshot=$snapshot;Candidate=$found[0];ReplyElement=$element}
    if($RequireVisible -and -not (Test-ReplyTargetVisible $live)){return $null}
    return $live
}
function Get-ReplyCommentViewport($Live) {
    $panel=$Live.Snapshot.Card.Current.BoundingRectangle
    $markers=@($Live.Snapshot.Nodes | Where-Object {$_.Id -match '^tooltip_\d{19}$'} | Sort-Object Index)
    if($markers.Count -eq 0){throw '缺少原评论边界，无法确认评论列表可视区域。'}
    # videoSideCard 包含固定的标签页、搜索提示和评论数量，不能把整个侧栏当作列表视口。
    $headers=@($Live.Snapshot.Nodes | Where-Object {$_.Index -lt $markers[0].Index -and $_.Type -ceq 'ControlType.Text' -and ([string]$_.Name).StartsWith('全部评论(',[StringComparison]::Ordinal)})
    if($headers.Count -ne 1 -or -not (Test-UiaInBrowser $headers[0].Element)){throw '无法确认唯一可见的评论列表标题。'}
    $inputState=Get-ReplyInputAnchor $Live.Snapshot.Card;$footer=Get-ReplyFooterTop $inputState.Element
    $top=[Math]::Max($panel.Top,$headers[0].Element.Current.BoundingRectangle.Bottom)
    $bottom=[Math]::Min($panel.Bottom,$footer)
    if($bottom -le $top){throw '评论列表没有可核验的可视区域。'}
    return [pscustomobject]@{Left=$panel.Left;Right=$panel.Right;Top=$top;Bottom=$bottom}
}
function Get-ReplyTargetContentElements($Live) {
    $author=@($Live.Snapshot.Nodes | Where-Object {$_.Index -eq $Live.Candidate.AuthorNodeIndex})
    $bodyIndices=@($Live.Candidate.BodyNodeIndices)
    $body=@($Live.Snapshot.Nodes | Where-Object {$_.Index -in $bodyIndices})
    if($author.Count -ne 1 -or $bodyIndices.Count -eq 0 -or $body.Count -ne $bodyIndices.Count){throw '原评论作者或正文控件引用不完整。'}
    return @($author[0].Element)+@($body | ForEach-Object {$_.Element})
}
function Test-ReplyTargetVisible($Live) {
    $viewport=Get-ReplyCommentViewport $Live
    foreach($element in @($Live.ReplyElement)+@(Get-ReplyTargetContentElements $Live)){
        if(-not (Test-UiaInBrowser $element)){return $false}
        $bounds=$element.Current.BoundingRectangle
        if($bounds.Left -lt $viewport.Left -or $bounds.Right -gt $viewport.Right -or $bounds.Top -lt $viewport.Top -or $bounds.Bottom -gt $viewport.Bottom){return $false}
    }
    return $true
}
function Get-ReplyTargetScrollNotches($Live) {
    $viewport=Get-ReplyCommentViewport $Live
    $elements=@($Live.ReplyElement)+@(Get-ReplyTargetContentElements $Live)
    $top=($elements | ForEach-Object {$_.Current.BoundingRectangle.Top} | Measure-Object -Minimum).Minimum
    $bottom=($elements | ForEach-Object {$_.Current.BoundingRectangle.Bottom} | Measure-Object -Maximum).Maximum
    if($top -lt $viewport.Top){return 1}
    if($bottom -gt $viewport.Bottom){return -1}
    throw '目标控件不可见，无法根据实时边界确定安全滚动方向。'
}
function Restore-ReplyDraftTargetVisibility($Candidate) {
    # 输入后页脚会增高并遮住原评论。只滚动列表恢复可视范围，不重选收件人或改写草稿。
    for($round=0;$round -le 8;$round++){
        Wait-RpaDelay 0
        Ensure-DouyinForeground
        $card=Get-CommentCard
        if(-not $card){throw '回复输入后评论区不可用，停止发送。'}
        $editor=Get-CommentEditor $card
        if(-not $editor.Current.HasKeyboardFocus -or (Get-UiaValue $editor) -cne $Candidate.ReplyText){throw '恢复原评论可见性前焦点或草稿已变化，停止发送。'}
        $live=Find-ReplyLiveTarget $Candidate
        if(-not $live){throw '回复输入后原评论已不能唯一定位，停止发送。'}
        if(Test-ReplyTargetVisible $live){return}
        if($round -eq 8){throw '回复输入后无法在限定滚动内恢复原评论完整可见，停止发送。'}
        $viewport=Get-ReplyCommentViewport $live
        $bounds=$card.Current.BoundingRectangle
        $wheelY=$bounds.Top+$bounds.Height*0.45
        if($wheelY -le $viewport.Top -or $wheelY -ge $viewport.Bottom){throw '评论滚动落点不在列表可视区域，停止发送。'}
        $notches=Get-ReplyTargetScrollNotches $live
        Move-ReplyCommentPanel $card $notches
    }
}
function Assert-ReplyRecipient($Candidate,$Card) {
    Ensure-DouyinForeground
    $live=Find-ReplyLiveTarget $Candidate
    if(-not $live){throw '原评论已不能唯一定位，禁止输入或发送。'}
    $selected=@(Find-DouyinNamed '回复中' $live.ReplyElement)
    if($selected.Count -ne 1){throw '当前选中的回复按钮不属于目标评论。'}
    $label=Get-ReplyRecipientLabel -Nodes $live.Snapshot.Nodes
    $expected='回复@'+$Candidate.AuthorName+': '+$Candidate.Text
    # 抖音将 emoji 渲染为图片并裁掉相邻空白；完整原评论仍由上面的 ID/URL/逐字比对约束。
    if(-not $label -or ($label -replace '\s','') -cne ($expected -replace '\s','')){throw '回复对象提示与作者、原评论全文不一致，禁止发送。'}
    return $live
}
function Save-ReplyTargetEvidence($Candidate,$Live) {
    $trace=[ordered]@{
        CapturedAt=(Get-Date -Format o)
        Expected=(Get-ReplyPlainCandidate $Candidate)
        Actual=(Get-ReplyPlainCandidate $Live.Candidate)
        ReplyBounds=$Live.ReplyElement.Current.BoundingRectangle.ToString()
        PanelBounds=$Live.Snapshot.Card.Current.BoundingRectangle.ToString()
        Window=([DingRpa]::ReadWindow($script:BrowserHandle))
        Nodes=@($Live.Snapshot.Nodes | Select-Object Index,Parent,Name,Type,Class,Id,Value,Offscreen,Bounds)
    }
    Write-RpaStateJson $trace (Join-Path $script:VideoEvidence 'reply-before-click-target.json')
    Save-DouyinEvidence 'reply-before-click'
}
function Open-ReplyTarget($Candidate) {
    $video=[pscustomobject]@{VideoId=$Candidate.VideoId;Title=$Candidate.VideoTitle;Url=$Candidate.VideoUrl}
    # 独立回复任务会重新初始化浏览器；从实时地址重建绑定，复用同一视频而不刷新。
    Ensure-DouyinForeground
    $currentVideoId=Get-DouyinVideoId (Get-UiaValue (Get-DouyinAddressElement))
    if($currentVideoId -ceq $Candidate.VideoId){
        $script:ExpectedVideoId=$Candidate.VideoId
        Ensure-DouyinForeground
        $card=Get-CommentCard
        if(-not $card){throw '当前视频没有唯一可复用的评论侧栏，停止回复且不刷新页面。'}
    }else{
        $card=Open-DouyinComments $video
    }
    Assert-ReplyInputEmpty $card
    for($round=0;$round -lt 40;$round++){
        Wait-RpaDelay 0
        $live=Find-ReplyLiveTarget $Candidate
        if($live -and (Test-ReplyTargetVisible $live)){
            Save-ReplyTargetEvidence $Candidate $live
            # 截图和控件采集期间页面可能完成滚动或重新排版，点击前重读原评论身份与位置。
            $live=Find-ReplyLiveTarget $Candidate
            if(-not $live -or -not (Test-ReplyTargetVisible $live)){throw '选择回复前原评论位置已变化，未点击、输入或发送。'}
            if(@(Find-DouyinNamed '回复' $live.ReplyElement).Count -ne 1){throw '目标回复入口不是可点击的回复状态。'}
            Invoke-DouyinClick $live.ReplyElement
            Wait-RpaDelay 0.4
            $card=Get-CommentCard
            $null=Assert-ReplyRecipient $Candidate $card
            Assert-ReplyInputEmpty $card
            return $card
        }
        $notches=-1
        if($live){$notches=Get-ReplyTargetScrollNotches $live}
        Move-ReplyCommentPanel $card $notches
        $card=Get-CommentCard
    }
    throw '限定滚动范围内无法定位目标评论，未输入或发送。'
}
