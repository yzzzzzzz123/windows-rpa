[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$skillRoot=Split-Path $PSScriptRoot -Parent
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $skillRoot 'src\core\Configuration.ps1')
$null=Read-RpaConfiguration (Join-Path $skillRoot 'config\dingtalk.json')
$testRoot=Join-Path $root ('artifacts\work\config-test-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot -Force
try {
    $original=Get-Content -LiteralPath (Join-Path $skillRoot 'config\dingtalk.json') -Raw -Encoding UTF8
    $invalidCases=@($original.Replace('"MaxWheelRounds": 40','"MaxWheelRounds": 0'),$original.Replace('navigator_view.AppCenter','unrelated.button'),$original.Replace('"LabelAttempts": 8','"LabelAttempts": 1.5'))
    foreach($case in $invalidCases){
        $path=Join-Path $testRoot 'invalid.json'
        [IO.File]::WriteAllText($path,$case,(New-Object Text.UTF8Encoding($false)))
        $rejected=$false
        try{$null=Read-RpaConfiguration $path}catch{$rejected=$true}
        if(-not $rejected){throw '无效配置未被拒绝。'}
    }
    [pscustomobject]@{Status='Passed';InvalidConfigurationsRejected=$invalidCases.Count;DesktopActions=0}
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=[IO.Path]::GetFullPath((Join-Path $root 'artifacts\work'))+'\'
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notmatch '^config-test-[a-f0-9]{32}$'){throw '拒绝清理未知配置测试目录。'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
