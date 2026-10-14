# 纯离线解析：调用方提供按 UIA ControlView 展开的节点与 Get-ReplyIdentityHash。
# 只识别 videoSideCard 的直接孩子，不合并嵌套回复的控件或读取地域用于筛选。
function Get-ReplyRecipientLabel {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Nodes)
    if($Nodes.Count -gt 10000){return $null}
    $indices=@{}
    foreach($node in $Nodes){
        if($null -eq $node -or $node.Index -isnot [ValueType] -or $node.Index -is [bool] -or $node.Parent -isnot [ValueType] -or $node.Parent -is [bool]){return $null}
        $index=[int]$node.Index
        if($index -lt 0 -or [double]$node.Index -ne $index -or [double]$node.Parent -ne [Math]::Truncate([double]$node.Parent) -or $indices.ContainsKey($index)){return $null}
        $indices[$index]=$true
    }
    $cards=@($Nodes | Where-Object {$_.Id -ceq 'videoSideCard' -and -not $_.Offscreen})
    if($cards.Count -ne 1){return $null}
    $footers=@($Nodes | Where-Object {$_.Parent -eq $cards[0].Index -and $_.Type -ceq 'ControlType.Group' -and ([string]$_.Class -split '\s+') -ccontains 'ZWk5Ao93'})
    if($footers.Count -ne 1 -or $footers[0].Offscreen){return $null}
    $children=@($Nodes | Where-Object {$_.Parent -eq $footers[0].Index} | Sort-Object {[int]$_.Index})
    $inputs=@($children | Where-Object {$_.Type -ceq 'ControlType.Group' -and ([string]$_.Class -split '\s+') -ccontains 'comment-input-inner-container'})
    if($inputs.Count -ne 1 -or $inputs[0].Offscreen){return $null}
    $label=New-Object Text.StringBuilder
    $started=$false;$closed=$false;$inputReached=$false
    foreach($node in $children){
        # 窄侧栏会把提示尾部的表情裁出可见区域，但 UIA 仍保留同一页脚下的完整名称。
        # 只允许这种已识别的表情节点屏外读取；提示文字、关闭按钮与输入区仍必须可见。
        $isEmoji=($node.Type -ceq 'ControlType.Image' -and ([string]$node.Class -split '\s+') -ccontains 'qz6Hz920')
        if($node.Offscreen -and -not $isEmoji){return $null}
        if($node.Index -eq $inputs[0].Index){
            if(-not $started -or -not $closed){return $null}
            $inputReached=$true;continue
        }
        # 回复提示、关闭图标、输入容器必须是唯一的一组直接孩子。
        if($inputReached -or $closed){return $null}
        if($node.Type -ceq 'ControlType.Text'){
            $part=[string]$node.Name
            if(-not $started){if(-not $part.StartsWith('回复@',[StringComparison]::Ordinal)){return $null};$started=$true}
            elseif($part.StartsWith('回复@',[StringComparison]::Ordinal)){return $null}
            $null=$label.Append($part)
        }elseif($isEmoji){
            if(-not $started -or [string]::IsNullOrWhiteSpace($node.Name)){return $null}
            $null=$label.Append([string]$node.Name)
        }elseif($node.Type -ceq 'ControlType.Image' -and ([string]$node.Class -split '\s+') -ccontains 'DADTc4UZ'){
            if(-not $started -or -not [string]::IsNullOrEmpty($node.Name)){return $null}
            $closed=$true
        }else{return $null}
    }
    if(-not $inputReached -or -not $label.ToString().StartsWith('回复@',[StringComparison]::Ordinal)){return $null}
    return $label.ToString()
}
function ConvertTo-ReplyAuthorUrl([string]$Address) {
    if($Address -match '[\p{Cc}]' -or $Address -notmatch '^(?:https://)?(?:www\.)?douyin\.com/user/([A-Za-z0-9_-]+)/?$'){return $null}
    return 'https://www.douyin.com/user/'+$Matches[1]
}
function Test-ReplyTimestampText([string]$Text) {
    # 仅取时间前缀作结构边界；分隔符之后的信息不进入候选或决策。
    $time=($Text -split '[·•]',2)[0].Trim()
    return ($time -match '^(?:刚刚|\d+(?:秒|分钟|小时|天|周|个月|月|年)前|(?:今天|昨天|前天)(?:\s+\d{1,2}:\d{2})?|(?:\d{4}[-/.])?\d{1,2}[-/.]\d{1,2}(?:\s+\d{1,2}:\d{2})?|\d{1,2}月\d{1,2}日(?:\s+\d{1,2}:\d{2})?)$')
}
function ConvertFrom-ReplyCommentNodes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Nodes,
        [Parameter(Mandatory=$true)][string]$VideoId,
        [Parameter(Mandatory=$true)][string]$VideoTitle,
        [Parameter(Mandatory=$true)][string]$VideoUrl
    )
    if($VideoId -notmatch '^\d{19}$' -or $VideoUrl -notmatch '^https://www\.douyin\.com/(?:video/(\d{19})/?|jingxuan/?\?modal_id=(\d{19}))$'){throw '评论解析需要明确的抖音视频地址与编号。'}
    $addressId=if($Matches[1]){$Matches[1]}else{$Matches[2]}
    if($addressId -cne $VideoId -or [string]::IsNullOrWhiteSpace($VideoTitle)){throw '视频地址、编号或标题不一致。'}
    if($Nodes.Count -gt 10000){throw '评论控件快照超出数量上限。'}
    $indices=@{};$markerCounts=@{}
    foreach($node in $Nodes){
        if($null -eq $node -or $node.Index -isnot [ValueType] -or $node.Index -is [bool] -or $node.Parent -isnot [ValueType] -or $node.Parent -is [bool]){return}
        $index=[int]$node.Index
        if($index -lt 0 -or [double]$node.Index -ne $index -or [double]$node.Parent -ne [Math]::Truncate([double]$node.Parent) -or $indices.ContainsKey($index)){return}
        $indices[$index]=$true
        if([string]$node.Id -match '^tooltip_\d{19}$'){
            if(-not $markerCounts.ContainsKey($node.Id)){$markerCounts[$node.Id]=0}
            $markerCounts[$node.Id]++
        }
    }
    $cards=@($Nodes | Where-Object {$_.Id -ceq 'videoSideCard' -and -not $_.Offscreen})
    if($cards.Count -ne 1){return}
    $children=@($Nodes | Where-Object {$_.Parent -eq $cards[0].Index} | Sort-Object {[int]$_.Index})
    $markerPositions=@(for($position=0;$position -lt $children.Count;$position++){
        # 无效 tooltip 也截断上一条，防止其正文混入其他评论。
        if([string]$children[$position].Id -like 'tooltip_*'){$position}
    })
    for($ordinal=0;$ordinal -lt $markerPositions.Count;$ordinal++){
        $position=$markerPositions[$ordinal];$marker=$children[$position]
        if($marker.Type -cne 'ControlType.Group' -or $marker.Id -notmatch '^tooltip_(\d{19})$'){continue}
        $commentId=$Matches[1]
        if($markerCounts[$marker.Id] -ne 1){continue}
        $prefixStart=if($ordinal -gt 0){$markerPositions[$ordinal-1]+1}else{0}
        $segmentEnd=if($ordinal+1 -lt $markerPositions.Count){$markerPositions[$ordinal+1]}else{$children.Count}
        $authors=@(for($i=$prefixStart;$i -lt $position;$i++){
            $node=$children[$i]
            if($node.Type -cne 'ControlType.Hyperlink' -or [string]::IsNullOrWhiteSpace($node.Name) -or $node.Name -match '头像$'){continue}
            $url=ConvertTo-ReplyAuthorUrl $node.Value
            if($url){[pscustomobject]@{Name=[string]$node.Name;Url=$url;NodeIndex=[int]$node.Index}}
        })
        if($authors.Count -ne 1){continue}
        $timestampPositions=@();$replyPositions=@()
        for($i=$position+1;$i -lt $segmentEnd;$i++){
            $node=$children[$i]
            if($node.Type -ceq 'ControlType.Text' -and (Test-ReplyTimestampText $node.Name)){$timestampPositions+=$i}
            if($node.Type -ceq 'ControlType.Group' -and ([string]$node.Class -split '\s+') -ccontains 'LJU9cDNW'){$replyPositions+=$i}
        }
        if($timestampPositions.Count -ne 1 -or $replyPositions.Count -ne 1 -or $replyPositions[0] -le $timestampPositions[0]){continue}
        $text=New-Object Text.StringBuilder
        $malformed=$false;$bodyIndices=New-Object 'Collections.Generic.List[int]'
        for($i=$position+1;$i -lt $timestampPositions[0];$i++){
            $node=$children[$i]
            if($node.Type -ceq 'ControlType.Text'){$null=$text.Append([string]$node.Name);$bodyIndices.Add([int]$node.Index)}
            elseif($node.Type -ceq 'ControlType.Image' -and ([string]$node.Class -split '\s+') -ccontains 'qz6Hz920'){
                if([string]::IsNullOrWhiteSpace($node.Name)){$malformed=$true;break}
                $null=$text.Append([string]$node.Name)
                $bodyIndices.Add([int]$node.Index)
            }elseif($node.Type -ceq 'ControlType.Hyperlink'){
                # 新作者、@链接等未确认结构不能被截断后冒充完整原评论。
                $malformed=$true;break
            }
        }
        $body=$text.ToString()
        if($malformed -or [string]::IsNullOrWhiteSpace($body) -or $body.Length -gt 10000 -or ($body -replace '[\r\n\t]','') -match '[\p{Cc}]'){continue}
        $author=$authors[0]
        [pscustomobject]@{
            CandidateId=(Get-ReplyIdentityHash ($VideoId+'|'+$commentId))
            AuthorKey=(Get-ReplyIdentityHash $author.Url)
            CommentId=$commentId;VideoId=$VideoId;VideoTitle=$VideoTitle;VideoUrl=$VideoUrl
            AuthorName=$author.Name;AuthorUrl=$author.Url;Text=$body
            AuthorNodeIndex=[int]$author.NodeIndex;BodyNodeIndices=$bodyIndices.ToArray()
            ReplyNodeIndex=[int]$children[$replyPositions[0]].Index;MarkerNodeIndex=[int]$marker.Index
        }
    }
}
