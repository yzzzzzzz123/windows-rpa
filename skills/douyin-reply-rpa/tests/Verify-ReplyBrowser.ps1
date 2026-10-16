[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'shared\douyin\Browser.ps1')
$checks=0
function Assert-Browser([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Assert-Rejected([scriptblock]$Body,[string]$Message){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert-Browser $rejected $Message}
$profile=Join-Path $root 'artifacts\work\独立 browser profile'
foreach($line in @(
    ('chrome.exe --user-data-dir="'+$profile+'" --new-window https://www.douyin.com/'),
    ('chrome.exe --user-data-dir "'+$profile+'"'),
    ('chrome.exe "--user-data-dir='+$profile+'"'),
    ('chrome.exe --user-data-dir="'+$profile.ToUpperInvariant()+'\"')
)){Assert-Browser (Test-DouyinProfileCommandLine $line $profile) '合法独立目录参数没有匹配。'}
foreach($line in @(
    'chrome.exe',
    ('chrome.exe --user-data-dir="'+$profile+'-other"'),
    ('chrome.exe --user-data-dir="'+$profile+'\Default"'),
    ('chrome.exe --other-user-data-dir="'+$profile+'"'),
    ('chrome.exe --user-data-dir="'+$profile+'" --user-data-dir=C:\personal'),
    ('chrome.exe --user-data-dir="'+$profile+'" --user-data-dir'),
    'chrome.exe --user-data-dir=relative',
    ('chrome.exe --user-data-dir="'+$profile)
)){Assert-Browser (-not (Test-DouyinProfileCommandLine $line $profile)) '个人、相邻、重复或不完整参数被接受。'}
# 原生接口夹具仅返回内存窗口，不枚举或操作真实桌面。
Add-Type -TypeDefinition @'
using System;
public static class DingRpa {
    public class Window { public long Handle; public uint ProcessId; public bool Visible=true; public string Title="抖音 - Google Chrome"; }
    public static Window[] Windows;
    public static Window Current;
    public static string DesktopName(){return "Default";}
    public static string InputDesktopName(){return "Default";}
    public static bool SetProcessDPIAware(){return true;}
    public static Window[] ListWindows(){return Windows;}
    public static Window ReadWindow(IntPtr h){return Current;}
}
'@
$script:Config=[pscustomobject]@{Browser=[pscustomobject]@{ProcessName='chrome';TitleContains='抖音';UserDataDirectory=$profile}}
function Get-Process {param($Id,$ErrorAction) return [pscustomobject]@{ProcessName='chrome';StartTime=([datetime]'2026-10-15T09:00:00')}}
function Get-CimInstance {
    param($ClassName,$Filter,$ErrorAction)
    if($script:Unavailable){throw '无法读取进程身份'}
    $processNumber=[int]($Filter -replace '^ProcessId=','')
    $line=if($processNumber -eq 202){'chrome.exe --user-data-dir="'+$profile+'"'}else{'chrome.exe'}
    return [pscustomobject]@{Name='chrome.exe';CommandLine=$line}
}
function Assert-RpaRunning {}
function Ensure-DouyinForeground {$script:Selected=$script:BrowserWindow.ProcessId}
$personal=New-Object DingRpa+Window;$personal.Handle=101;$personal.ProcessId=101
$dedicated=New-Object DingRpa+Window;$dedicated.Handle=202;$dedicated.ProcessId=202
[DingRpa]::Windows=@($personal,$dedicated)
Initialize-DouyinBrowser
Assert-Browser ($script:Selected -eq 202) '两个同名窗口同时存在时未选择独立 profile。'
[DingRpa]::Current=$dedicated
Assert-DouyinIdentity
Assert-Browser $true '独立 profile 身份复核失败。'
$script:Unavailable=$true
Assert-Rejected {Assert-DouyinIdentity} '无法读取进程身份时仍允许输入。'
$script:Unavailable=$false
[DingRpa]::Current=$personal
Assert-Rejected {Assert-DouyinIdentity} '窗口进程被替换后仍允许输入。'
[DingRpa]::Windows=@($personal)
Assert-Rejected {Initialize-DouyinBrowser} '测试窗口缺失时回退到了个人浏览器。'
[DingRpa]::Windows=@($dedicated,$dedicated)
Assert-Rejected {Initialize-DouyinBrowser} '多个测试窗口时没有拒绝歧义。'
[pscustomobject]@{Status='Passed';BrowserChecks=$checks;DesktopActions=0;Submitted=0}
