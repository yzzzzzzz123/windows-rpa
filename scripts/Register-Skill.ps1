[CmdletBinding()]
param([ValidateSet('All','douyin-rpa','dingtalk-rpa')][string]$Skill='All',[string]$SkillsRoot)
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if(-not $SkillsRoot){$SkillsRoot=Join-Path $env:USERPROFILE '.agents\skills'}
$SkillsRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SkillsRoot)
$null=New-Item -ItemType Directory -Path $SkillsRoot -Force
$names=if($Skill -eq 'All'){@('douyin-rpa','dingtalk-rpa')}else{@($Skill)}
# Validate every target before creating links; never replace unrelated installations.
foreach($name in $names){
    $source=Join-Path $projectRoot ('skills\'+$name)
    $link=Join-Path $SkillsRoot $name
    if(-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)){throw ('Skill 源缺失：'+$source)}
    if(Test-Path -LiteralPath $link){
        $existing=Get-Item -LiteralPath $link -Force
        if(-not ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or @($existing.Target).Count -ne 1 -or [IO.Path]::GetFullPath(@($existing.Target)[0]) -ne $source){throw ('技能目录已存在其他安装，未覆盖：'+$link)}
    }
}
foreach($name in $names){
    $source=Join-Path $projectRoot ('skills\'+$name);$link=Join-Path $SkillsRoot $name
    if(-not (Test-Path -LiteralPath $link)){$null=New-Item -ItemType Junction -Path $link -Value $source}
    if((Get-FileHash -LiteralPath (Join-Path $link 'SKILL.md')).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source 'SKILL.md')).Hash){throw '技能发现链接校验失败。'}
    [pscustomobject]@{Status='Registered';Skill=$name;LinkPath=$link;SourceRoot=$source;CopiedSource=$false}
}
# Retire only the known legacy discovery junction, never its target or a real folder.
if($names -contains 'douyin-rpa'){
    $legacy=Join-Path $SkillsRoot 'windows-rpa'
    if(Test-Path -LiteralPath $legacy){
        $item=Get-Item -LiteralPath $legacy -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and @($item.Target).Count -eq 1 -and [IO.Path]::GetFullPath(@($item.Target)[0]) -eq $projectRoot){[IO.Directory]::Delete($legacy)}
    }
}
