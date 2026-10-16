[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$skillRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $skillRoot 'src\core\Reply.Configuration.ps1')
. (Join-Path $skillRoot 'src\core\Reply.Parsing.ps1')
$script:ParsingCases=0
function Assert-Parsing([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:ParsingCases++}
function New-FixtureNode([int]$Index,[int]$Parent,[string]$Type,[string]$Name='', [string]$Id='', [string]$Class='', [string]$Value='', [bool]$Offscreen=$false){
    return [pscustomobject]@{Index=$Index;Parent=$Parent;Type=('ControlType.'+$Type);Name=$Name;Id=$Id;Class=$Class;Value=$Value;Offscreen=$Offscreen;Bounds='0,0,100,20'}
}
function New-FixtureComment([int]$Start,[string]$CommentId='1234567890123456701',[string]$Author='示例用户',[string]$Body="想找动漫资源`n哪里能免费看？🤔",[string]$Url='https://www.douyin.com/user/example_a/'){
    New-FixtureNode $Start 0 'Hyperlink' ($Author+'头像') -Value $Url
    New-FixtureNode ($Start+1) 0 'Hyperlink' $Author -Value $Url
    New-FixtureNode ($Start+2) 0 'Group' -Id ('tooltip_'+$CommentId) -Class 'fBKZfpyn'
    New-FixtureNode ($Start+3) 0 'Text' $Body
    New-FixtureNode ($Start+4) 0 'Image' '[捂脸]' -Class 'qz6Hz920'
    New-FixtureNode ($Start+5) 0 'Text' '2周前·测试地域'
    New-FixtureNode ($Start+6) 0 'Group' -Class 'VpA2NKl1'
    New-FixtureNode ($Start+7) 0 'Group' -Class 'before LJU9cDNW after'
    New-FixtureNode ($Start+8) ($Start+7) 'Text' '回复'
}
function Read-Fixture([object[]]$Nodes){
    return @(ConvertFrom-ReplyCommentNodes -Nodes $Nodes -VideoId '1234567890123456789' -VideoTitle '动漫片段' -VideoUrl 'https://www.douyin.com/video/1234567890123456789')
}
function Copy-Fixture([object[]]$Nodes){return @($Nodes | ConvertTo-Json -Depth 8 | ConvertFrom-Json)}
$card=New-FixtureNode 0 -1 'Group' -Id 'videoSideCard'
$single=@($card)+@(New-FixtureComment 10)
$first=@(Read-Fixture $single)
Assert-Parsing ($first.Count -eq 1) '标准扁平评论未解析。'
Assert-Parsing ($first[0].Text -ceq "想找动漫资源`n哪里能免费看？🤔[捂脸]") '正文换行或表情没有逐字保留。'
Assert-Parsing ($first[0].AuthorName -ceq '示例用户' -and $first[0].AuthorUrl -ceq 'https://www.douyin.com/user/example_a') '头像被选作作者，或作者地址未规范化。'
Assert-Parsing ($first[0].CandidateId -ceq (Get-ReplyIdentityHash '1234567890123456789|1234567890123456701') -and $first[0].AuthorKey -ceq (Get-ReplyIdentityHash 'https://www.douyin.com/user/example_a')) '候选或用户哈希与核心契约不符。'
Assert-Parsing ($first[0].ReplyNodeIndex -eq 17 -and $first[0].MarkerNodeIndex -eq 12) '回复或评论标记定位索引错误。'
Assert-Parsing ($first[0].AuthorNodeIndex -eq 11 -and (($first[0].BodyNodeIndices -join ',') -ceq '13,14')) '原作者或正文、表情的实时可视核验索引未保留。'
Assert-ReplyCandidate $first[0]
$sameText=@($single)+@(New-FixtureComment 30 -CommentId '1234567890123456702' -Author '另一用户' -Url 'https://douyin.com/user/example_b')
$both=@(Read-Fixture $sameText)
Assert-Parsing ($both.Count -eq 2 -and $both[0].Text -ceq $both[1].Text -and $both[0].CandidateId -cne $both[1].CandidateId) '相同文字但不同评论编号被合并。'
$nested=@($single)+@(
    (New-FixtureNode 100 12 'Group' -Id 'tooltip_1234567890123456709'),
    (New-FixtureNode 101 100 'Text' '嵌套回复不能串入父评论'),
    (New-FixtureNode 102 100 'Group' -Class 'LJU9cDNW')
)
$parsedNested=@(Read-Fixture $nested)
Assert-Parsing ($parsedNested.Count -eq 1 -and $parsedNested[0].Text -ceq $first[0].Text) '嵌套回复被拼接到父评论或改变了父回复按钮。'
$inlineNested=@($single)+@(New-FixtureComment 30 -CommentId '1234567890123456702' -Author '作者对上一条的回复' -Body '独立回复正文' -Url 'https://www.douyin.com/user/example_b')
$inlineParsed=@(Read-Fixture $inlineNested)
Assert-Parsing ($inlineParsed.Count -eq 2 -and $inlineParsed[0].Text -ceq $first[0].Text) '同级展开回复被合并进上一条。'
foreach($case in @('missing-author','missing-marker','missing-reply','missing-body','duplicate-marker','two-replies','two-authors','missing-time','ambiguous-time','duplicate-index','invalid-author-url','empty-emoji','two-cards')){
    $nodes=Copy-Fixture $single
    switch($case){
        'missing-author' {$nodes=@($nodes | Where-Object {$_.Index -ne 11})}
        'missing-marker' {$nodes=@($nodes | Where-Object {$_.Index -ne 12})}
        'missing-reply' {$nodes=@($nodes | Where-Object {$_.Index -ne 17})}
        'missing-body' {$nodes=@($nodes | Where-Object {$_.Index -notin @(13,14)})}
        'duplicate-marker' {$nodes+=New-FixtureNode 90 0 'Group' -Id 'tooltip_1234567890123456701'}
        'two-replies' {$nodes+=New-FixtureNode 90 0 'Group' -Class 'LJU9cDNW'}
        'two-authors' {$nodes+=New-FixtureNode 9 0 'Hyperlink' '多出的作者' -Value 'https://www.douyin.com/user/other'}
        'missing-time' {$nodes=@($nodes | Where-Object {$_.Index -ne 15})}
        'ambiguous-time' {$nodes+=New-FixtureNode 90 0 'Text' '昨天'}
        'duplicate-index' {$nodes+=New-FixtureNode 13 0 'Text' '重复索引'}
        'invalid-author-url' {($nodes | Where-Object {$_.Index -eq 11}).Value='https://www.douyin.com.evil.invalid/user/example_a'}
        'empty-emoji' {($nodes | Where-Object {$_.Index -eq 14}).Name=''}
        'two-cards' {$nodes+=New-FixtureNode 90 -1 'Group' -Id 'videoSideCard'}
    }
    Assert-Parsing (@(Read-Fixture $nodes).Count -eq 0) ('不确定结构没有拒绝：'+$case)
}
$duplicated=@($single)+@(New-FixtureComment 30)
Assert-Parsing (@(Read-Fixture $duplicated).Count -eq 0) '重复评论编号仍生成可发送候选。'
$changedRegion=Copy-Fixture $single
($changedRegion | Where-Object {$_.Index -eq 15}).Name='2周前·任意其他字符串'
$regionOutput=@(Read-Fixture $changedRegion)
Assert-Parsing (($regionOutput | ConvertTo-Json -Compress) -ceq ($first | ConvertTo-Json -Compress)) '时间后的地域改变了正文、身份或筛选结果。'
$offscreen=Copy-Fixture $single
foreach($node in $offscreen){if($node.Index -gt 0){$node.Offscreen=$true}}
Assert-Parsing (@(Read-Fixture $offscreen).Count -eq 1) '已加载的屏外评论未保留为候选，UI 层应另行校验发送可见性。'
$shuffled=@($single | Sort-Object Index -Descending)
Assert-Parsing ((@(Read-Fixture $shuffled)[0].Text) -ceq $first[0].Text) '扁平节点输入顺序改变了同级控件语序。'
$noNodes=@(Read-Fixture @())
Assert-Parsing ($noNodes.Count -eq 0) '空控件快照不应生成候选。'
$recipientNodes=@(
    (New-FixtureNode 0 -1 'Group' -Id 'videoSideCard'),
    (New-FixtureNode 200 0 'Group' -Class 'ZWk5Ao93 _do0yNAa'),
    (New-FixtureNode 201 200 'Text' '回复@一只鱼'),
    (New-FixtureNode 202 200 'Image' '🐟' -Class 'qz6Hz920'),
    (New-FixtureNode 203 200 'Text' ': 这个课能学到AI动画吗，我对那个感兴趣'),
    (New-FixtureNode 204 200 'Image' -Class 'DADTc4UZ'),
    (New-FixtureNode 205 200 'Group' -Class 'McY63d8B comment-input-inner-container a34WqUnp')
)
Assert-Parsing ((Get-ReplyRecipientLabel -Nodes $recipientNodes) -ceq '回复@一只鱼🐟: 这个课能学到AI动画吗，我对那个感兴趣') '回复提示没有正确拼接表情姓名。'
$clippedEmojiNodes=@(
    (New-FixtureNode 0 -1 'Group' -Id 'videoSideCard'),
    (New-FixtureNode 200 0 'Group' -Class 'ZWk5Ao93'),
    (New-FixtureNode 201 200 'Text' '回复@示例用户: 这部动漫的后几集哪里能看'),
    (New-FixtureNode 202 200 'Image' '[捂脸]' -Class 'qz6Hz920' -Offscreen $true),
    (New-FixtureNode 203 200 'Image' '[捂脸]' -Class 'qz6Hz920' -Offscreen $true),
    (New-FixtureNode 204 200 'Image' '[捂脸]' -Class 'qz6Hz920' -Offscreen $true),
    (New-FixtureNode 205 200 'Image' -Class 'DADTc4UZ'),
    (New-FixtureNode 206 200 'Group' -Class 'comment-input-inner-container')
)
Assert-Parsing ((Get-ReplyRecipientLabel -Nodes $clippedEmojiNodes) -ceq '回复@示例用户: 这部动漫的后几集哪里能看[捂脸][捂脸][捂脸]') '侧栏裁切的尾部表情使完整回复提示无法重建。'
foreach($case in @('hidden-header','hidden-close','hidden-input','unknown-clipped-image','empty-clipped-emoji','emoji-outside-footer')){
    $nodes=Copy-Fixture $clippedEmojiNodes
    switch($case){
        'hidden-header' {($nodes | Where-Object {$_.Index -eq 201}).Offscreen=$true}
        'hidden-close' {($nodes | Where-Object {$_.Index -eq 205}).Offscreen=$true}
        'hidden-input' {($nodes | Where-Object {$_.Index -eq 206}).Offscreen=$true}
        'unknown-clipped-image' {($nodes | Where-Object {$_.Index -eq 202}).Class='unknown-image'}
        'empty-clipped-emoji' {($nodes | Where-Object {$_.Index -eq 202}).Name=''}
        'emoji-outside-footer' {($nodes | Where-Object {$_.Index -eq 202}).Parent=0}
    }
    $label=Get-ReplyRecipientLabel -Nodes $nodes
    if($case -eq 'emoji-outside-footer'){
        Assert-Parsing ($label -ceq '回复@示例用户: 这部动漫的后几集哪里能看[捂脸][捂脸]') '回复提示混入页脚外的表情，可能掩盖正文不一致。'
    }else{Assert-Parsing ($null -eq $label) ('裁切兼容误接受不确定回复提示：'+$case)}
}
$plainHeader=Copy-Fixture $recipientNodes
$plainHeader=@($plainHeader | Where-Object {$_.Index -notin @(202,203)})
($plainHeader | Where-Object {$_.Index -eq 201}).Name="回复@普通用户: 第一行`n第二行🤔"
Assert-Parsing ((Get-ReplyRecipientLabel -Nodes $plainHeader) -ceq "回复@普通用户: 第一行`n第二行🤔") '普通提示或正文换行表情未原样保留。'
foreach($case in @('duplicate-footer','hidden-footer','duplicate-input','missing-input','unknown-image','empty-emoji','duplicate-header','duplicate-close','missing-close','unknown-group','missing-prefix','hidden-label','duplicate-index','second-visible-card')){
    $nodes=Copy-Fixture $recipientNodes
    switch($case){
        'duplicate-footer' {$nodes+=New-FixtureNode 300 0 'Group' -Class 'ZWk5Ao93'}
        'hidden-footer' {($nodes | Where-Object {$_.Index -eq 200}).Offscreen=$true}
        'duplicate-input' {$nodes+=New-FixtureNode 300 200 'Group' -Class 'comment-input-inner-container'}
        'missing-input' {$nodes=@($nodes | Where-Object {$_.Index -ne 205})}
        'unknown-image' {($nodes | Where-Object {$_.Index -eq 202}).Class='unknown-image'}
        'empty-emoji' {($nodes | Where-Object {$_.Index -eq 202}).Name=''}
        'duplicate-header' {($nodes | Where-Object {$_.Index -eq 203}).Name='回复@第二个用户: 另一条评论'}
        'duplicate-close' {$nodes+=New-FixtureNode 206 200 'Image' -Class 'DADTc4UZ'}
        'missing-close' {$nodes=@($nodes | Where-Object {$_.Index -ne 204})}
        'unknown-group' {($nodes | Where-Object {$_.Index -eq 202}).Type='ControlType.Group'}
        'missing-prefix' {($nodes | Where-Object {$_.Index -eq 201}).Name='一只鱼'}
        'hidden-label' {($nodes | Where-Object {$_.Index -eq 201}).Offscreen=$true}
        'duplicate-index' {$nodes+=New-FixtureNode 202 200 'Text' '不唯一'}
        'second-visible-card' {$nodes+=New-FixtureNode 300 -1 'Group' -Id 'videoSideCard'}
    }
    Assert-Parsing ($null -eq (Get-ReplyRecipientLabel -Nodes $nodes)) ('不确定回复提示结构未拒绝：'+$case)
}
[pscustomobject]@{Status='Passed';ParsingCases=$script:ParsingCases;MultilineAndEmoji=$true;StableCommentIdentity=$true;AmbiguousTargetsRejected=$true;NestedRepliesIsolated=$true;RecipientLabelReconstructed=$true;RegionIgnored=$true;DesktopActions=0}
