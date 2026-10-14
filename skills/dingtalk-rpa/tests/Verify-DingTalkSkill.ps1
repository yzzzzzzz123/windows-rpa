[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$testWorkspace=Join-Path $repositoryRoot 'artifacts\work'
$testRoot=Join-Path $testWorkspace ('dingtalk-skill-test-'+[Guid]::NewGuid().ToString('N'))
$entrySource=Join-Path $projectRoot 'scripts\Invoke-DingTalkRpa.ps1'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$fixtureProject=Join-Path $testRoot '中文项目''s & $ 目录'
$fixtureSkill=Join-Path $fixtureProject 'skills\dingtalk-rpa'
$fixtureEntry=Join-Path $fixtureSkill 'scripts\Invoke-DingTalkRpa.ps1'
$junctionPath=Join-Path $testRoot '.codex\skills\dingtalk-rpa'
function Assert-DingTalkSkill([bool]$Condition,[string]$Reason){if(-not $Condition){throw $Reason}}
function Call-DingTalkEntry([string]$Entry,[hashtable]$Parameters=@{}) {
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json ([ordered]@{Entry=$Entry;Parameters=$Parameters}) -Depth 5 -Compress)))
    $command=@'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$ErrorActionPreference='Stop'
$request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
$arguments=@{}
foreach($property in $request.Parameters.PSObject.Properties){$arguments[$property.Name]=$property.Value}
& $request.Entry @arguments
exit $LASTEXITCODE
'@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command.Replace('__PAYLOAD__',$payload)))
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$powershell;$start.Arguments='-NoLogo -NoProfile -NonInteractive -EncodedCommand '+$encoded
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8;$start.StandardErrorEncoding=[Text.Encoding]::UTF8
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start
    try{
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(20000)){$process.Kill();throw '钉钉 Skill 无桌面测试超过 20 秒。'}
        return [pscustomobject]@{ExitCode=$process.ExitCode;Output=$stdout.Result;Error=$stderr.Result}
    }finally{$process.Dispose()}
}
function Get-DouyinStateFingerprint([string]$Root) {
    $parts=New-Object 'Collections.Generic.List[string]'
    foreach($relative in @('data\douyin-rpa\state','data\douyin-rpa\jobs')){
        $statePath=Join-Path $Root $relative
        if(-not (Test-Path -LiteralPath $statePath)){continue}
        foreach($file in @(Get-ChildItem -LiteralPath $statePath -Recurse -File | Sort-Object FullName)){
            $parts.Add($file.FullName+'|'+$file.Length+'|'+$file.LastWriteTimeUtc.Ticks)
        }
    }
    return $parts -join "`n"
}
try{
    foreach($relative in @('skills\dingtalk-rpa\scripts','skills\dingtalk-rpa\config','skills\dingtalk-rpa\src\workflows')){$null=[IO.Directory]::CreateDirectory((Join-Path $fixtureProject $relative))}
    Copy-Item -LiteralPath $entrySource -Destination $fixtureEntry
    Copy-Item -LiteralPath (Join-Path $projectRoot 'scripts\DingTalk.Paths.ps1') -Destination (Join-Path $fixtureSkill 'scripts\DingTalk.Paths.ps1')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'shared') -Destination (Join-Path $fixtureProject 'shared') -Recurse
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Destination (Join-Path $fixtureProject 'VERSION')
    $fixture=@'
[CmdletBinding()]
param([string]$Scenario,[string]$ConfigPath,[string]$EvidenceRoot,[switch]$SelfTest,[switch]$WaitForKey)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$observation=[ordered]@{Scenario=$Scenario;ConfigPath=$ConfigPath;EvidenceRoot=$EvidenceRoot;SelfTest=[bool]$SelfTest;WaitForKey=[bool]$WaitForKey;ParameterNames=@($PSBoundParameters.Keys|Sort-Object)}
$json=ConvertTo-Json $observation -Compress -Depth 5
[IO.File]::WriteAllText((Join-Path $root 'invoked.json'),$json,(New-Object Text.UTF8Encoding($false)))
$json
$code=[int]([IO.File]::ReadAllText((Join-Path $root 'exit-code.txt')))
exit $code
'@
    [IO.File]::WriteAllText((Join-Path $fixtureSkill 'scripts\Invoke-DingTalkNative.ps1'),$fixture,(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText((Join-Path $fixtureSkill 'config\dingtalk.json'),'{}')
    [IO.File]::WriteAllText((Join-Path $fixtureSkill 'src\workflows\DingTalk.AppCenter.ps1'),'# 离线依赖占位；不得执行桌面。')
    $exitPath=Join-Path $fixtureSkill 'exit-code.txt';[IO.File]::WriteAllText($exitPath,'0')
    $cases=@(
        @{Parameters=@{};Scenario='AppCenterLowCode';SelfTest=$false;Wait=$false},
        @{Parameters=@{Mode='Check'};Scenario='AppCenterLowCode';SelfTest=$true;Wait=$false},
        @{Parameters=@{Mode='Inspect'};Scenario='Inspect';SelfTest=$false;Wait=$false},
        @{Parameters=@{Mode='Run';WaitForKey=$true};Scenario='AppCenterLowCode';SelfTest=$false;Wait=$true}
    )
    foreach($case in $cases){
        $result=Call-DingTalkEntry $fixtureEntry $case.Parameters
        Assert-DingTalkSkill ($result.ExitCode -eq 0) ('夹具路由失败：'+$result.Error)
        $observed=$result.Output | ConvertFrom-Json
        Assert-DingTalkSkill ($observed.Scenario -eq $case.Scenario -and $observed.SelfTest -eq $case.SelfTest -and $observed.WaitForKey -eq $case.Wait) '模式没有固定映射到钉钉场景。'
        Assert-DingTalkSkill ($observed.ConfigPath -ceq (Join-Path $fixtureSkill 'config\dingtalk.json') -and $observed.EvidenceRoot -ceq (Join-Path $fixtureProject 'data\dingtalk-rpa\runs')) '钉钉配置或证据路径未隔离。'
        Assert-DingTalkSkill (($observed.ParameterNames -join ',') -eq 'ConfigPath,EvidenceRoot,Scenario,SelfTest,WaitForKey') '薄入口传递了额外运行参数。'
    }
    foreach($code in @(1,2,7)){
        [IO.File]::WriteAllText($exitPath,$code.ToString());$result=Call-DingTalkEntry $fixtureEntry @{Mode='Run'}
        Assert-DingTalkSkill ($result.ExitCode -eq $code) '运行器退出码未原样透传。'
    }
    [IO.File]::WriteAllText($exitPath,'0')
    $null=[IO.Directory]::CreateDirectory((Split-Path $junctionPath -Parent))
    $null=New-Item -ItemType Junction -Path $junctionPath -Value $fixtureSkill
    $linked=Call-DingTalkEntry (Join-Path $junctionPath 'scripts\Invoke-DingTalkRpa.ps1') @{Mode='Inspect'}
    Assert-DingTalkSkill ($linked.ExitCode -eq 0) ('技能发现目录 junction 定位失败：'+$linked.Error)
    $observed=$linked.Output|ConvertFrom-Json
    Assert-DingTalkSkill ($observed.ConfigPath -ceq (Join-Path $fixtureSkill 'config\dingtalk.json') -and $observed.Scenario -eq 'Inspect') 'junction 调用使用了错误的项目根或场景。'
    $rejected=0
    foreach($bad in @(@{Mode='DouyinComment'},@{Scenario='DouyinComment'},@{Publish=$true},@{Continuous=$true},@{StateRoot=$testRoot})){
        $before=(Get-Item -LiteralPath (Join-Path $fixtureSkill 'invoked.json')).LastWriteTimeUtc.Ticks
        $result=Call-DingTalkEntry $fixtureEntry $bad
        $after=(Get-Item -LiteralPath (Join-Path $fixtureSkill 'invoked.json')).LastWriteTimeUtc.Ticks
        if($result.ExitCode -ne 0 -and $before -eq $after){$rejected++}
    }
    Assert-DingTalkSkill ($rejected -eq 5) '未拒绝错误模式或抖音/任意场景参数。'
    $missingBlocked=0
    foreach($relative in @('scripts\Invoke-DingTalkNative.ps1','config\dingtalk.json','src\workflows\DingTalk.AppCenter.ps1')){
        $dependency=Join-Path $fixtureSkill $relative
        [IO.File]::Move($dependency,$dependency+'.held')
        try{
            $before=(Get-Item -LiteralPath (Join-Path $fixtureSkill 'invoked.json')).LastWriteTimeUtc.Ticks
            $missing=Call-DingTalkEntry $fixtureEntry @{Mode='Run'}
            Assert-DingTalkSkill ($missing.ExitCode -ne 0 -and (Get-Item -LiteralPath (Join-Path $fixtureSkill 'invoked.json')).LastWriteTimeUtc.Ticks -eq $before) ('依赖缺失时仍启动运行器：'+$relative)
            $missingBlocked++
        }finally{[IO.File]::Move($dependency+'.held',$dependency)}
    }
    # 唯一真实调用是原生产代码的 SelfTest，在隔离副本运行，不读取或污染活动任务。
    $liveProject=Join-Path $testRoot '真实自检副本'
    $null=New-Item -ItemType Directory -Path (Join-Path $liveProject 'skills') -Force
    foreach($relative in @('shared','VERSION')){Copy-Item -LiteralPath (Join-Path $repositoryRoot $relative) -Destination (Join-Path $liveProject $relative) -Recurse}
    $liveSkill=Join-Path $liveProject 'skills\dingtalk-rpa'
    $null=New-Item -ItemType Directory -Path $liveSkill -Force
    foreach($relative in @('scripts','src','config')){Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination (Join-Path $liveSkill $relative) -Recurse}
    foreach($relative in @('data\douyin-rpa\state','data\douyin-rpa\jobs')){
        $statePath=Join-Path $liveProject $relative;$null=[IO.Directory]::CreateDirectory($statePath)
        [IO.File]::WriteAllText((Join-Path $statePath 'unchanged.txt'),'抖音状态不可修改')
    }
    $liveRoot=Join-Path $liveProject 'data\dingtalk-rpa\runs'
    $douyinBefore=Get-DouyinStateFingerprint $liveProject
    $live=Call-DingTalkEntry (Join-Path $liveProject 'skills\dingtalk-rpa\scripts\Invoke-DingTalkRpa.ps1') @{Mode='Check'}
    $liveEvidenceCreated=@(Get-ChildItem -LiteralPath $liveRoot -Directory -ErrorAction SilentlyContinue)
    Assert-DingTalkSkill ($live.ExitCode -eq 0 -and $liveEvidenceCreated.Count -eq 1) ('真实无桌面自检失败：'+$live.Error)
    $liveReport=Get-Content -LiteralPath (Join-Path $liveEvidenceCreated[0].FullName 'result.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-DingTalkSkill ($liveReport.Status -eq 'SelfTestPassed' -and $liveReport.DesktopInputPerformed -eq $false) '真实 Check 没有返回无桌面自检结果。'
    Assert-DingTalkSkill ((Get-DouyinStateFingerprint $liveProject) -ceq $douyinBefore) '真实 Check 改写了抖音状态。'
    [pscustomobject]@{Status='Passed';DefaultRun=$true;FixedModeMappings=3;ExitCodePassthrough=$true;RejectedParameters=$rejected;MissingDependenciesBlocked=$missingBlocked;UnicodeSpecialPath=$true;DiscoveryJunction=$true;LiveCheck=$true;DouyinStateUnchanged=$true;DesktopActions=0}
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot);$workRoot=[IO.Path]::GetFullPath($testWorkspace)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($workRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^dingtalk-skill-test-[a-f0-9]{32}$'){throw '拒绝清理未确认的钉钉 Skill 测试目录。'}
    if(Test-Path -LiteralPath $junctionPath){[IO.Directory]::Delete($junctionPath)}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
