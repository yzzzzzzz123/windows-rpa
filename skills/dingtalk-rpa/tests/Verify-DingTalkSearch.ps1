[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$testWorkspace=Join-Path $repositoryRoot 'artifacts\work'
. (Join-Path $projectRoot 'src\workflows\DingTalk.AppCenter.ps1')
$Config=Get-Content -LiteralPath (Join-Path $projectRoot 'config\dingtalk.json') -Raw -Encoding UTF8|ConvertFrom-Json
function Find-DingMarketTarget {
    param([IntPtr]$handle,[string]$Name,[string]$ImageName,[switch]$Editor)
    $script:Lookups++
    if($script:SearchCase -eq 'missing'){return $null}
    if($script:SearchCase -eq 'duplicate'){throw '重复目标。'}
    $x=100
    if($script:SearchCase -eq 'moved-before-input' -and $script:Lookups -gt 1){$x=200}
    $element=$null
    if($script:SearchCase -in @('nonempty','uia-empty')){$element=[pscustomobject]@{Id=1}}
    return [pscustomobject]@{X=$x;Y=100;Width=120;Height=20;Element=$element;Method='fixture'}
}
function Invoke-DingSearchClick {$script:Clicks++}
function Wait-DingNavPoll {}
function Assert-DingSearchFocus {
    $script:FocusChecks++
    if($script:SearchCase -eq 'focus-lost'){throw '焦点丢失。'}
    if($script:SearchCase -eq 'focus-lost-before-send' -and $script:FocusChecks -gt 1){throw '输入前失焦。'}
}
function Get-DingSearchValue {
    if($script:SearchCase -eq 'nonempty'){return '已有内容'}
    if($script:Sent.Count -eq 0){return ''}
    if($script:SearchCase -eq 'readback-failed'){return 'tes'}
    return 'test'
}
function Send-DingSearchText([IntPtr]$handle,$Target,[string]$Text) {$script:Sent.Add($Text)}
function Write-JsonFile {}
function Save-TargetImage {}
$cases=@(
    @('ocr-empty',$true,1),@('uia-empty',$true,1),@('missing',$false,0),@('duplicate',$false,0),
    @('nonempty',$false,0),@('focus-lost',$false,0),@('focus-lost-before-send',$false,0),
    @('moved-before-input',$false,0),@('readback-failed',$false,1)
)
foreach($case in $cases){
    $script:SearchCase=$case[0];$script:Lookups=0;$script:Clicks=0;$script:FocusChecks=0
    $script:Sent=New-Object 'Collections.Generic.List[string]'
    $testResult=[ordered]@{Actions=@()};$passed=$true
    try{Invoke-DingSearchInput ([IntPtr]101)}catch{$passed=$false}
    if($passed -ne $case[1] -or $script:Sent.Count -ne $case[2]){throw ('搜索输入边界失败：'+$script:SearchCase)}
    if($testResult.SearchInput.Submitted -ne $false){throw '搜索步骤不能提交。'}
    if($passed -and (-not $testResult.SearchInput.Verified -or $script:Sent[0] -cne 'test')){throw '未核验精确输入。'}
    if($script:SearchCase -eq 'readback-failed' -and (-not $testResult.SearchInput.InputAttempted -or $testResult.SearchInput.Verified -or $testResult.Actions.Count -ne 0)){throw '未知输入被误记成功。'}
}
[pscustomobject]@{Status='Passed';SearchCases=$cases.Count;NonemptyPreserved=$true;FocusRequired=$true;UnknownInputNotRetried=$true;DesktopActions=0}
