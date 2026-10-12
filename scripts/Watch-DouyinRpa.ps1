[CmdletBinding()]
param([string]$DataRoot,[switch]$Headless,[ValidateRange(1,60)][int]$RefreshSeconds=2,[ValidateRange(0,100000)][int]$MaxSamples=0)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Skill.Core.ps1')
$environment=Get-SkillEnvironment $DataRoot
$directory=Join-Path $environment.DataRoot 'monitor'
$null=New-Item -ItemType Directory -Path $directory -Force
# This observer never launches, restarts, stops, or sends input to the worker.
$monitorLock=[IO.File]::Open((Join-Path $directory 'observer.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$script:exitMonitor=$false;$form=$null;$tray=$null;$lastKey='';$lastAlert='';$samples=0
$stageNames=@{Initializing='初始化';OpeningComments='打开评论区';Submitting='正在提交';Submitted='已提交，继续下一条';WaitingForInterval='等待发送间隔';WaitingForNextCycle='本轮结束，等待下轮';WaitingForVerification='等待你处理验证码';WaitingForBrowser='等待浏览器恢复';VideoSkipped='跳过当前视频';SearchSkipped='跳过当前搜索';VerificationCompleted='验证完成，继续'}
try {
    if(-not $Headless){
        Add-Type -AssemblyName System.Windows.Forms,System.Drawing
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public class RpaMonitorForm : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation { get { return true; } }
}
'@
        [Windows.Forms.Application]::EnableVisualStyles()
        $form=New-Object RpaMonitorForm
        $form.Text='RPA 实时监控';$form.ClientSize=New-Object Drawing.Size(490,350)
        $form.MinimumSize=New-Object Drawing.Size(490,350)
        $form.StartPosition='CenterScreen';$form.BackColor=[Drawing.Color]::FromArgb(245,247,250)
        # Do not put an overlay on Chrome's input targets or continually take focus.
        $form.TopMost=$false
        $label=New-Object Windows.Forms.Label
        $label.Dock='Fill';$label.Padding=New-Object Windows.Forms.Padding(18)
        $label.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
        $form.Controls.Add($label)
        $tray=New-Object Windows.Forms.NotifyIcon
        $tray.Icon=[Drawing.SystemIcons]::Information;$tray.Visible=$true;$tray.Text='RPA 监控正在启动'
        $menu=New-Object Windows.Forms.ContextMenuStrip
        $showItem=$menu.Items.Add('显示监控')
        $showItem.add_Click({$form.Show();$form.WindowState='Normal';$form.Activate()})
        $hideItem=$menu.Items.Add('隐藏窗口（继续监控）')
        $hideItem.add_Click({$form.Hide()})
        $exitItem=$menu.Items.Add('退出监控（RPA 任务继续）')
        $exitItem.add_Click({$script:exitMonitor=$true})
        $tray.ContextMenuStrip=$menu
        $tray.add_DoubleClick({$form.Show();$form.WindowState='Normal';$form.Activate()})
        $form.add_FormClosing({param($sender,$eventArgs) if(-not $script:exitMonitor){$eventArgs.Cancel=$true;$sender.Hide()}})
        $form.Show()
    }
    do {
        $checkedAt=Get-Date -Format o
        try {
            $task=Get-SkillStatus $environment '' -Lightweight
            $health=$task.Health
            $headline=if($task.Status -eq 'NoRuns'){'还没有任务'}elseif(-not $task.Running){'任务已结束：'+$task.Status}elseif($health -eq 'Stalled'){'进程存活，但心跳超时，可能卡住'}elseif($task.Status -eq 'WaitingForVerification'){'等待你在抖音处理验证码'}elseif($task.Paused){'任务已暂停'}elseif($health -eq 'Unknown'){'进程存活；尚无运行器心跳'}else{'正在运行 · 心跳正常'}
            $errorText=$null
        }catch{
            $task=$null;$health='ReadError';$headline='监控读取失败，2 秒后重试';$errorText=$_.Exception.Message
        }
        $snapshot=[ordered]@{MonitorUpdatedAt=$checkedAt;MonitorProcessId=$PID;RefreshSeconds=$RefreshSeconds;Headline=$headline;Health=$health;ReadError=$errorText;Task=$task}
        Write-SkillJson $snapshot (Join-Path $directory 'status.json')
        $key=@($task.JobId,$task.Status,$task.Stage,$health,$task.Submitted,$task.Skipped,$errorText) -join '|'
        if($key -cne $lastKey){
            [IO.File]::AppendAllText((Join-Path $directory 'events.jsonl'),((ConvertTo-Json $snapshot -Depth 14 -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
            $lastKey=$key
        }
        if($form){
            $stage=if($stageNames.ContainsKey([string]$task.Stage)){$stageNames[[string]$task.Stage]}else{[string]$task.Stage -replace '^Searching: ','搜索：'}
            $countdown=''
            $waitUntil=if($task.Stage -eq 'WaitingForInterval'){$task.NextSubmissionAt}elseif($task.Stage -eq 'WaitingForNextCycle'){$task.NextCycleAt}else{$null}
            if($waitUntil){$countdown='（剩余 '+[Math]::Max(0,[Math]::Ceiling(([DateTimeOffset]::Parse($waitUntil)-[DateTimeOffset]::Now).TotalSeconds))+' 秒）'}
            $heartbeat=if($null -eq $task.HeartbeatAgeSeconds){'暂无'}else{[string]$task.HeartbeatAgeSeconds+' 秒前'}
            $recentError=if($errorText){$errorText}elseif($task.Reason){$task.Reason}elseif($task.LastError){$task.LastError}else{'无'}
            $label.Text=@($headline,('当前步骤：'+$stage+$countdown),('本轮已提交 '+[int]$task.Submitted+' 条  |  跳过 '+[int]$task.Skipped+' 条'),('发送最小间隔：'+$task.CommentIntervalSeconds+' 秒'),('进程：'+$task.ProcessId+'  |  心跳：'+$heartbeat),('监控刷新：'+(Get-Date -Format 'HH:mm:ss')+'（每 '+$RefreshSeconds+' 秒）'),('最近异常：'+$recentError),'',('任务：'+$task.JobId),'关闭窗口仅收起至托盘；双击托盘图标可再次打开。','已提交表示发送动作已执行，不检查评论可见性。') -join "`r`n"
            $label.ForeColor=if($health -in @('Stalled','ReadError') -or -not $task.Running){[Drawing.Color]::DarkRed}elseif($task.Status -eq 'WaitingForVerification'){[Drawing.Color]::DarkOrange}else{[Drawing.Color]::FromArgb(25,65,45)}
            $form.Text='RPA · 已提交 '+[int]$task.Submitted+' · '+$headline
            $tooltip=$headline+' | 已提交 '+[int]$task.Submitted+' | '+(Get-Date -Format 'HH:mm:ss')
            $tray.Text=$tooltip.Substring(0,[Math]::Min(63,$tooltip.Length))
            $alert=if($health -in @('Stalled','ReadError') -or $task.Status -in @('WaitingForVerification','Interrupted','Blocked')){$task.JobId+'|'+$headline}else{''}
            if($alert -and $alert -cne $lastAlert){$tray.BalloonTipTitle='RPA 运行提醒';$tray.BalloonTipText=$headline;$tray.ShowBalloonTip(8000)}
            $lastAlert=$alert
            $showFile=Join-Path $directory 'show'
            if(Test-Path -LiteralPath $showFile){Remove-Item -LiteralPath $showFile;$form.Show();$form.WindowState='Normal'}
        }
        $samples++
        if($MaxSamples -gt 0 -and $samples -ge $MaxSamples){break}
        $until=[DateTime]::UtcNow.AddSeconds($RefreshSeconds)
        do {
            if($form){[Windows.Forms.Application]::DoEvents()}
            Start-Sleep -Milliseconds 100
        }while(-not $script:exitMonitor -and [DateTime]::UtcNow -lt $until)
    }while(-not $script:exitMonitor)
}finally{
    if($tray){$tray.Visible=$false;$tray.Dispose()}
    if($form){$script:exitMonitor=$true;$form.Dispose()}
    $monitorLock.Dispose()
}
