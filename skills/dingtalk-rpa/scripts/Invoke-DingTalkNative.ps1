[CmdletBinding()]
param(
    [ValidateSet('AppCenterLowCode','Inspect')][string]$Scenario='AppCenterLowCode',
    [string]$ConfigPath,
    [string]$EvidenceRoot,
    [switch]$WaitForKey,
    [switch]$SelfTest
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DingTalk.Paths.ps1')
$projectRoot=$skillRoot
$RpaVersion=(Get-Content -LiteralPath $layout.VersionPath -Raw).Trim()
. (Join-Path $projectRoot 'src\core\Configuration.ps1')
if(-not $ConfigPath){$ConfigPath=Join-Path $projectRoot 'config\dingtalk.json'}
$Config=Read-RpaConfiguration $ConfigPath
if(-not $EvidenceRoot){$EvidenceRoot=$layout.RunsRoot}
$resultDir=Join-Path $EvidenceRoot ((Get-Date -Format 'yyyyMMdd_HHmmssfff')+'-'+$PID)
New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if(-not ('DingRpa' -as [type])){Add-Type -Path (Join-Path $layout.SharedRoot 'native\DingRpa.cs')}
. (Join-Path $layout.SharedRoot 'core\Screenshot.ps1')
. (Join-Path $projectRoot 'src\core\Desktop.ps1')
. (Join-Path $projectRoot 'src\workflows\DingTalk.AppCenter.ps1')
if($SelfTest){
    if([IntPtr]::Size -ne 8){throw '请使用 64 位 Windows PowerShell。'}
    $inputSize=[Runtime.InteropServices.Marshal]::SizeOf([type][DingRpa+Input])
    if($inputSize -ne 40){throw ('Win32 INPUT 结构大小异常：'+$inputSize)}
    $report=[ordered]@{Status='SelfTestPassed';Version=$RpaVersion;Desktop=[DingRpa]::DesktopName();PowerShell=$PSVersionTable.PSVersion.ToString();NativeInputSize=$inputSize;ConfigurationValid=$true;DesktopInputPerformed=$false;EvidenceDirectory=$resultDir}
    Write-JsonFile $report 'result.json'
    [pscustomobject]$report
    exit 0
}
$script:FocusHistory=New-Object 'System.Collections.Generic.List[object]'
$script:LastDingHandle=[IntPtr]::Zero
$script:DingProcessIds=@()
$script:DingExecutablePaths=@()
$testResult=[ordered]@{Status='NotStarted';Version=$RpaVersion;Test=$Scenario;Target='钉钉主窗口';WindowLocated=$false;Activated=$false;Actions=@();NavigationStates=@();Reason=$null}
try {
    $null = [DingRpa]::SetProcessDPIAware()
    Write-Host ('钉钉 RPA 版本：'+$RpaVersion)
    $dingIds = @(Get-Process DingTalk -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $script:DingProcessIds=$dingIds
    $script:DingExecutablePaths=@(Get-Process DingTalk -ErrorAction SilentlyContinue|ForEach-Object {try{if($_.Path){$_.Path}}catch{}}|Select-Object -Unique)
    $script:RunnerForeground=Get-WindowDetails ([DingRpa]::GetForegroundWindow())
    $windows = @([DingRpa]::ListWindows())
    $candidates = @($windows | Where-Object { $_.Visible -and ($dingIds -contains [int]$_.ProcessId) })
    $context = [ordered]@{Desktop=[DingRpa]::DesktopName();SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;WindowCount=$windows.Count;DingTalkProcessIds=$dingIds;DingTalkWindows=$candidates}
    Write-JsonFile $context 'windows.json'
    if ($context.Desktop -like 'CodexSandboxDesktop*') { throw '当前位于 Codex 隔离桌面。请在自己的 Windows 桌面中双击 Run-DingTalk-RPA.cmd 运行。' }
    $targets = @($candidates | Where-Object { $_.ClassName -eq 'StandardFrame_DingTalk' -and $_.Title -match '^(?:\(\d+\)\s*)?(?:钉钉|DingTalk)(?:\s*\(\d+\))?$' })
    if ($targets.Count -ne 1) { throw '未找到唯一的钉钉主窗口。请打开钉钉主界面后重新运行；本次不会选择“钉钉服务平台”等业务窗口。窗口列表已保存。' }
    $target = $targets[0]
    $testResult.WindowLocated=$true
    $targetHandle = [IntPtr]$target.Handle
    $script:LastDingHandle=$targetHandle
    Write-Host ('已定位窗口：' + $target.Title + '，句柄：' + $target.Handle)
    $testResult['ActivationMethod']=[DingRpa]::ActivateTarget($targetHandle,[uint32]$target.ProcessId)
    $testResult.Activated=([DingRpa]::GetForegroundWindow() -eq $targetHandle)
    if (-not $testResult.Activated) { throw '钉钉主窗口定位成功，但 Windows 没有将其切到前台。请先点击钉钉主窗口，再运行测试。' }
    $rect = New-Object DingRpa+Rect
    if (([DingRpa]::GetForegroundWindow() -eq $targetHandle) -and [DingRpa]::GetWindowRect($targetHandle,[ref]$rect)) {
        $width=$rect.Right-$rect.Left; $height=$rect.Bottom-$rect.Top
        if ($width -gt 0 -and $height -gt 0 -and $width -lt 20000 -and $height -lt 20000) {
            $bitmap = New-Object System.Drawing.Bitmap($width,$height)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
                $bitmap.Save((Join-Path $resultDir 'dingtalk-window.png'),[System.Drawing.Imaging.ImageFormat]::Png)
                Write-Host '窗口激活和截图成功。'
            } finally { $graphics.Dispose(); $bitmap.Dispose() }
        }
    } else { Write-Host '窗口未能切到前台，已跳过截图。请保持钉钉页面可见后重试。' }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if($Scenario -eq 'Inspect'){
        Save-VisibleControls $targetHandle 'controls.json'
        $testResult.Status='Inspected'
        $testResult.Reason='已完成窗口定位、激活、截图和控件读取，未执行导航。'
    }else{
        Invoke-AppCenterFlow $targetHandle
    }
} catch {
    $message=$_.Exception.Message
    try{$null=Save-FocusSnapshot 'stopped'}catch{}
    if ($testResult.Status -eq 'NotStarted') { $testResult.Status='Blocked'; $testResult.Reason=$message }
    else { $testResult['AdditionalDiagnosticError']=$message }
    Set-Content -LiteralPath (Join-Path $resultDir 'error.txt') -Value $message -Encoding UTF8
    Write-Host ('诊断停止：' + $message) -ForegroundColor Yellow
} finally {
    Write-JsonFile $testResult 'result.json'
    Write-Host ('结果目录：' + $resultDir)
        Write-Host ('最终状态：'+$testResult.Status)
    if ($WaitForKey) { $null=Read-Host '按回车关闭' }
}

switch($testResult.Status){
    'Passed' {exit 0}
    'Inspected' {exit 0}
    'NeedsVisualReview' {exit 2}
    default {exit 1}
}
