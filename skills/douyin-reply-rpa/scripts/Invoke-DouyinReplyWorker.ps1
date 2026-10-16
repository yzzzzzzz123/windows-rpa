[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$JobFile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Reply.Core.ps1')
$job=Read-ReplyJson $JobFile
$environment=Get-ReplyEnvironment $job.DataRoot
$expectedJob=Join-Path (Get-ReplyJobPath $environment $job.JobId) 'job.json'
if([IO.Path]::GetFullPath($JobFile) -ne $expectedJob -or $job.RuntimeRoot -ne $environment.RuntimeRoot -or $job.StateRoot -ne $environment.StateRoot -or $job.SharedSubmissionRoot -ne $environment.SharedSubmissionRoot){throw '后台任务路径不符合当前技能身份。'}
$expectedDirectory=Split-Path $expectedJob -Parent
if($job.ConfigPath -ne (Join-Path $expectedDirectory 'config.json') -or $job.EvidenceRoot -ne (Join-Path $expectedDirectory 'evidence')){throw '任务配置或证据目录不在当前任务内。'}
. (Join-Path $environment.RuntimeRoot 'src\core\Reply.State.ps1')
$script:RunDirectory=$job.EvidenceRoot
$script:RunReport=[ordered]@{JobId=$job.JobId;Mode=$job.Mode;Status='Starting';Stage='Starting';Paused=$false;Submitted=0;Previewed=0;Skipped=0;Processed=0;CandidateCount=0;Reason=$null;LastError=$null;UpdatedAt=(Get-Date -Format o);HeartbeatAt=(Get-Date -Format o)}
$exitCode=0
try {
    $script:Config=Read-ReplyConfiguration $job.ConfigPath
    if(-not [string]::Equals($Config.Browser.UserDataDirectory,(Get-ReplyBrowserProfilePath $environment),[StringComparison]::OrdinalIgnoreCase)){throw '回复任务必须使用当前 DataRoot 的独立测试 profile；旧配置不能回退到个人浏览器。'}
    if($job.Mode -cne $Config.Mode){throw '任务模式与配置不一致。'}
    if($Config.Mode -ne 'Discover'){
        $source=@(Read-ReplySourceCandidates $environment $Config.SourceJobId)
        foreach($candidate in $Config.Replies){
            $original=@($source | Where-Object {$_.CandidateId -ceq $candidate.CandidateId})
            if($original.Count -ne 1){throw '执行前无法核实候选来源。'}
            foreach($name in @('CandidateId','AuthorKey','CommentId','VideoId','VideoTitle','VideoUrl','AuthorName','AuthorUrl','Text')){if($candidate.$name -cne $original[0].$name){throw ('执行前候选来源字段已变化：'+$name)}}
        }
    }
    Initialize-ReplyState $job.StateRoot $job.SharedSubmissionRoot
    Add-Type -AssemblyName System.Drawing,UIAutomationClient,UIAutomationTypes
    Add-Type -Path (Join-Path $environment.SharedRoot 'native\DingRpa.cs')
    . (Join-Path $environment.SharedRoot 'core\Screenshot.ps1')
    . (Join-Path $environment.SharedRoot 'douyin\Urls.ps1')
    . (Join-Path $environment.SharedRoot 'douyin\Browser.ps1')
    . (Join-Path $environment.SharedRoot 'douyin\Comments.ps1')
    . (Join-Path $environment.RuntimeRoot 'src\core\Reply.Parsing.ps1')
    . (Join-Path $environment.RuntimeRoot 'src\core\Reply.UI.ps1')
    . (Join-Path $environment.RuntimeRoot 'src\workflows\Reply.Workflow.ps1')
    $script:RunReport.Status='Running';Set-RpaProgress 'InitializingBrowser'
    Initialize-DouyinBrowser
    if($Config.Mode -eq 'Discover'){Invoke-ReplyDiscovery}else{Invoke-ReplyBatch}
    $script:RunReport.Status='Completed';Set-RpaProgress 'Completed'
}catch [OperationCanceledException]{
    $script:RunReport.Status='Stopped';$script:RunReport.Reason=$_.Exception.Message
}catch{
    $script:RunReport.Status='Failed';$script:RunReport.Reason=$_.Exception.Message
    $script:RunReport['ErrorLocation']=$_.ScriptStackTrace;$exitCode=1
    # 目标核验失败时保留当时页面证据，便于区分提示裁切、未选中与控件缺失；不导航或重发。
    if($script:RunReport.Stage -eq 'OpeningReplyTarget' -and $script:BrowserHandle){
        try{Save-DouyinEvidence 'reply-target-failed'}catch{$script:RunReport['EvidenceError']=$_.Exception.Message}
    }
}finally{
    if($script:PendingCandidateId){try{Set-ReplySubmissionStatus $script:PendingCandidateId 'Unknown' $script:RunReport.Reason}catch{}}
    $script:RunReport['UpdatedAt']=Get-Date -Format o;$script:RunReport['HeartbeatAt']=Get-Date -Format o
    Write-RpaStateJson $script:RunReport (Join-Path $script:RunDirectory 'result.json')
    Write-RpaStateJson ([ordered]@{Status=$script:RunReport.Status;Reason=$script:RunReport.Reason;FinishedAt=(Get-Date -Format o)}) (Join-Path (Split-Path $JobFile -Parent) 'worker-result.json')
    Close-ReplyState
}
exit $exitCode
