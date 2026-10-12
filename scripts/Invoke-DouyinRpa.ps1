[CmdletBinding()]
param(
    [string]$ConfigPath,[string]$EvidenceRoot,[string]$StateRoot,
    [switch]$Publish,[switch]$Continuous,[ValidateRange(0,1000000)][int]$MaxVideos=1,
    [switch]$Inspect,[switch]$SelfTest,[switch]$WaitForKey,[switch]$PreserveControlSignals
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src\core\Douyin.Configuration.ps1')
. (Join-Path $projectRoot 'src\core\RpaState.ps1')
if(-not $ConfigPath){$ConfigPath=Join-Path $projectRoot 'config\douyin.json'}
$Config=Read-DouyinConfiguration $ConfigPath
if(-not $EvidenceRoot){$EvidenceRoot=Join-Path $projectRoot 'evidence\runs'}
if(-not $StateRoot){$StateRoot=Join-Path $projectRoot 'evidence\douyin-state'}
$EvidenceRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EvidenceRoot)
$StateRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StateRoot)
$script:RunDirectory=Join-Path $EvidenceRoot ((Get-Date -Format 'yyyyMMdd_HHmmssfff')+'-douyin-'+$PID)
$null=New-Item -ItemType Directory -Path $script:RunDirectory -Force
$script:VideoEvidence=$script:RunDirectory
$script:RpaRunLock=$null;$script:PendingVideoId=$null
Add-Type -AssemblyName System.Drawing,UIAutomationClient,UIAutomationTypes
if(-not ('DingRpa' -as [type])){Add-Type -Path (Join-Path $projectRoot 'src\native\DingRpa.cs')}
. (Join-Path $projectRoot 'src\core\Desktop.ps1')
. (Join-Path $projectRoot 'src\core\Browser.ps1')
. (Join-Path $projectRoot 'src\workflows\Douyin.Comment.ps1')
$script:RunReport=[ordered]@{
    Status='Starting';Version=(Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim();Scenario='DouyinComment'
    Publish=[bool]$Publish;Continuous=[bool]$Continuous;MaxVideos=$MaxVideos;StartedAt=(Get-Date -Format o)
    Processed=0;Submitted=0;Published=0;Previewed=0;Skipped=0;RecoverableErrors=0;LastError=$null;LastVideoId=$null;LastVideoStatus=$null;Reason=$null;EvidenceDirectory=$script:RunDirectory
    Stage='Initializing';Paused=$false;UpdatedAt=(Get-Date -Format o);HeartbeatAt=(Get-Date -Format o)
    CommentIntervalSeconds=$Config.Timing.CommentIntervalSeconds;NextSubmissionAt=$null;NextCycleAt=$null
}
$exitCode=1
try {
    if([IntPtr]::Size -ne 8){throw '请使用 64 位 Windows PowerShell 5.1。'}
    if($SelfTest){
        $size=[Runtime.InteropServices.Marshal]::SizeOf([type][DingRpa+Input])
        if($size -ne 40){throw 'Win32 INPUT 结构大小异常。'}
        $script:RunReport.Status='SelfTestPassed'
        $script:RunReport['NativeInputSize']=$size;$script:RunReport['ConfigurationValid']=$true;$script:RunReport['DesktopInputPerformed']=$false
        $exitCode=0
    }else{
        Initialize-RpaState $StateRoot $projectRoot
        $oldStop=Join-Path $script:RpaControlRoot 'stop'
        if(-not $PreserveControlSignals -and (Test-Path -LiteralPath $oldStop)){Remove-Item -LiteralPath $oldStop}
        Initialize-DouyinBrowserWithRecovery ([bool]$Continuous)
        if($Inspect){
            Save-DouyinEvidence 'browser';$script:RunReport.Status='Inspected';$exitCode=0
        }else{
            $script:RunReport.Status='Running'
            Write-RpaStateJson $script:RunReport (Join-Path $script:RunDirectory 'result.json')
            Write-Host ('抖音原生 RPA；发布='+[bool]$Publish+'；持续运行='+[bool]$Continuous+'；本次处理上限='+$MaxVideos)
            Write-Host '按住 Escape 或运行 Stop-RPA.cmd 可停止；暂停后可以运行 Resume-RPA.cmd 继续。'
            Invoke-DouyinLoop ([bool]$Publish) ([bool]$Continuous) $MaxVideos
            $script:RunReport.Status=if($Publish){'Completed'}else{'PreviewCompleted'}
            $exitCode=0
        }
    }
}catch{
    $reason=$_.Exception.Message
    if($_.Exception -is [OperationCanceledException]){$script:RunReport.Status='Stopped';$exitCode=0}
    elseif($reason -like 'NeedsUserAction:*'){$script:RunReport.Status='NeedsUserAction';$exitCode=2}
    elseif($script:PendingVideoId -or $reason -like 'NeedsVisualReview:*'){$script:RunReport.Status='NeedsVisualReview';$exitCode=2}
    else{$script:RunReport.Status='Blocked';$exitCode=1}
    $script:RunReport.Reason=$reason
    if($script:PendingVideoId){try{Set-RpaSubmissionStatus $script:PendingVideoId 'NeedsVisualReview' $reason}catch{}}
    try{Save-DouyinEvidence 'stopped'}catch{}
    Set-Content -LiteralPath (Join-Path $script:RunDirectory 'error.txt') -Value $_.ScriptStackTrace -Encoding UTF8
    Write-Host ('流程停止：'+$reason) -ForegroundColor Yellow
}finally{
    $script:RunReport['FinishedAt']=Get-Date -Format o
    $script:RunReport.Paused=$false;$script:RunReport.UpdatedAt=Get-Date -Format o
    Write-RpaStateJson $script:RunReport (Join-Path $script:RunDirectory 'result.json')
    if($script:RpaRunLock){$script:RpaRunLock.Dispose()}
    Write-Host ('最终状态：'+$script:RunReport.Status)
    Write-Host ('结果目录：'+$script:RunDirectory)
    if($WaitForKey){$null=Read-Host '按回车关闭'}
}
[pscustomobject]$script:RunReport
exit $exitCode
