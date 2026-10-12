[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$psFiles=@(Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter '*.ps1' -File | Where-Object {$_.FullName -notmatch '[\\/]evidence[\\/]'})
foreach($file in $psFiles){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw ($file.Name+': '+($errors.Message -join '; '))}
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    if($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191){throw ('PowerShell 5.1 中文脚本需要 UTF-8 BOM：'+$file.Name)}
}
. (Join-Path $projectRoot 'src\core\Configuration.ps1')
$null=Read-RpaConfiguration (Join-Path $projectRoot 'config\dingtalk.json')
$testDir=Join-Path $projectRoot ('work\verify-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
$original=Get-Content -LiteralPath (Join-Path $projectRoot 'config\dingtalk.json') -Raw -Encoding UTF8
$invalidCases=@($original.Replace('"MaxWheelRounds": 40','"MaxWheelRounds": 0'),$original.Replace('navigator_view.AppCenter','unrelated.button'),$original.Replace('"LabelAttempts": 8','"LabelAttempts": 1.5'))
foreach($case in $invalidCases){
    $path=Join-Path $testDir 'invalid.json'
    [IO.File]::WriteAllText($path,$case,(New-Object Text.UTF8Encoding($false)))
    $rejected=$false
    try{$null=Read-RpaConfiguration $path}catch{$rejected=$true}
    if(-not $rejected){throw '无效配置未被拒绝。'}
}
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $powershell -NoProfile -File (Join-Path $projectRoot 'scripts\Invoke-Rpa.ps1') -SelfTest -EvidenceRoot (Join-Path $testDir 'evidence')
if($LASTEXITCODE -ne 0){throw '原生接口自检失败。'}
$reportPath=Get-ChildItem -LiteralPath (Join-Path $testDir 'evidence') -Filter result.json -File -Recurse | Select-Object -First 1
$report=Get-Content -LiteralPath $reportPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
if($report.Status -ne 'SelfTestPassed' -or $report.DesktopInputPerformed -ne $false){throw '自检结果异常。'}
[pscustomobject]@{Status='Passed';ParsedScripts=$psFiles.Count;InvalidConfigurationsRejected=$invalidCases.Count;NativeCompile=$true;DesktopActions=0;TestReport=$reportPath.FullName}
