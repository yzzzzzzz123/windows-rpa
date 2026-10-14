# 两个抖音 Skill 共用的 HTTPS 来源校验与视频编号解析；无桌面或状态依赖。
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
