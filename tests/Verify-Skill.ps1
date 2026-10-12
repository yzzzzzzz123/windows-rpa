[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $projectRoot ('work\skill-test-'+[Guid]::NewGuid().ToString('N'))
$build=& (Join-Path $projectRoot 'scripts\Build-Skill.ps1') -OutputRoot (Join-Path $testRoot 'packages')
$null=New-Item -ItemType Directory -Path $testRoot -Force
$entry=Join-Path $build.SkillRoot 'scripts\Invoke-DouyinSkill.ps1'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$data=Join-Path $testRoot 'data'
function Call-Skill([string]$Action,[string]$Id,[string]$TaskPath) {
    $parameters=@{Action=$Action;DataRoot=$data}
    if($Id){$parameters.JobId=$Id};if($TaskPath){$parameters.TaskFile=$TaskPath}
    $json=& $entry @parameters
    return ($json | ConvertFrom-Json)
}
function Wait-SkillState([string]$Id,[scriptblock]$Predicate) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        $status=Call-Skill 'Status' $Id
        if(& $Predicate $status){return $status}
        Start-Sleep -Milliseconds 150
    }while($timer.Elapsed.TotalSeconds -lt 20)
    throw ('等待状态超时：'+(ConvertTo-Json $status -Compress -Depth 6))
}
$check=Call-Skill 'Check'
if(-not $check.Ok -or -not $check.JobId){throw 'Skill 后台自检未成功启动。'}
$finished=Wait-SkillState $check.JobId {param($s)-not $s.Running}
if($finished.Status -ne 'SelfTestPassed'){throw '随包运行器自检失败。'}
$retired=Call-Skill 'Resume' $check.JobId
if($retired.Ok){throw '已结束任务被错误恢复。'}
. (Join-Path $build.SkillRoot 'scripts\Skill.Core.ps1')
$environment=Get-SkillEnvironment $data
$invalid=@(
    [pscustomobject]@{Mode='Publish'},[pscustomobject]@{Mode='Publish';Comment='测试';Continuous='true'},
    [pscustomobject]@{Mode='Preview';MaxVideos=0},[pscustomobject]@{Mode='Publish';Comment='测试';UnsafeOverride=$true},
    [pscustomobject]@{Mode='Preview';SearchTerms='不是数组'}
)
$rejected=0
foreach($task in $invalid){try{$null=New-SkillConfiguration $task $environment (Join-Path $testRoot 'invalid.json')}catch{$rejected++}}
if($rejected -ne $invalid.Count){throw '无效任务未被拒绝。'}
# A relocated package with a fixture runner exercises the real controller without desktop input.
$relocated=Join-Path $testRoot '中文 skill''s & $ 目录'
Copy-Item -LiteralPath $build.SkillRoot -Destination $relocated -Recurse
$entry=Join-Path $relocated 'scripts\Invoke-DouyinSkill.ps1'
$fixture=@'
[CmdletBinding()]
param([string]$ConfigPath,[string]$EvidenceRoot,[string]$StateRoot,[int]$MaxVideos,[switch]$Continuous,[switch]$Publish,[switch]$Inspect,[switch]$SelfTest,[switch]$PreserveControlSignals)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\core\RpaState.ps1')
Add-Type -Path (Join-Path $root 'src\native\DingRpa.cs')
$script:RunDirectory=Join-Path $EvidenceRoot 'fixture'
$null=New-Item -ItemType Directory -Path $script:RunDirectory -Force
$script:RunReport=[ordered]@{Status='Running';Stage='Waiting';Paused=$false;UpdatedAt=(Get-Date -Format o);Processed=0;Published=0;Previewed=0;Reason=$null}
try {
    Initialize-RpaState $StateRoot $root
    Set-RpaProgress 'Waiting'
    Wait-RpaDelay 40
    $script:RunReport.Status='Completed'
}catch [OperationCanceledException]{
    $script:RunReport.Status='Stopped'
}finally{
    $script:RunReport.Paused=$false
    Set-RpaProgress 'Finished'
    if($script:RpaRunLock){$script:RpaRunLock.Dispose()}
}
exit 0
'@
[IO.File]::WriteAllText((Join-Path $relocated 'scripts\Invoke-DouyinRpa.ps1'),$fixture,(New-Object Text.UTF8Encoding($true)))
$taskPath=Join-Path $testRoot 'task.json'
[IO.File]::WriteAllText($taskPath,'{"Mode":"Preview","Comment":"中文回读测试"}',(New-Object Text.UTF8Encoding($false)))
$fixtureId=$null
try {
    $started=Call-Skill 'Start' '' $taskPath
    if(-not $started.Ok){throw ('迁移后启动失败：'+$started.Error)}
    $fixtureId=$started.JobId
    $null=Wait-SkillState $fixtureId {param($s)$s.Status -eq 'Running'}
    $duplicate=Call-Skill 'Start' '' $taskPath
    if($duplicate.Ok){throw '同状态目录启动了重复实例。'}
    $snapshot=Read-SkillJson (Join-Path $data ('jobs\'+$fixtureId+'\config.json'))
    if($snapshot.Comment -cne '中文回读测试'){throw '任务中文配置丢失。'}
    $null=Call-Skill 'Pause' $fixtureId
    $paused=Wait-SkillState $fixtureId {param($s)$s.Paused -and $s.Status -eq 'Paused'}
    Start-Sleep -Milliseconds 2400
    $stillPaused=Call-Skill 'Status' $fixtureId
    if($stillPaused.HeartbeatAt -le $paused.HeartbeatAt -or $stillPaused.UpdatedAt -ne $paused.UpdatedAt -or $stillPaused.Health -ne 'Responsive'){throw '暂停期间未保持独立心跳，或心跳错误改写了进展时间。'}
    $wrong=Call-Skill 'Stop' $check.JobId
    if($wrong.Ok){throw '旧任务控制未被拒绝。'}
    $null=Call-Skill 'Resume' $fixtureId
    $null=Wait-SkillState $fixtureId {param($s)$s.Running -and -not $s.Paused -and -not $s.PauseRequested}
    $null=Call-Skill 'Stop' $fixtureId
    $stopped=Wait-SkillState $fixtureId {param($s)-not $s.Running}
    if($stopped.Status -ne 'Stopped'){throw '控制停止未正确结束任务。'}
    # The original PID with an incompatible start time must never be treated as alive.
    $identity=Read-SkillJson (Join-Path $data ('jobs\'+$fixtureId+'\job.json'))
    $identity.ProcessId=$PID;$identity.ProcessStartTicks='1'
    if(Test-SkillProcess $identity){throw '复用的 PID 被错误认为任务仍存活。'}
    $report=[ordered]@{Status='Passed';PortableRuntimeCheck=$true;InvalidTasksRejected=$rejected;DuplicateStartRejected=$true;PauseAcknowledged=$true;ResumeAcknowledged=$true;StopAcknowledged=$true;RetiredJobControlRejected=$true;ProcessIdentityChecked=$true;UnicodeConfiguration=$true;RelocatedSpecialCharacterPath=$true;DesktopActions=0;TestRoot=$testRoot}
    Write-SkillJson $report (Join-Path $testRoot 'result.json')
    [pscustomobject]$report
}finally{
    if($fixtureId){$remaining=Call-Skill 'Status' $fixtureId;if($remaining.Running){$null=Call-Skill 'Stop' $fixtureId}}
}
