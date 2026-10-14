function Assert-ReplyInteger($Value,[int]$Minimum,[int]$Maximum,[string]$Name) {
    if($Value -isnot [ValueType] -or $Value -is [bool] -or [double]$Value -ne [Math]::Truncate([double]$Value) -or $Value -lt $Minimum -or $Value -gt $Maximum){throw ($Name+' 必须为 '+$Minimum+' 至 '+$Maximum+' 的整数。')}
}
function Assert-ReplyText($Value,[int]$Maximum,[string]$Name,[switch]$AllowWhitespace) {
    if($Value -isnot [string] -or -not $Value.Trim() -or $Value.Length -gt $Maximum){throw ($Name+' 文字为空或超过长度上限。')}
    $check=if($AllowWhitespace){$Value -replace '[\r\n\t]',''}else{$Value}
    # 补充平面的表情由代理对表示，不能把 Unicode Surrogate 当成控制字符。
    if($check -match '[\p{Cc}]'){throw ($Name+' 不能含控制字符。')}
}
function Get-ReplyIdentityHash([string]$Value) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object {$_.ToString('x2')}) -join '')}finally{$sha.Dispose()}
}
function Assert-ReplyCandidate($Candidate) {
    if($Candidate -isnot [pscustomobject]){throw '候选评论必须为 JSON 对象。'}
    if($Candidate.CandidateId -isnot [string] -or $Candidate.CandidateId -cnotmatch '^[a-f0-9]{64}$'){throw 'CandidateId 必须为 SHA256 小写十六进制。'}
    if($Candidate.AuthorKey -isnot [string] -or $Candidate.AuthorKey -cnotmatch '^[a-f0-9]{64}$'){throw 'AuthorKey 必须为 SHA256 小写十六进制。'}
    if($Candidate.VideoId -isnot [string] -or $Candidate.VideoId -notmatch '^\d{19}$'){throw '候选视频编号无效。'}
    if($Candidate.CommentId -isnot [string] -or $Candidate.CommentId -notmatch '^\d{19}$'){throw '候选原评论编号无效。'}
    Assert-ReplyText $Candidate.AuthorName 200 'AuthorName'
    Assert-ReplyText $Candidate.Text 10000 '原评论' -AllowWhitespace
    Assert-ReplyText $Candidate.VideoTitle 2000 'VideoTitle' -AllowWhitespace
    if($Candidate.AuthorUrl -isnot [string] -or $Candidate.AuthorUrl -notmatch '^https://www\.douyin\.com/user/[A-Za-z0-9_-]+$'){throw '候选作者必须具有无查询参数、无尾斜杠的规范抖音用户主页。'}
    if($Candidate.VideoUrl -isnot [string] -or $Candidate.VideoUrl -notmatch '^https://www\.douyin\.com/(?:video/(\d{19})/?|jingxuan/?\?modal_id=(\d{19}))$'){throw '候选视频地址无效。'}
    $addressId=if($Matches[1]){$Matches[1]}else{$Matches[2]}
    if($addressId -cne $Candidate.VideoId){throw '候选视频地址与视频编号不一致。'}
    if($Candidate.CandidateId -cne (Get-ReplyIdentityHash ($Candidate.VideoId+'|'+$Candidate.CommentId)) -or $Candidate.AuthorKey -cne (Get-ReplyIdentityHash $Candidate.AuthorUrl)){throw '候选评论或作者身份哈希不一致。'}
}
function Assert-ReplyConfiguration($Config) {
    if($Config.SchemaVersion -ne 1 -or $Config.Mode -notin @('Discover','Preview','Publish')){throw '回复配置版本或模式无效。'}
    if($Config.Browser.ProcessName -ne 'chrome' -or $Config.Browser.TitleContains -ne '抖音' -or $Config.Browser.AutoActivate -isnot [bool]){throw '当前仅支持明确定位的抖音 Chrome 窗口。'}
    foreach($name in @('SearchTerms','MatchAny')){
        if($Config.$name -isnot [array] -or $Config.$name.Count -lt 1 -or $Config.$name.Count -gt 30){throw ($name+' 必须为 1 至 30 项数组。')}
        foreach($value in $Config.$name){Assert-ReplyText $value 60 $name}
    }
    Assert-ReplyInteger $Config.MaxVideos 1 10 'MaxVideos'
    Assert-ReplyInteger $Config.MaxCommentsPerVideo 1 100 'MaxCommentsPerVideo'
    Assert-ReplyInteger $Config.MaxScrollRounds 0 10 'MaxScrollRounds'
    Assert-ReplyInteger $Config.Timing.PageWaitSeconds 5 120 'PageWaitSeconds'
    Assert-ReplyInteger $Config.Timing.CommentIntervalSeconds 10 86400 'CommentIntervalSeconds'
    foreach($name in @('AddressAutomationId','CommentCardAutomationId','EditorClass','Placeholder','CommentButtonClassToken')){Assert-ReplyText $Config.Selectors.$name 200 $name}
    if($Config.Selectors.SendButtonClasses -isnot [array] -or $Config.Selectors.SendButtonClasses.Count -lt 1 -or $Config.Selectors.SendButtonClasses.Count -gt 10){throw '发送按钮选择器无效。'}
    foreach($value in $Config.Selectors.SendButtonClasses){Assert-ReplyText $value 200 'SendButtonClasses'}
    if($Config.Mode -ne 'Discover'){
        if($Config.SourceJobId -notmatch '^\d{8}_\d{9}-[a-f0-9]{12}$'){throw 'SourceJobId 格式无效。'}
        if($Config.Replies -isnot [array] -or $Config.Replies.Count -lt 1 -or $Config.Replies.Count -gt 10){throw 'Replies 必须为 1 至 10 项数组。'}
        $ids=@{};$authors=@{}
        foreach($reply in $Config.Replies){
            Assert-ReplyCandidate $reply
            Assert-ReplyText $reply.ReplyText 300 'ReplyText'
            Assert-ReplyText $reply.Reason 1000 'Reason'
            if($reply.ReplyText -notmatch '(?i)Sparnow'){throw '每条回复必须提到 Sparnow。'}
            if($ids.ContainsKey($reply.CandidateId) -or $authors.ContainsKey($reply.AuthorKey)){throw '同批次不能重复回复同一评论或同一用户。'}
            $ids[$reply.CandidateId]=$true;$authors[$reply.AuthorKey]=$true
        }
    }
    return $Config
}
function Read-ReplyConfiguration([string]$Path) {
    $config=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return Assert-ReplyConfiguration $config
}
