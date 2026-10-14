[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Describe','Check','Start','Status','Pause','Resume','Stop','Monitor')][string]$Action,
    [string]$TaskFile,[string]$JobId,[string]$DataRoot
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Skill.Core.ps1')
$dispatchLock=$null
try {
    $environment=Get-SkillEnvironment $DataRoot
    if($Action -eq 'Describe'){
        $output=[ordered]@{Ok=$true;Skill='douyin-rpa';Version=(Get-Content -LiteralPath $environment.VersionPath -Raw).Trim();Paths=$environment;Defaults=(Read-SkillJson (Join-Path $environment.RuntimeRoot 'config\douyin.json'));Actions=@('Check','Start','Status','Pause','Resume','Stop','Monitor');Modes=@('Preview','Publish','Inspect','Check')}
    }elseif($Action -eq 'Status'){
        $output=Get-SkillStatus $environment $JobId
    }elseif($Action -eq 'Monitor'){
        $output=Start-SkillMonitor $environment
        $output | Add-Member NoteProperty Ok $true
    }else{
        $null=New-Item -ItemType Directory -Path $environment.StateRoot -Force
        $dispatchLock=[IO.File]::Open((Join-Path $environment.StateRoot 'skill-dispatch.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $activeFile=Join-Path $environment.StateRoot 'skill-active.json'
        $active=if(Test-Path -LiteralPath $activeFile){Read-SkillJson $activeFile}else{$null}
        if($Action -in @('Start','Check')){
            if($active -and (Test-SkillProcess $active)){throw ('已有 Skill 任务正在运行：'+$active.JobId)}
            $runtimeLock=[IO.File]::Open((Join-Path $environment.StateRoot 'runner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $runtimeLock.Dispose()
            $task=if($Action -eq 'Check'){[pscustomobject]@{Mode='Check'}}else{if(-not $TaskFile){throw 'Start 需要 TaskFile。'};Read-SkillJson $TaskFile}
            $newId=(Get-Date -Format 'yyyyMMdd_HHmmssfff')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,12)
            $jobDir=Get-SkillJobPath $environment $newId
            $null=New-Item -ItemType Directory -Path $jobDir -Force
            $configPath=Join-Path $jobDir 'config.json'
            $normalized=New-SkillConfiguration $task $environment $configPath
            $null=New-Item -ItemType Directory -Path (Join-Path $jobDir 'evidence') -Force
            Write-SkillJson $task (Join-Path $jobDir 'request.json')
            $control=Join-Path $environment.StateRoot 'control'
            $null=New-Item -ItemType Directory -Path $control -Force
            foreach($name in @('stop','pause')){$path=Join-Path $control $name;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
            $job=[ordered]@{JobId=$newId;Mode=$normalized.Mode;Continuous=$normalized.Continuous;MaxVideos=$normalized.MaxVideos;RuntimeRoot=$environment.RuntimeRoot;StateRoot=$environment.StateRoot;DataRoot=$environment.DataRoot;ConfigPath=$configPath;EvidenceRoot=(Join-Path $jobDir 'evidence');CreatedAt=(Get-Date -Format o);ProcessId=$null;ProcessStartTicks=$null}
            $jobPath=Join-Path $jobDir 'job.json'
            Write-SkillJson $job $jobPath
            $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arguments='-NoProfile -NonInteractive -File '+(ConvertTo-SkillArgument (Join-Path $PSScriptRoot 'Invoke-RpaWorker.ps1'))+' -JobFile '+(ConvertTo-SkillArgument $jobPath)
            $process=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $jobDir 'stdout.log') -RedirectStandardError (Join-Path $jobDir 'stderr.log')
            $job.ProcessId=$process.Id;$job.ProcessStartTicks=$process.StartTime.ToUniversalTime().Ticks.ToString()
            Write-SkillJson $job $jobPath
            Write-SkillJson $job $activeFile
            Write-SkillJson ([ordered]@{JobId=$newId}) (Join-Path $environment.DataRoot 'latest.json')
            $output=Get-SkillStatus $environment $newId
            if($normalized.Continuous){
                try{$null=Start-SkillMonitor $environment;$output=Get-SkillStatus $environment $newId}catch{$output | Add-Member NoteProperty MonitorError $_.Exception.Message}
            }
        }else{
            $current=Get-SkillStatus $environment $JobId
            if(-not $current.Running){throw '该任务已经结束；控制指令不会重新启动它。'}
            if(-not $active -or $active.JobId -ne $current.JobId -or $active.DataRoot -ne $environment.DataRoot){throw '任务不是此状态目录的当前实例，拒绝控制其他任务。'}
            $control=Join-Path $current.StateRoot 'control'
            if($Action -eq 'Resume'){
                if(Test-Path -LiteralPath (Join-Path $control 'stop')){throw '已请求停止的任务不能恢复。'}
                $path=Join-Path $control 'pause';if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
            }else{
                $name=if($Action -eq 'Pause'){'pause'}else{'stop'}
                [IO.File]::WriteAllText((Join-Path $control $name),(Get-Date -Format o))
            }
            $output=Get-SkillStatus $environment $current.JobId
            $output | Add-Member NoteProperty ControlRequested $Action
        }
    }
    $output | ConvertTo-Json -Depth 14
}catch{
    [ordered]@{Ok=$false;Action=$Action;Error=$_.Exception.Message} | ConvertTo-Json -Depth 5
    exit 1
}finally{if($dispatchLock){$dispatchLock.Dispose()}}
