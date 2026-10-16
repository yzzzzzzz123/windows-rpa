[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$psFiles=@(foreach($directory in @('skills','shared','scripts','tests')){Get-ChildItem -LiteralPath (Join-Path $projectRoot $directory) -Recurse -Filter '*.ps1' -File})
foreach($file in $psFiles){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw ($file.FullName+': '+($errors.Message -join '; '))}
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    if($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191){throw ('PowerShell 5.1 中文脚本需要 UTF-8 BOM：'+$file.Name)}
}
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$checks=@(
    'skills\douyin-rpa\tests\Verify-Keywords.ps1',
    'skills\douyin-rpa\tests\Verify-Douyin.ps1',
    'skills\douyin-rpa\tests\Verify-Skill.ps1',
    'skills\douyin-rpa\tests\Verify-Monitor.ps1',
    'skills\douyin-reply-rpa\tests\Verify-ReplyCore.ps1',
    'skills\douyin-reply-rpa\tests\Verify-ReplyBrowser.ps1',
    'skills\douyin-reply-rpa\tests\Verify-ReplySession.ps1',
    'skills\douyin-reply-rpa\tests\Verify-ReplyUi.ps1',
    'skills\douyin-reply-rpa\tests\Verify-ReplyRouting.ps1',
    'skills\douyin-reply-rpa\tests\Verify-ReplyWorkflow.ps1',
    'skills\dingtalk-rpa\tests\Verify-Configuration.ps1',
    'skills\dingtalk-rpa\tests\Verify-DingTalkSkill.ps1',
    'skills\dingtalk-rpa\tests\Verify-DingTalkNavigation.ps1',
    'skills\dingtalk-rpa\tests\Verify-DingTalkSearch.ps1',
    'tests\Verify-Layout.ps1'
)
foreach($check in $checks){
    & $powershell -NoProfile -File (Join-Path $projectRoot $check)
    if($LASTEXITCODE -ne 0){throw ('验证失败：'+$check)}
}
[pscustomobject]@{Status='Passed';ParsedScripts=$psFiles.Count;TestSuites=$checks.Count;DesktopActions=0}
