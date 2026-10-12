[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\Skill.Core.ps1')
$data=Join-Path $root ('work\monitor-test-'+[Guid]::NewGuid().ToString('N'))
$environment=Get-SkillEnvironment $data
$id='20260101_000000000-0123456789ab'
$jobDir=Get-SkillJobPath $environment $id
$reportDir=Join-Path $jobDir 'evidence\fixture'
$null=New-Item -ItemType Directory -Path $reportDir -Force
$job=[ordered]@{JobId=$id;Mode='Preview';StateRoot=$environment.StateRoot;ProcessId=$PID;ProcessStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()}
Write-SkillJson $job (Join-Path $jobDir 'job.json')
Write-SkillJson @{JobId=$id} (Join-Path $data 'latest.json')
$report=[ordered]@{Status='Running';Stage='WaitingForInterval';UpdatedAt=(Get-Date -Format o);HeartbeatAt=(Get-Date -Format o);CommentIntervalSeconds=10;NextSubmissionAt=[DateTimeOffset]::Now.AddSeconds(10).ToString('o');Processed=2;Submitted=1;Skipped=1}
Write-SkillJson $report (Join-Path $reportDir 'result.json')
function Wait-Monitor([scriptblock]$Predicate){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        $path=Join-Path $data 'monitor\status.json'
        if(Test-Path -LiteralPath $path){$value=Read-SkillJson $path;if(& $Predicate $value){return $value}}
        Start-Sleep -Milliseconds 150
    }while($timer.Elapsed.TotalSeconds -lt 15)
    throw ('监控状态未更新：'+(ConvertTo-Json $value -Depth 8 -Compress))
}
$observer=$null
try {
    $observer=Start-SkillMonitor $environment -Headless
    $identity=Read-SkillJson (Join-Path $data 'monitor\process.json')
    $again=Start-SkillMonitor $environment -Headless
    if($again.ProcessId -ne $observer.ProcessId){throw '重复启动了监控进程。'}
    $first=Wait-Monitor {param($s)$s.Health -eq 'Responsive' -and $s.Task.Submitted -eq 1}
    if($first.Task.CommentIntervalSeconds -ne 10 -or -not $first.Task.MonitorRunning){throw '运行间隔或监控身份错误。'}
    $next=Wait-Monitor {param($s)$s.MonitorUpdatedAt -gt $first.MonitorUpdatedAt}
    $report.HeartbeatAt=[DateTimeOffset]::Now.AddMinutes(-2).ToString('o')
    Write-SkillJson $report (Join-Path $reportDir 'result.json')
    $null=Wait-Monitor {param($s)$s.Health -eq 'Stalled' -and $s.Task.Running}
    $report.HeartbeatAt=Get-Date -Format o;$report.Status='WaitingForVerification'
    Write-SkillJson $report (Join-Path $reportDir 'result.json')
    $null=Wait-Monitor {param($s)$s.Headline -like '*验证码*'}
    $job.ProcessStartTicks='1'
    Write-SkillJson $job (Join-Path $jobDir 'job.json')
    $null=Wait-Monitor {param($s)-not $s.Task.Running -and $s.Task.Status -eq 'Interrupted'}
    $newId='20260101_000000001-0123456789ac'
    $newDir=Get-SkillJobPath $environment $newId
    $null=New-Item -ItemType Directory -Path (Join-Path $newDir 'evidence\fixture') -Force
    $job.JobId=$newId;$job.ProcessStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()
    $report.Status='Running';$report.HeartbeatAt=Get-Date -Format o
    Write-SkillJson $job (Join-Path $newDir 'job.json')
    Write-SkillJson $report (Join-Path $newDir 'evidence\fixture\result.json')
    Write-SkillJson @{JobId=$newId} (Join-Path $data 'latest.json')
    $null=Wait-Monitor {param($s)$s.Task.JobId -eq $newId -and $s.Health -eq 'Responsive'}
    [pscustomobject]@{Status='Passed';ObserverSingleton=$true;SnapshotRefresh=$true;StallDetected=$true;CaptchaDetected=$true;ExitDetected=$true;NewJobFollowed=$true;DesktopActions=0;TestRoot=$data}
}finally{
    if($identity -and (Test-SkillProcess $identity)){Stop-Process -Id $identity.ProcessId -Force}
}
