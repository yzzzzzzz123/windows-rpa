[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$skillRoot=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
. (Join-Path $skillRoot 'src\core\Reply.UI.ps1')
$script:Checks=0
$script:Config=[pscustomobject]@{Selectors=[pscustomobject]@{EditorClass='fixture-editor';Placeholder='留下你的精彩评论吧'}}
$script:Editors=@();$script:Placeholders=@()
function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
function Assert-Rejected([scriptblock]$Body,[string]$Message){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert-True $rejected $Message}
function New-FixtureElement([string]$Name,$Value,[bool]$Visible=$true){return [pscustomobject]@{Name=$Name;Value=$Value;Visible=$Visible}}
function Test-UiaInBrowser($Element){return [bool]$Element.Visible}
function Find-DouyinNamed([string]$Name,$Root){
    if($Name -cne $script:Config.Selectors.Placeholder -or $Root -ne $script:Card){throw '占位区查询脱离当前评论卡片。'}
    return $script:Placeholders
}
function Get-UiaValue($Element){return $Element.Value}
$script:Card=[pscustomobject]@{Name='fixture-comment-card'}
$script:Card|Add-Member ScriptMethod FindAll {
    param($Scope,$Condition)
    if($Scope -ne [System.Windows.Automation.TreeScope]::Descendants -or $Condition.Property -ne [System.Windows.Automation.AutomationElement]::ClassNameProperty -or $Condition.Value -cne $script:Config.Selectors.EditorClass){throw '编辑器查询没有使用指定类和当前卡片后代范围。'}
    return $script:Editors
}

# 真实页面中，未激活的空输入区只暴露占位文字，不暴露编辑器。
$placeholder=New-FixtureElement 'placeholder' $null
$script:Placeholders=@($placeholder)
$anchor=Get-ReplyInputAnchor $script:Card
Assert-True ($anchor.Element -eq $placeholder -and $null -eq $anchor.Editor) '单一占位文字未被识别为空输入区。'
Assert-ReplyInputEmpty $script:Card
Assert-True $true '未激活的单一占位区应通过空输入核验。'

$script:Placeholders=@()
Assert-Rejected {Assert-ReplyInputEmpty $script:Card} '没有占位文字也没有编辑器时错误地认为输入区为空。'
$script:Placeholders=@($placeholder,(New-FixtureElement 'second-placeholder' $null))
Assert-Rejected {Get-ReplyInputAnchor $script:Card} '多个占位区没有被拒绝。'

$emptyEditor=New-FixtureElement 'empty-editor' ''
$script:Editors=@($emptyEditor);$script:Placeholders=@()
$anchor=Get-ReplyInputAnchor $script:Card
Assert-True ($anchor.Editor -eq $emptyEditor -and $anchor.Element -eq $emptyEditor) '唯一编辑器未作为实际输入锚点。'
Assert-ReplyInputEmpty $script:Card
Assert-True $true '可读取的空编辑器未通过核验。'

$script:Editors=@($emptyEditor,(New-FixtureElement 'second-editor' ''))
Assert-Rejected {Assert-ReplyInputEmpty $script:Card} '多个可见编辑器没有被拒绝。'
$script:Editors=@((New-FixtureElement 'draft-editor' '用户尚未提交的草稿'))
Assert-Rejected {Assert-ReplyInputEmpty $script:Card} '已有草稿被错误当作空输入区。'
$script:Editors=@((New-FixtureElement 'unreadable-editor' $null))
Assert-Rejected {Assert-ReplyInputEmpty $script:Card} '不可读取的编辑器被错误当作空输入区。'

$script:Editors=@((New-FixtureElement 'hidden-editor' '隐藏草稿' $false));$script:Placeholders=@($placeholder)
$anchor=Get-ReplyInputAnchor $script:Card
Assert-True ($anchor.Element -eq $placeholder -and $null -eq $anchor.Editor) '不可见编辑器错误覆盖了当前可见占位区。'

$expected=[pscustomobject]@{CandidateId=('a'*64);CommentId='7000000000000000001';VideoId='7000000000000000002';AuthorKey=('b'*64);AuthorUrl='https://www.douyin.com/user/fixture';AuthorName='原作者';Text='想了解 AI 分镜与剪辑流程。'}
$actual=$expected|ConvertTo-Json|ConvertFrom-Json
Assert-ReplyTargetMatch $expected $actual
Assert-True $true '同一原评论身份应通过实时比对。'
foreach($change in @(@('CommentId','7000000000000000099'),@('AuthorUrl','https://www.douyin.com/user/other'),@('Text','已被替换成其他原评论。'))){
    $actual=$expected|ConvertTo-Json|ConvertFrom-Json
    $actual.($change[0])=$change[1]
    Assert-Rejected {Assert-ReplyTargetMatch $expected $actual} ('实时目标字段变化未被拒绝：'+$change[0])
}

# 评论按钮露在固定标题边缘时，作者和正文仍可能被遮挡；必须核验整个原评论。
function New-ViewportElement([string]$Bounds,[bool]$Visible=$true){return [pscustomobject]@{Visible=$Visible;Current=[pscustomobject]@{BoundingRectangle=[Windows.Rect]::Parse($Bounds)}}}
function Get-ReplyFooterTop($InputElement){return 564}
$script:Card|Add-Member NoteProperty Current ([pscustomobject]@{BoundingRectangle=[Windows.Rect]::Parse('842,226,269,388')})
$header=New-ViewportElement '854,295,50,17'
$author=New-ViewportElement '895,342,40,20'
$body=New-ViewportElement '895,366,158,17'
$emoji=New-ViewportElement '1053,366,16,17'
$replyElement=New-ViewportElement '892,409,37,17'
$script:Editors=@();$script:Placeholders=@($placeholder)
$viewportLive=[pscustomobject]@{
    ReplyElement=$replyElement
    Candidate=[pscustomobject]@{AuthorNodeIndex=87;BodyNodeIndices=@(89,90)}
    Snapshot=[pscustomobject]@{Card=$script:Card;Nodes=@(
        [pscustomobject]@{Index=5;Type='ControlType.Text';Name='全部评论(';Id='';Element=$header},
        [pscustomobject]@{Index=87;Type='ControlType.Hyperlink';Name='原作者';Id='';Element=$author},
        [pscustomobject]@{Index=88;Type='ControlType.Group';Name='';Id='tooltip_7000000000000000001'},
        [pscustomobject]@{Index=89;Type='ControlType.Text';Name='原评论正文';Id='';Element=$body},
        [pscustomobject]@{Index=90;Type='ControlType.Image';Name='[捂脸]';Id='';Element=$emoji}
    )}
}
Assert-True (Test-ReplyTargetVisible $viewportLive) '作者、正文和按钮完整可见时未通过目标核验。'
$author.Current.BoundingRectangle=[Windows.Rect]::Parse('895,242,40,20');$author.Visible=$false
$body.Current.BoundingRectangle=[Windows.Rect]::Parse('895,266,158,17');$body.Visible=$false
$replyElement.Current.BoundingRectangle=[Windows.Rect]::Parse('892,309,37,17')
Assert-True (-not (Test-ReplyTargetVisible $viewportLive)) '真实失败布局中仅按钮露出时被误认为整个评论可见。'
Assert-True ((Get-ReplyTargetScrollNotches $viewportLive) -eq 1) '原作者被固定标题遮挡时滚动方向错误。'
$author.Current.BoundingRectangle=[Windows.Rect]::Parse('895,542,40,20');$author.Visible=$true
$body.Current.BoundingRectangle=[Windows.Rect]::Parse('895,566,158,17');$body.Visible=$true
$replyElement.Current.BoundingRectangle=[Windows.Rect]::Parse('892,609,37,17')
Assert-True (-not (Test-ReplyTargetVisible $viewportLive)) '原评论被输入页脚遮挡时未拒绝点击。'
Assert-True ((Get-ReplyTargetScrollNotches $viewportLive) -eq -1) '原评论在页脚下方时滚动方向错误。'
$author.Current.BoundingRectangle=[Windows.Rect]::Parse('895,342,40,20')
$body.Current.BoundingRectangle=[Windows.Rect]::Parse('895,366,158,17')
$replyElement.Current.BoundingRectangle=[Windows.Rect]::Parse('892,409,37,17')
$body.Visible=$false
Assert-True (-not (Test-ReplyTargetVisible $viewportLive)) '正文被裁切为不可见时仍允许选择回复。'
Assert-Rejected {Get-ReplyTargetScrollNotches $viewportLive} '无法按边界判断的遮挡仍被猜测滚动。'
$body.Visible=$true
$savedNodes=$viewportLive.Snapshot.Nodes
$viewportLive.Snapshot.Nodes=@($savedNodes | Where-Object {$_.Index -ne 5})
Assert-Rejected {Test-ReplyTargetVisible $viewportLive} '标题缺失时退回整个侧栏边界。'
$viewportLive.Snapshot.Nodes=$savedNodes
$savedIndices=$viewportLive.Candidate.BodyNodeIndices;$viewportLive.Candidate.BodyNodeIndices=@(89,999)
Assert-Rejected {Test-ReplyTargetVisible $viewportLive} '正文控件引用缺失时未停止。'
$viewportLive.Candidate.BodyNodeIndices=$savedIndices

# 输入框变高遮住原评论时，只滚动已确认的列表；草稿、焦点和原身份都必须保持。
$script:DraftCandidate=[pscustomobject]@{ReplyText='已逐字回读的本次回复 Sparnow'}
$script:DraftEditor=[pscustomobject]@{Visible=$true;Value=$script:DraftCandidate.ReplyText;Current=[pscustomobject]@{HasKeyboardFocus=$true}}
$script:Editors=@($script:DraftEditor);$script:Placeholders=@()
function Reset-DraftViewportCase {
    $script:DraftMoves=0;$script:DraftMissing=$false;$script:DraftStall=$false;$script:DraftChangesAfterMove=$false
    $script:DraftFooter=440
    $script:DraftEditor.Value=$script:DraftCandidate.ReplyText;$script:DraftEditor.Current.HasKeyboardFocus=$true
    $author.Current.BoundingRectangle=[Windows.Rect]::Parse('895,390,40,20')
    $body.Current.BoundingRectangle=[Windows.Rect]::Parse('895,414,158,17')
    $emoji.Current.BoundingRectangle=[Windows.Rect]::Parse('1053,414,16,17')
    $replyElement.Current.BoundingRectangle=[Windows.Rect]::Parse('892,450,37,17')
    $replyElement.Visible=$false
}
function Get-ReplyFooterTop($InputElement){return $script:DraftFooter}
function Wait-RpaDelay([double]$Seconds){}
function Ensure-DouyinForeground {}
function Get-CommentCard {return $script:Card}
function Get-CommentEditor($Card){if($Card -ne $script:Card){throw '编辑器查询脱离当前侧栏。'};return $script:DraftEditor}
function Find-ReplyLiveTarget($Candidate){if($Candidate -ne $script:DraftCandidate){throw '原候选被替换。'};if($script:DraftMissing){return $null};return $viewportLive}
function Move-ReplyCommentPanel($Card,[int]$Notches){
    if($Card -ne $script:Card -or $Notches -ne -1){throw '不是向上恢复被页脚遮住的原评论。'}
    $script:DraftMoves++
    if(-not $script:DraftStall){foreach($element in @($author,$body,$emoji,$replyElement)){$bounds=$element.Current.BoundingRectangle;$bounds.Offset(0,-60);$element.Current.BoundingRectangle=$bounds};$replyElement.Visible=$true}
    if($script:DraftChangesAfterMove){$script:DraftEditor.Value='已经变化的草稿'}
}
function Invoke-DouyinClick($Element){throw '恢复可见性禁止点击或重选回复。'}

Reset-DraftViewportCase
Restore-ReplyDraftTargetVisibility $script:DraftCandidate
Assert-True ($script:DraftMoves -eq 1 -and (Test-ReplyTargetVisible $viewportLive)) '输入框展开遮住回复按钮时未恢复整个原评论可见。'
Assert-True ($script:DraftEditor.Value -ceq $script:DraftCandidate.ReplyText -and $script:DraftEditor.Current.HasKeyboardFocus) '恢复可见性改变了原草稿或焦点。'
$script:DraftMoves=0
Restore-ReplyDraftTargetVisibility $script:DraftCandidate
Assert-True ($script:DraftMoves -eq 0) '原评论完整可见时仍额外滚动。'

Reset-DraftViewportCase
$script:DraftEditor.Value='其他草稿'
Assert-Rejected {Restore-ReplyDraftTargetVisibility $script:DraftCandidate} '恢复可见性时忽略草稿变化。'
Assert-True ($script:DraftMoves -eq 0) '草稿不匹配后仍滚动。'
Reset-DraftViewportCase
$script:DraftEditor.Current.HasKeyboardFocus=$false
Assert-Rejected {Restore-ReplyDraftTargetVisibility $script:DraftCandidate} '恢复可见性时忽略编辑器失焦。'
Assert-True ($script:DraftMoves -eq 0) '失焦后仍滚动。'
Reset-DraftViewportCase
$script:DraftMissing=$true
Assert-Rejected {Restore-ReplyDraftTargetVisibility $script:DraftCandidate} '原评论不能唯一定位后仍恢复。'
Assert-True ($script:DraftMoves -eq 0) '原评论缺失后仍滚动。'
Reset-DraftViewportCase
$script:DraftFooter=380
Assert-Rejected {Restore-ReplyDraftTargetVisibility $script:DraftCandidate} '滚轮落在输入页脚上仍执行滚动。'
Assert-True ($script:DraftMoves -eq 0) '不安全的滚轮落点仍被使用。'
Reset-DraftViewportCase
$script:DraftChangesAfterMove=$true
Assert-Rejected {Restore-ReplyDraftTargetVisibility $script:DraftCandidate} '滚动后没有重新核对原草稿。'
Reset-DraftViewportCase
$script:DraftStall=$true
Assert-Rejected {Restore-ReplyDraftTargetVisibility $script:DraftCandidate} '无法恢复原评论时无限滚动或放宽可见性。'
Assert-True ($script:DraftMoves -eq 8) '恢复可见性的滚动次数没有限定。'

# 跨任务首次进入回复流程时 ExpectedVideoId 为空；同一视频必须实时绑定并复用。
. (Join-Path $skillRoot '..\..\shared\douyin\Urls.ps1')
function Add-RouteTrace([string]$Event){$script:RouteTrace.Add($Event)}
function Reset-RouteCase {
    $script:RouteTrace=New-Object 'Collections.Generic.List[string]'
    $script:ExpectedVideoId=$null
    $script:Address=[pscustomobject]@{Value=$expected.VideoUrl}
    $script:DocumentVideoId=$expected.VideoId
    $script:RouteCard=$script:Card
    $script:FailEmpty=$false
    $script:SelectedReply=$false
    $script:TargetReads=0
    $script:TargetMovesAfterEvidence=$false
}
function Ensure-DouyinForeground {
    Add-RouteTrace 'Foreground'
    if($script:ExpectedVideoId){
        Add-RouteTrace 'BoundPageVerified'
        if((Get-DouyinVideoId $script:Address.Value) -cne $script:ExpectedVideoId -or $script:DocumentVideoId -cne $script:ExpectedVideoId){throw '夹具地址栏与文档身份不一致。'}
    }
}
function Get-DouyinAddressElement {Add-RouteTrace 'AddressRead';return $script:Address}
function Get-CommentCard {Add-RouteTrace 'CardRead';return $script:RouteCard}
function Open-DouyinComments($Video){
    Add-RouteTrace 'Navigate'
    $script:Address.Value=$Video.Url;$script:DocumentVideoId=$Video.VideoId;$script:ExpectedVideoId=$Video.VideoId
    return $script:RouteCard
}
function Assert-ReplyInputEmpty($Card){Add-RouteTrace 'EmptyVerified';if($script:FailEmpty){throw '夹具草稿不为空。'}}
function Wait-RpaDelay([double]$Seconds){}
function Find-ReplyLiveTarget($Candidate){$script:TargetReads++;Add-RouteTrace 'TargetVerified';if($script:TargetMovesAfterEvidence -and $script:TargetReads -gt 1){return $null};return [pscustomobject]@{ReplyElement='fixture-reply'}}
function Save-ReplyTargetEvidence($Candidate,$Live){Add-RouteTrace 'BeforeClickEvidence'}
function Test-ReplyTargetVisible($Live){return $true}
function Find-DouyinNamed([string]$Name,$Root){if($Name -cne '回复' -or $Root -cne 'fixture-reply'){throw '夹具回复入口不匹配。'};return 'fixture-label'}
function Invoke-DouyinClick($Element){if($Element -cne 'fixture-reply'){throw '夹具只允许选择目标回复入口。'};Add-RouteTrace 'ReplySelected';$script:SelectedReply=$true}
function Assert-ReplyRecipient($Candidate,$Card){if(-not $script:SelectedReply){throw '尚未选择目标回复入口。'};Add-RouteTrace 'RecipientVerified'}
function Move-ReplyCommentPanel($Card,[int]$Notches){throw '已定位夹具不应滚动。'}
function Count-RouteTrace([string]$Event){return @($script:RouteTrace|Where-Object {$_ -ceq $Event}).Count}
$expected|Add-Member NoteProperty VideoUrl ('https://www.douyin.com/video/'+$expected.VideoId)
$expected|Add-Member NoteProperty VideoTitle 'AI 视频教程'

Reset-RouteCase
$opened=Open-ReplyTarget $expected
Assert-True ($opened -eq $script:Card -and $script:ExpectedVideoId -ceq $expected.VideoId) '跨任务同视频未重建实时绑定或复用原评论侧栏。'
Assert-True ((Count-RouteTrace 'Navigate') -eq 0 -and (Count-RouteTrace 'BoundPageVerified') -eq 1) '跨任务同视频发生刷新或未核验地址栏与文档身份。'
Assert-True ((Count-RouteTrace 'EmptyVerified') -eq 2 -and (Count-RouteTrace 'RecipientVerified') -eq 1 -and (Count-RouteTrace 'ReplySelected') -eq 1) '复用页面跳过了空输入、原评论或收件人核验。'
Assert-True ((Count-RouteTrace 'BeforeClickEvidence') -eq 1 -and (Count-RouteTrace 'TargetVerified') -eq 2) '选择回复前未保存位置证据并重新读取实时目标。'

Reset-RouteCase
$script:Address.Value='https://www.douyin.com/search/AI?type=video'
$script:DocumentVideoId=$null
$null=Open-ReplyTarget $expected
Assert-True ((Count-RouteTrace 'Navigate') -eq 1 -and (Count-RouteTrace 'ReplySelected') -eq 1) '当前不是候选视频时未正常打开绑定视频。'

Reset-RouteCase
$script:DocumentVideoId='7000000000000000099'
Assert-Rejected {Open-ReplyTarget $expected} '地址栏与文档不同的视频被允许复用。'
Assert-True ((Count-RouteTrace 'Navigate') -eq 0 -and (Count-RouteTrace 'ReplySelected') -eq 0) '文档身份不一致后仍导航或选择回复。'

Reset-RouteCase
$script:RouteCard=$null
Assert-Rejected {Open-ReplyTarget $expected} '同一视频缺少唯一评论侧栏时未停止。'
Assert-True ((Count-RouteTrace 'Navigate') -eq 0 -and (Count-RouteTrace 'ReplySelected') -eq 0) '缺少评论侧栏时通过刷新绕过核验。'

Reset-RouteCase
$script:FailEmpty=$true
Assert-Rejected {Open-ReplyTarget $expected} '复用页面已有草稿仍继续操作。'
Assert-True ((Count-RouteTrace 'Navigate') -eq 0 -and (Count-RouteTrace 'ReplySelected') -eq 0) '草稿核验失败后仍刷新或选择回复。'

Reset-RouteCase
$script:TargetMovesAfterEvidence=$true
Assert-Rejected {Open-ReplyTarget $expected} '证据采集期间目标消失后仍继续选择回复。'
Assert-True ((Count-RouteTrace 'BeforeClickEvidence') -eq 1 -and (Count-RouteTrace 'ReplySelected') -eq 0) '实时目标变化后仍点击旧位置。'

[pscustomobject]@{Status='Passed';Checks=$script:Checks;InactivePlaceholderAccepted=$true;AmbiguousInputsRejected=$true;DraftAndUnreadableRejected=$true;IdentityChangesRejected=$true;CrossJobPageReuse=$true;LivePageIdentityRequired=$true;NoRefreshFallback=$true;TargetRecheckedBeforeClick=$true;WholeCommentViewportRequired=$true;DraftViewportRestored=$true;DraftFocusAndValuePreserved=$true;DesktopActions=0;Submitted=0}
