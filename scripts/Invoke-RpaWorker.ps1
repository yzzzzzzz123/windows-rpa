[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$JobFile)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'Skill.Core.ps1')
$jobDir=Split-Path $JobFile -Parent
$worker=[ordered]@{Status='Starting';ExitCode=$null;Reason=$null;FinishedAt=$null}
try {
    $job=Read-SkillJson $JobFile
    $arguments=@{ConfigPath=$job.ConfigPath;EvidenceRoot=$job.EvidenceRoot;StateRoot=$job.StateRoot;MaxVideos=[int]$job.MaxVideos;Continuous=[bool]$job.Continuous;Publish=($job.Mode -eq 'Publish');Inspect=($job.Mode -eq 'Inspect');SelfTest=($job.Mode -eq 'Check');PreserveControlSignals=$true}
    & (Join-Path $job.RuntimeRoot 'scripts\Invoke-DouyinRpa.ps1') @arguments
    $worker.ExitCode=$LASTEXITCODE
    $worker.Status=if($LASTEXITCODE -eq 0){'Finished'}else{'Failed'}
}catch{
    $worker.Status='Failed';$worker.ExitCode=1;$worker.Reason=$_.Exception.Message
}finally{
    $worker.FinishedAt=Get-Date -Format o
    Write-SkillJson $worker (Join-Path $jobDir 'worker-result.json')
}
exit $worker.ExitCode
