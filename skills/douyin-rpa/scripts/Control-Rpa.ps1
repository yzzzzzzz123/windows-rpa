[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Pause','Resume','Stop')][string]$Action,[string]$StateRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Skill.Core.ps1')
if(-not $StateRoot){$StateRoot=(Get-SkillEnvironment).StateRoot}
$controlRoot=Join-Path $StateRoot 'control'
$null=New-Item -ItemType Directory -Path $controlRoot -Force
switch($Action){
    'Pause' {Set-Content -LiteralPath (Join-Path $controlRoot 'pause') -Value (Get-Date -Format o) -Encoding UTF8; Write-Host '已请求暂停；程序会在下一个操作检查点暂停。'}
    'Resume' {foreach($name in @('pause','stop')){$path=Join-Path $controlRoot $name; if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}; Write-Host '暂停/停止标记已清除。已退出的程序需要重新启动。'}
    'Stop' {Set-Content -LiteralPath (Join-Path $controlRoot 'stop') -Value (Get-Date -Format o) -Encoding UTF8; Write-Host '已请求停止；已提交但未确认的评论不会自动重试。'}
}
