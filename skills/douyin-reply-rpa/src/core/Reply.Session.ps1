function Get-ReplyCallerSessionId {return [Diagnostics.Process]::GetCurrentProcess().SessionId}
function Get-ReplyCallerSid {return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
function Get-ReplyUserSessions($EnvInfo) {
    if(-not ('ReplySession' -as [type])){Add-Type -Path (Join-Path $EnvInfo.RuntimeRoot 'src\native\ReplySession.cs')}
    return [ReplySession]::List()
}
function Select-ReplyUserSession($Sessions,[string]$UserSid) {
    $matches=@($Sessions | Where-Object {$_.Active -and $_.SessionId -gt 0 -and $_.UserSid -ceq $UserSid})
    if($matches.Count -ne 1){throw ('需要同一账号唯一的活动 Windows 用户会话，当前匹配数量：'+$matches.Count)}
    return [int]$matches[0].SessionId
}
function New-ReplySessionTask($Service,$EnvInfo,[string]$RequestFile,[string]$UserSid) {
    $definition=$Service.NewTask(0)
    $definition.RegistrationInfo.Description='抖音回复 Skill 单次交互会话启动桥接；无定时触发。'
    $definition.Principal.UserId=$UserSid
    $definition.Principal.LogonType=3 # TASK_LOGON_INTERACTIVE_TOKEN; no credentials.
    $definition.Principal.RunLevel=0 # TASK_RUNLEVEL_LUA; no elevation.
    $definition.Settings.Enabled=$true
    $definition.Settings.AllowDemandStart=$true
    $definition.Settings.DisallowStartIfOnBatteries=$false
    $definition.Settings.StopIfGoingOnBatteries=$false
    $definition.Settings.ExecutionTimeLimit='PT1M'
    $definition.Settings.RestartCount=0
    $definition.Settings.MultipleInstances=2 # IgnoreNew.
    $action=$definition.Actions.Create(0)
    $action.Path=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action.Arguments='-NoProfile -NonInteractive -STA -WindowStyle Hidden -File '+(ConvertTo-ReplyArgument (Join-Path $EnvInfo.RuntimeRoot 'scripts\Invoke-DouyinReplySession.ps1'))+' -RequestFile '+(ConvertTo-ReplyArgument $RequestFile)
    $action.WorkingDirectory=$EnvInfo.RuntimeRoot
    return $definition
}
function Start-ReplySessionTask($EnvInfo,[string]$RequestFile,[string]$TaskName,[int]$SessionId,[string]$UserSid) {
    $service=New-Object -ComObject Schedule.Service
    $service.Connect()
    $folder=$service.GetFolder('\')
    $definition=New-ReplySessionTask $service $EnvInfo $RequestFile $UserSid
    $registered=$false
    try{
        $task=$folder.RegisterTaskDefinition($TaskName,$definition,2,$UserSid,$null,3,$null) # TASK_CREATE only.
        $registered=$true
        $null=$task.RunEx($null,4,$SessionId,$null) # TASK_RUN_USE_SESSION_ID.
    }catch{
        if($registered){try{$folder.DeleteTask($TaskName,0)}catch{}}
        throw
    }
}
function Remove-ReplySessionTask([string]$TaskName) {
    $service=New-Object -ComObject Schedule.Service
    $service.Connect()
    $service.GetFolder('\').DeleteTask($TaskName,0)
}
function Wait-ReplySessionReceipt([string]$Path) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($timer.Elapsed.TotalSeconds -lt 25){
        if(Test-Path -LiteralPath $Path){return Read-ReplyJson $Path}
        Start-Sleep -Milliseconds 150
    }
    throw ('交互会话启动结果尚不明确，禁止自动重试；保留启动记录：'+$Path)
}
function Invoke-ReplyInteractiveStart($EnvInfo,[string]$TaskFile) {
    if(-not $TaskFile){throw 'Start 需要 TaskFile。'}
    $null=New-Item -ItemType Directory -Path $EnvInfo.StateRoot -Force
    $lock=$null
    $pendingPath=Join-Path $EnvInfo.StateRoot 'interactive-launch.json'
    try{
        $lock=[IO.File]::Open((Join-Path $EnvInfo.StateRoot 'skill-session-launch.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        # An unacknowledged launch must never be replaced by another launch.
        if(Test-Path -LiteralPath $pendingPath){
            $pending=Read-ReplyJson $pendingPath
            if(-not (Test-Path -LiteralPath $pending.ReceiptPath)){throw ('上次交互启动尚未确认，禁止再次启动；记录：'+$pendingPath)}
            $receipt=Read-ReplyJson $pending.ReceiptPath
            if($receipt.LaunchId -cne $pending.LaunchId){throw '交互启动回执身份不匹配。'}
            if($pending.TaskName){Remove-ReplySessionTask $pending.TaskName}
            Remove-Item -LiteralPath $pendingPath -Force
            return $receipt.Result
        }
        $current=Get-ReplyStatus $EnvInfo ''
        if($current.Running){throw ('已有回复任务正在运行：'+$current.JobId)}
        $userSid=Get-ReplyCallerSid
        $sessionId=Select-ReplyUserSession @(Get-ReplyUserSessions $EnvInfo) $userSid
        $launchId=[Guid]::NewGuid().ToString('N')
        $directory=Join-Path $EnvInfo.DataRoot ('launches\'+$launchId)
        $null=New-Item -ItemType Directory -Path $directory -Force
        $requestPath=Join-Path $directory 'request.json'
        $receiptPath=Join-Path $directory 'receipt.json'
        $taskName='Codex-DouyinReply-'+$launchId
        # Snapshot UTF-8 input before handing it to the user session.
        Write-ReplyJson (Read-ReplyJson $TaskFile) (Join-Path $directory 'task.json')
        $request=[ordered]@{LaunchId=$launchId;RuntimeRoot=$EnvInfo.RuntimeRoot;DataRoot=$EnvInfo.DataRoot;SessionId=$sessionId;UserSid=$userSid;CreatedAt=(Get-Date -Format o)}
        Write-ReplyJson $request $requestPath
        Write-ReplyJson ([ordered]@{LaunchId=$launchId;TaskName=$taskName;ReceiptPath=$receiptPath;SessionId=$sessionId;Status='Pending'}) $pendingPath
        try{Start-ReplySessionTask $EnvInfo $requestPath $taskName $sessionId $userSid}catch{
            # RunEx failure is not proof that no process was launched: keep the marker.
            throw ('交互会话派发失败，保留记录并禁止自动重试：'+$_.Exception.Message)
        }
        $receipt=Wait-ReplySessionReceipt $receiptPath
        if($receipt.LaunchId -cne $launchId){throw '交互启动回执身份不匹配。'}
        Remove-ReplySessionTask $taskName
        Remove-Item -LiteralPath $pendingPath -Force
        return $receipt.Result
    }finally{if($lock){$lock.Dispose()}}
}
