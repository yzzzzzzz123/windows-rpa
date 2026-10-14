[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$skillRoot=Split-Path $PSScriptRoot -Parent
$workspace=[IO.Path]::GetFullPath((Join-Path $skillRoot '..\..\artifacts\work'))
$testRoot=Join-Path $workspace ('reply-session-test-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot -Force
. (Join-Path $skillRoot 'scripts\Reply.Core.ps1')
$script:Checks=0
function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
function Assert-Rejected([scriptblock]$Body,[string]$Message){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert-True $rejected $Message}
$own=[pscustomobject]@{SessionId=1;UserSid='own';Active=$true}
$other=[pscustomobject]@{SessionId=2;UserSid='other';Active=$true}
$disconnected=[pscustomobject]@{SessionId=3;UserSid='own';Active=$false}
Assert-True ((Select-ReplyUserSession @($own,$other,$disconnected) 'own') -eq 1) '选择了其他账号或断开连接的会话。'
Assert-Rejected {Select-ReplyUserSession @($other,$disconnected) 'own'} '无活动会话时未拒绝。'
Assert-Rejected {Select-ReplyUserSession @($own,$own) 'own'} '多个活动会话时未拒绝歧义。'

# Fake Task Scheduler definition: assert credentials, elevation, triggers and retries.
$script:Definition=[pscustomobject]@{RegistrationInfo=[pscustomobject]@{Description=''};Principal=[pscustomobject]@{UserId='';LogonType=0;RunLevel=1};Settings=[pscustomobject]@{Enabled=$false;AllowDemandStart=$false;DisallowStartIfOnBatteries=$true;StopIfGoingOnBatteries=$true;ExecutionTimeLimit='';RestartCount=99;MultipleInstances=0};Actions=[pscustomobject]@{}}
$script:Action=[pscustomobject]@{Path='';Arguments='';WorkingDirectory=''}
$script:Definition.Actions|Add-Member ScriptMethod Create {param($type)if($type -ne 0){throw '不是 Exec action'};return $script:Action}
$service=[pscustomobject]@{}
$service|Add-Member ScriptMethod NewTask {param($flags)return $script:Definition}
$environment=[pscustomobject]@{RuntimeRoot=$skillRoot;DataRoot=(Join-Path $testRoot '中文 skill''s & $ 数据');StateRoot=(Join-Path $testRoot 'state')}
$requestPath=Join-Path $environment.DataRoot 'request.json'
$definition=New-ReplySessionTask $service $environment $requestPath 'own'
Assert-True ($definition.Principal.UserId -eq 'own' -and $definition.Principal.LogonType -eq 3 -and $definition.Principal.RunLevel -eq 0) '任务没有使用同账号 InteractiveToken 和普通权限。'
Assert-True ($definition.Settings.RestartCount -eq 0 -and $definition.Settings.MultipleInstances -eq 2 -and $definition.Settings.ExecutionTimeLimit -eq 'PT1M') '任务可自动重启或重复启动。'
Assert-True ($script:Action.Arguments.EndsWith(' -RequestFile "'+$requestPath+'"') -and $script:Action.Arguments.Contains('-STA -WindowStyle Hidden -File "')) '中文及特殊字符路径没有作为独立参数传递。'

# Mock handoff only; no real scheduler or desktop is touched by this suite.
$script:Sessions=@($own);$script:Started=0;$script:Removed=0;$script:CreateReceipt=$true;$script:WrongReceipt=$false;$script:Running=$false
function Get-ReplyCallerSid {return 'own'}
function Get-ReplyUserSessions($EnvInfo){return $script:Sessions}
function Get-ReplyStatus($EnvInfo,[string]$Id){return [pscustomobject]@{Running=$script:Running;JobId='existing'}}
function Remove-ReplySessionTask([string]$TaskName){$script:Removed++}
function Start-ReplySessionTask($EnvInfo,[string]$RequestFile,[string]$TaskName,[int]$SessionId,[string]$UserSid){
    $script:Started++
    $request=Read-ReplyJson $RequestFile
    if($request.UserSid -ne 'own' -or $request.SessionId -ne 1 -or $UserSid -ne 'own' -or $SessionId -ne 1){throw '派发身份不匹配。'}
    $script:Snapshot=Read-ReplyJson (Join-Path (Split-Path $RequestFile -Parent) 'task.json')
    $script:ReceiptPath=Join-Path (Split-Path $RequestFile -Parent) 'receipt.json'
    $script:LaunchId=$request.LaunchId
    if($script:CreateReceipt){Write-ReplyJson ([ordered]@{LaunchId=$(if($script:WrongReceipt){'wrong'}else{$request.LaunchId});Result=[ordered]@{Ok=$true;JobId='fixture';Submitted=0}}) $script:ReceiptPath}
}
function Wait-ReplySessionReceipt([string]$Path){if(-not (Test-Path -LiteralPath $Path)){throw '模拟启动超时。'};return Read-ReplyJson $Path}
try{
    $taskFile=Join-Path $testRoot 'task.json'
    Write-ReplyJson ([ordered]@{Mode='Discover';SearchTerms=@('中文视频分镜')}) $taskFile
    $result=Invoke-ReplyInteractiveStart $environment $taskFile
    Assert-True ($result.Ok -and $script:Started -eq 1 -and $script:Removed -eq 1) '会话派发没有返回真实回执或清理一次性任务。'
    Assert-True ($script:Snapshot.SearchTerms[0] -ceq '中文视频分镜') '输入快照中文丢失。'
    $pendingPath=Join-Path $environment.StateRoot 'interactive-launch.json'
    Assert-True (-not (Test-Path -LiteralPath $pendingPath)) '收到回执后仍保留未确认启动标记。'
    $script:Running=$true
    Assert-Rejected {Invoke-ReplyInteractiveStart $environment $taskFile} '已有任务仍可派发新启动。'
    Assert-True ($script:Started -eq 1) '活跃任务检查发生在调度器启动之后。'
    $script:Running=$false;$script:CreateReceipt=$false
    Assert-Rejected {Invoke-ReplyInteractiveStart $environment $taskFile} '启动超时未保留不确定结果。'
    Assert-True ((Test-Path -LiteralPath $pendingPath) -and $script:Started -eq 2 -and $script:Removed -eq 1) '超时后删除了启动记录或正在启动的任务。'
    Assert-Rejected {Invoke-ReplyInteractiveStart $environment $taskFile} '不确定启动结果允许重新派发。'
    Assert-True ($script:Started -eq 2) '超时后重复派发了任务。'
    # A later receipt recovers the existing result, never starts the next job.
    Write-ReplyJson ([ordered]@{LaunchId=$script:LaunchId;Result=[ordered]@{Ok=$true;JobId='late'}}) $script:ReceiptPath
    $result=Invoke-ReplyInteractiveStart $environment $taskFile
    Assert-True ($result.JobId -eq 'late' -and $script:Started -eq 2 -and $script:Removed -eq 2 -and -not (Test-Path -LiteralPath $pendingPath)) '迟到回执没有恢复原结果或产生重复任务。'
    $script:CreateReceipt=$true;$script:WrongReceipt=$true
    Assert-Rejected {Invoke-ReplyInteractiveStart $environment $taskFile} '错误身份回执没有拒绝。'
    Assert-True ((Test-Path -LiteralPath $pendingPath) -and $script:Removed -eq 2) '错误身份回执仍清理了待确认启动记录。'
    [pscustomobject]@{Status='Passed';Checks=$script:Checks;SameAccountOnly=$true;NoElevation=$true;NoPassword=$true;UnknownNoRetry=$true;LateReceiptRecovered=$true;DesktopActions=0;Submitted=0}
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=$workspace+'\'
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notmatch '^reply-session-test-[a-f0-9]{32}$'){throw '拒绝清理未知测试目录。'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
