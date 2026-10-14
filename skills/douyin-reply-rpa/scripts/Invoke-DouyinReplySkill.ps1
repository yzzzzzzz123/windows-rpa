[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Describe','Start','Status','Pause','Resume','Stop','Candidates')][string]$Action,
    [string]$TaskFile,[string]$JobId,[string]$DataRoot,
    [ValidateSet('Auto','Local','Interactive')][string]$LaunchMode='Auto'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Reply.Core.ps1')
$dispatchLock=$null
try{
    $environment=Get-ReplyEnvironment $DataRoot
    if($Action -eq 'Start' -and ($LaunchMode -eq 'Interactive' -or ($LaunchMode -eq 'Auto' -and (Get-ReplyCallerSessionId) -eq 0))){
        $output=Invoke-ReplyInteractiveStart $environment $TaskFile
        $output | ConvertTo-Json -Depth 20
        if(-not $output.Ok){exit 1}
        return
    }
    if($Action -eq 'Describe'){
        $output=[ordered]@{Ok=$true;Skill='douyin-reply-rpa';Version=(Get-Content -LiteralPath $environment.VersionPath -Raw -Encoding UTF8).Trim();Paths=$environment;Defaults=(Read-ReplyJson (Join-Path $environment.RuntimeRoot 'config\reply.json'));Actions=@('Describe','Start','Status','Pause','Resume','Stop','Candidates');Modes=@('Discover','Preview','Publish');LaunchModes=@('Auto','Local','Interactive')}
    }elseif($Action -eq 'Status'){
        $output=Get-ReplyStatus $environment $JobId
        $pendingPath=Join-Path $environment.StateRoot 'interactive-launch.json'
        $output|Add-Member NoteProperty LaunchPending (Test-Path -LiteralPath $pendingPath) -Force
        if(Test-Path -LiteralPath $pendingPath){
            $pending=Read-ReplyJson $pendingPath
            $output|Add-Member NoteProperty LaunchId $pending.LaunchId -Force
            $output|Add-Member NoteProperty LaunchSessionId $pending.SessionId -Force
            $output|Add-Member NoteProperty LaunchReceiptPath $pending.ReceiptPath -Force
            $output|Add-Member NoteProperty LaunchStatus $(if(Test-Path -LiteralPath $pending.ReceiptPath){'ReceiptReady'}else{'Pending'}) -Force
        }
    }elseif($Action -eq 'Candidates'){$output=Get-ReplyCandidates $environment $JobId
    }else{
        $null=New-Item -ItemType Directory -Path $environment.StateRoot -Force
        $dispatchLock=[IO.File]::Open((Join-Path $environment.StateRoot 'skill-dispatch.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $activeFile=Join-Path $environment.StateRoot 'skill-active.json'
        $active=if(Test-Path -LiteralPath $activeFile){Read-ReplyJson $activeFile}else{$null}
        if($Action -eq 'Start'){
            $pendingPath=Join-Path $environment.StateRoot 'interactive-launch.json'
            if(Test-Path -LiteralPath $pendingPath){
                $pending=Read-ReplyJson $pendingPath
                $snapshot=Join-Path $environment.DataRoot ('launches\'+$pending.LaunchId+'\task.json')
                if(-not $TaskFile -or [IO.Path]::GetFullPath($TaskFile) -ne $snapshot -or (Get-ReplyCallerSessionId) -ne $pending.SessionId){throw '存在尚未确认的交互启动，禁止另建任务。'}
            }
            if($active -and (Test-ReplyProcess $active)){throw ('已有回复任务正在运行：'+$active.JobId)}
            if(-not $TaskFile){throw 'Start 需要 TaskFile。'}
            $task=Read-ReplyJson $TaskFile
            $newId=(Get-Date -Format 'yyyyMMdd_HHmmssfff')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,12)
            $jobDir=Get-ReplyJobPath $environment $newId
            $null=New-Item -ItemType Directory -Path $jobDir -Force
            $configPath=Join-Path $jobDir 'config.json'
            $normalized=New-ReplyConfiguration $task $environment $configPath
            $workerPath=Join-Path $environment.RuntimeRoot 'scripts\Invoke-DouyinReplyWorker.ps1'
            if(-not (Test-Path -LiteralPath $workerPath -PathType Leaf)){throw '缺少回复任务运行器。'}
            $null=New-Item -ItemType Directory -Path $environment.SharedSubmissionRoot -Force
            $probe=[IO.File]::Open((Join-Path $environment.SharedSubmissionRoot 'runner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $probe.Dispose()
            $evidence=Join-Path $jobDir 'evidence'
            $null=New-Item -ItemType Directory -Path $evidence -Force
            Write-ReplyJson $task (Join-Path $jobDir 'request.json')
            $control=Join-Path $environment.StateRoot 'control'
            $null=New-Item -ItemType Directory -Path $control -Force
            foreach($name in @('stop','pause')){$path=Join-Path $control $name;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
            $job=[ordered]@{JobId=$newId;Mode=$normalized.Mode;RuntimeRoot=$environment.RuntimeRoot;StateRoot=$environment.StateRoot;SharedSubmissionRoot=$environment.SharedSubmissionRoot;DataRoot=$environment.DataRoot;ConfigPath=$configPath;EvidenceRoot=$evidence;CreatedAt=(Get-Date -Format o);ProcessId=$null;ProcessStartTicks=$null}
            $jobPath=Join-Path $jobDir 'job.json'
            Write-ReplyJson $job $jobPath
            $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arguments='-NoProfile -NonInteractive -STA -File '+(ConvertTo-ReplyArgument $workerPath)+' -JobFile '+(ConvertTo-ReplyArgument $jobPath)
            $process=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $jobDir 'stdout.log') -RedirectStandardError (Join-Path $jobDir 'stderr.log')
            $job.ProcessId=$process.Id;$job.ProcessStartTicks=$process.StartTime.ToUniversalTime().Ticks.ToString()
            Write-ReplyJson $job $jobPath
            Write-ReplyJson $job $activeFile
            Write-ReplyJson ([ordered]@{JobId=$newId}) (Join-Path $environment.DataRoot 'latest.json')
            $output=Get-ReplyStatus $environment $newId
        }else{$output=Invoke-ReplyControl $environment $Action $JobId $active}
    }
    $output | ConvertTo-Json -Depth 20
}catch{
    [ordered]@{Ok=$false;Action=$Action;Error=$_.Exception.Message} | ConvertTo-Json -Depth 6
    exit 1
}finally{if($dispatchLock){$dispatchLock.Dispose()}}
