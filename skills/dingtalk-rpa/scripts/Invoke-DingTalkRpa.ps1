[CmdletBinding()]
param(
    [ValidateSet('Check','Inspect','Run')][string]$Mode='Run',
    [switch]$WaitForKey
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DingTalk.Paths.ps1')
$runnerPath=Join-Path $skillRoot 'scripts\Invoke-DingTalkNative.ps1'
$configPath=Join-Path $skillRoot 'config\dingtalk.json'
$workflowPath=Join-Path $skillRoot 'src\workflows\DingTalk.AppCenter.ps1'
foreach($required in @($runnerPath,$configPath,$workflowPath)){
    if(-not (Test-Path -LiteralPath $required -PathType Leaf)){throw ('钉钉运行依赖缺失：'+$required)}
}
$parameters=@{
    Scenario=if($Mode -eq 'Inspect'){'Inspect'}else{'AppCenterLowCode'}
    ConfigPath=$configPath
    EvidenceRoot=$layout.RunsRoot
    SelfTest=($Mode -eq 'Check')
    WaitForKey=[bool]$WaitForKey
}
& $runnerPath @parameters
exit $LASTEXITCODE
