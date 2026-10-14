[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$testWorkspace=Join-Path $repositoryRoot 'artifacts\work'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
. (Join-Path $projectRoot 'src\core\Configuration.ps1')
. (Join-Path $projectRoot 'src\core\Desktop.ps1')
. (Join-Path $projectRoot 'src\workflows\DingTalk.AppCenter.ps1')
$original=Get-Content -LiteralPath (Join-Path $projectRoot 'config\dingtalk.json') -Raw -Encoding UTF8
$testRoot=Join-Path $testWorkspace ('dingtalk-navigation-tests-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testRoot)
function Assert-NavTest([bool]$Condition,[string]$Reason){if(-not $Condition){throw $Reason}}
function New-NavTestButton([string]$Id,[string]$Name) {
    return [pscustomobject]@{Id=$Id;Current=[pscustomobject]@{Name=$Name;ControlType=[System.Windows.Automation.ControlType]::Button;IsEnabled=$true;IsOffscreen=$false;BoundingRectangle=[pscustomobject]@{X=10;Y=10;Width=40;Height=30}}}
}
# 仅替换原生/UIA 读写边界；运行真实选择、校验、等待及导航分支逻辑。
function Get-DingNavForeground {return [IntPtr]$script:NavForeground}
function Assert-DingNavNotCancelled {
    if($script:NavCase -eq 'cancel-start' -or ($script:NavCase -eq 'cancel-after-more' -and $script:NavClicks.Count -gt 0)){throw [OperationCanceledException]::new('离线取消。')}
}
function Get-WindowDetails([IntPtr]$handle) {
    $processId=42;$isDing=$true
    if($handle -eq [IntPtr]303){$processId=99;$isDing=$false}
    if($script:NavCase -eq 'main-identity-invalid' -and $handle -eq [IntPtr]101){$isDing=$false}
    if($handle -eq [IntPtr]202 -and ($script:NavCase -eq 'menu-wrong-pid' -or $script:NavPidChanged)){$processId=43}
    return [pscustomobject]@{Handle=$handle.ToInt64();ProcessId=$processId;Visible=$true;IsDingTalk=$isDing}
}
function Get-DingNavRoot([IntPtr]$handle) {
    $id='main-root'
    if($handle -eq [IntPtr]202){$id=$Config.ApplicationCenter.MoreWindowAutomationId}
    if($script:NavCase -eq 'menu-wrong-root' -or $script:NavRootChanged){$id='untrusted-root'}
    return [pscustomobject]@{Current=[pscustomobject]@{AutomationId=$id}}
}
function Get-DingNavWindowHandles {return @(101,202)}
function Wait-DingNavPoll([int]$Milliseconds) {
    Assert-DingNavNotCancelled;$script:NavPolls++
    if($script:NavPolls -gt $Config.Timing.LabelAttempts){throw '导航等待没有上界。'}
    if($script:NavCase -eq 'more-delayed' -and $script:NavPolls -eq 2){$script:NavForeground=202}
}
function Get-DingNavMatches([IntPtr]$handle,[string]$id) {
    if(-not $script:NavQueries.ContainsKey($id)){$script:NavQueries[$id]=0};$script:NavQueries[$id]++
    if($id -eq $Config.ApplicationCenter.AutomationId){
        if($script:NavCase -notlike 'direct-*' -and $script:NavCase -ne 'legacy-direct'){return @()}
        $button=New-NavTestButton $id '应用中心'
        if($script:NavCase -eq 'direct-duplicate' -or ($script:NavCase -eq 'direct-stale-duplicate' -and $script:NavQueries[$id] -gt 1)){return @($button,$button)}
        if($script:NavCase -eq 'direct-disabled'){$button.Current.IsEnabled=$false}
        if($script:NavCase -eq 'direct-hidden'){$button.Current.IsOffscreen=$true}
        if($script:NavCase -eq 'direct-wrong-name'){$button.Current.Name='其他入口'}
        if($script:NavCase -eq 'direct-wrong-type'){$button.Current.ControlType=[System.Windows.Automation.ControlType]::Text}
        if($script:NavCase -eq 'direct-empty-bounds'){$button.Current.BoundingRectangle.Width=0}
        return $button
    }
    if($id -eq $Config.ApplicationCenter.MoreAutomationId){
        if($script:NavCase -eq 'more-missing'){return @()}
        $button=New-NavTestButton $id '更多'
        if($script:NavCase -eq 'more-duplicate'){return @($button,$button)}
        if($script:NavCase -eq 'more-disabled'){$button.Current.IsEnabled=$false}
        return $button
    }
    if($id -eq $Config.ApplicationCenter.MoreItemAutomationId){
        if($handle -ne [IntPtr]202){throw '菜单查询没有限制到已确认弹窗。'}
        if($script:NavCase -eq 'menu-missing'){return @()}
        $button=New-NavTestButton $id '应用中心'
        if($script:NavCase -eq 'menu-duplicate' -or ($script:NavCase -eq 'menu-stale-duplicate' -and $script:NavQueries[$id] -gt 1)){return @($button,$button)}
        if($script:NavCase -eq 'menu-disabled'){$button.Current.IsEnabled=$false}
        if($script:NavCase -eq 'menu-stale-hidden' -and $script:NavQueries[$id] -gt 1){$button.Current.IsOffscreen=$true}
        if($script:NavCase -eq 'menu-focus-lost-during-lookup' -and $script:NavQueries[$id] -gt 1){$script:NavForeground=303}
        if($script:NavCase -eq 'menu-pid-changed-during-lookup' -and $script:NavQueries[$id] -gt 1){$script:NavPidChanged=$true}
        return $button
    }
    throw '查询了未固定的导航选择器。'
}
function Invoke-DingNavMouseClick([IntPtr]$handle,$Button) {
    $script:NavClicks.Add($Button.Id)
    if($Button.Id -eq $Config.ApplicationCenter.MoreAutomationId){
        if($handle -ne [IntPtr]101){throw '更多未绑定主窗口。'}
        $script:NavForeground=202
        if($script:NavCase -eq 'more-delayed'){$script:NavForeground=101}
        if($script:NavCase -eq 'menu-other-app'){$script:NavForeground=303}
    }elseif($Button.Id -eq $Config.ApplicationCenter.MoreItemAutomationId){
        if($handle -ne [IntPtr]202){throw '应用中心点击了错误窗口。'}
    }elseif($Button.Id -ne $Config.ApplicationCenter.AutomationId){throw '点击了未经验证的入口。'}
}
function Save-TargetImage([IntPtr]$handle,[string]$filename) {$script:NavEvidence.Add($filename)}
function Save-VisibleControls([IntPtr]$handle,[string]$filename) {
    $script:NavEvidence.Add($filename)
    if($script:NavCase -eq 'menu-root-changed-after-evidence'){$script:NavRootChanged=$true}
    if($script:NavCase -eq 'menu-focus-lost-after-evidence'){$script:NavForeground=303}
}
try{
    $Config=Read-RpaConfiguration (Join-Path $projectRoot 'config\dingtalk.json')
    $moreNames=@('MoreAutomationId','MoreName','MoreWindowAutomationId','MoreItemAutomationId')
    $legacy=$original|ConvertFrom-Json
    foreach($name in $moreNames){$legacy.ApplicationCenter.PSObject.Properties.Remove($name)}
    $legacyPath=Join-Path $testRoot 'legacy.json'
    [IO.File]::WriteAllText($legacyPath,(ConvertTo-Json $legacy -Depth 6),(New-Object Text.UTF8Encoding($false)))
    $null=Read-RpaConfiguration $legacyPath
    $invalidConfigs=0
    foreach($name in $moreNames){
        $bad=$original|ConvertFrom-Json;$bad.ApplicationCenter.$name='未经验证的入口'
        $path=Join-Path $testRoot 'bad.json';[IO.File]::WriteAllText($path,(ConvertTo-Json $bad -Depth 6),(New-Object Text.UTF8Encoding($false)))
        try{$null=Read-RpaConfiguration $path}catch{$invalidConfigs++}
    }
    $partial=$original|ConvertFrom-Json;$partial.ApplicationCenter.PSObject.Properties.Remove('MoreName')
    $path=Join-Path $testRoot 'partial.json';[IO.File]::WriteAllText($path,(ConvertTo-Json $partial -Depth 6),(New-Object Text.UTF8Encoding($false)))
    try{$null=Read-RpaConfiguration $path}catch{$invalidConfigs++}
    Assert-NavTest ($invalidConfigs -eq 5) '错误或不完整的更多选择器配置被接受。'
    $cases=@(
        @('direct-valid',1,$true),@('legacy-direct',1,$true),@('legacy-missing',0,$false),
        @('direct-duplicate',0,$false),@('direct-disabled',0,$false),@('direct-hidden',0,$false),@('direct-wrong-name',0,$false),@('direct-wrong-type',0,$false),@('direct-empty-bounds',0,$false),@('direct-stale-duplicate',0,$false),
        @('more-normal',2,$true),@('more-delayed',2,$true),@('more-missing',0,$false),@('more-duplicate',0,$false),@('more-disabled',0,$false),
        @('menu-missing',1,$false),@('menu-duplicate',1,$false),@('menu-disabled',1,$false),@('menu-wrong-pid',1,$false),@('menu-wrong-root',1,$false),@('menu-other-app',1,$false),
        @('menu-stale-duplicate',1,$false),@('menu-stale-hidden',1,$false),@('menu-focus-lost-during-lookup',1,$false),@('menu-pid-changed-during-lookup',1,$false),@('menu-root-changed-after-evidence',1,$false),@('menu-focus-lost-after-evidence',1,$false),
        @('cancel-start',0,$false),@('cancel-after-more',1,$false),@('main-identity-invalid',0,$false)
    )
    foreach($case in $cases){
        $script:NavCase=[string]$case[0];$Config=$original|ConvertFrom-Json
        if($script:NavCase -like 'legacy-*'){$Config=$legacy}
        $Config.Timing.LabelAttempts=3
        $testResult=[ordered]@{Actions=@()};$script:NavForeground=101;$script:NavPolls=0;$script:NavPidChanged=$false;$script:NavRootChanged=$false
        $script:NavClicks=New-Object 'Collections.Generic.List[string]';$script:NavEvidence=New-Object 'Collections.Generic.List[string]';$script:NavQueries=@{}
        $succeeded=$true;$reason=$null
        try{Invoke-DingAppCenterNavigation ([IntPtr]101)}catch{$succeeded=$false;$reason=$_.Exception.Message}
        Assert-NavTest ($succeeded -eq [bool]$case[2]) ('导航结果错误：'+$script:NavCase+'；'+$reason)
        Assert-NavTest ($script:NavClicks.Count -eq [int]$case[1]) ('点击次数错误：'+$script:NavCase)
        if($succeeded -and $script:NavCase -like '*direct*'){
            Assert-NavTest ($testResult.AppCenterRoute -eq 'Direct' -and $script:NavClicks[0] -eq $Config.ApplicationCenter.AutomationId -and $script:NavEvidence.Count -eq 0) '直达路径错误使用更多或记录错误。'
        }elseif($succeeded){
            Assert-NavTest ($testResult.AppCenterRoute -eq 'More' -and ($script:NavClicks -join ',') -eq ($Config.ApplicationCenter.MoreAutomationId+','+$Config.ApplicationCenter.MoreItemAutomationId)) '更多路径点击顺序不正确。'
            Assert-NavTest (($script:NavEvidence -join ',') -eq '00-more.png,00-more-controls.json' -and $testResult.Actions.Count -eq 2) '更多证据或动作记录未保留。'
        }
        if($script:NavCase -in @('menu-missing','menu-wrong-root')){Assert-NavTest ($script:NavPolls -eq 2) '缺失菜单等待不是有界重试。'}
        if($script:NavCase -eq 'menu-duplicate'){Assert-NavTest ($script:NavPolls -eq 0) '重复菜单被错误当成缺失而重试。'}
    }
    [pscustomobject]@{Status='Passed';NavigationCases=$cases.Count;InvalidConfigurationsRejected=$invalidConfigs;LegacyConfigurationAccepted=$true;MissingAndDuplicateDistinguished=$true;PopupSameProcessAndRootRequired=$true;ClickRevalidation=$true;BoundedMenuWait=$true;SingleMoreClick=$true;MoreEvidenceRecorded=$true;DesktopActions=0}
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot);$work=[IO.Path]::GetFullPath($testWorkspace)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($work,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^dingtalk-navigation-tests-[a-f0-9]{32}$'){throw '拒绝清理未确认的钉钉导航测试目录。'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
