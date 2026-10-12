function Read-DouyinConfiguration([string]$Path) {
    $c=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if($c.SchemaVersion -ne 1){throw '不支持的抖音配置版本。'}
    if($c.Browser.ProcessName -ne 'chrome' -or $c.Browser.TitleContains -ne '抖音' -or $c.Browser.AutoActivate -isnot [bool]){throw '当前仅支持明确定位的抖音 Chrome 窗口。'}
    foreach($property in @('SearchTerms','MatchAny')){
        $values=@($c.$property)
        if($values.Count -lt 1 -or $values.Count -gt 20){throw ('配置项数量异常：'+$property)}
        foreach($value in $values){if($value -isnot [string] -or -not $value.Trim() -or $value.Length -gt 60 -or $value -match '[\p{C}]'){throw ('配置项文字异常：'+$property)}}
    }
    if($c.Comment -isnot [string] -or -not $c.Comment.Trim() -or $c.Comment.Length -gt 300 -or $c.Comment -match '[\p{C}]'){throw '评论需要 1 至 300 字，不能含控制字符。'}
    $ranges=@(
        @($c.Timing.PageWaitSeconds,5,120),@($c.Timing.CommentIntervalSeconds,10,86400),
        @($c.Timing.EmptyQueueWaitSeconds,10,86400),
        @($c.Discovery.MaxScrollRounds,0,20),@($c.Discovery.MaxVideosPerSearch,1,100)
    )
    foreach($range in $ranges){$v=$range[0]; if($v -isnot [ValueType] -or $v -is [bool] -or [double]$v -ne [Math]::Truncate([double]$v) -or $v -lt $range[1] -or $v -gt $range[2]){throw '抖音等待或发现参数必须为允许范围内的整数。'}}
    foreach($name in @('AddressAutomationId','CommentCardAutomationId','EditorClass','Placeholder','CommentButtonClassToken')){
        if($c.Selectors.$name -isnot [string] -or -not $c.Selectors.$name){throw ('缺少选择器：'+$name)}
    }
    if(@($c.Selectors.SendButtonClasses).Count -lt 1 -or @($c.Selectors.SendButtonClasses).Count -gt 10){throw '发送按钮选择器配置无效。'}
    foreach($selector in $c.Selectors.SendButtonClasses){if($selector -isnot [string] -or -not $selector.Trim()){throw '发送按钮选择器不能为空。'}}
    return $c
}
function ConvertTo-DouyinUri([string]$Address) {
    if($Address -notmatch '^https?://'){$Address='https://'+$Address}
    $uri=$null
    if(-not [Uri]::TryCreate($Address,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -notin @('douyin.com','www.douyin.com') -or $uri.UserInfo -or -not $uri.IsDefaultPort){throw '浏览器不在预期的抖音 HTTPS 页面。'}
    return $uri
}
function Get-DouyinVideoId([string]$Address) {
    $uri=ConvertTo-DouyinUri $Address
    if($uri.AbsolutePath -match '^/video/(\d{19})/?$'){return $Matches[1]}
    if($uri.Query -match '(?:^\?|&)modal_id=(\d{19})(?:&|$)'){return $Matches[1]}
    return $null
}
