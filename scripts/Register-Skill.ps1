[CmdletBinding()]
param([string]$SkillsRoot)
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if(-not $SkillsRoot){$SkillsRoot=Join-Path $env:USERPROFILE '.agents\skills'}
$SkillsRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SkillsRoot)
$link=Join-Path $SkillsRoot 'windows-rpa'
$null=New-Item -ItemType Directory -Path $SkillsRoot -Force
if(Test-Path -LiteralPath $link){
    $existing=Get-Item -LiteralPath $link -Force
    if(-not ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [IO.Path]::GetFullPath(@($existing.Target)[0]) -ne $source){throw '技能目录存在其他 windows-rpa，未覆盖。'}
}else{
    $null=New-Item -ItemType Junction -Path $link -Value $source
}
if((Get-FileHash -LiteralPath (Join-Path $link 'SKILL.md') -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source 'SKILL.md') -Algorithm SHA256).Hash){throw '技能发现链接校验失败。'}
[pscustomobject]@{Status='Registered';Skill='windows-rpa';LinkPath=$link;SourceRoot=$source;CopiedSource=$false}
