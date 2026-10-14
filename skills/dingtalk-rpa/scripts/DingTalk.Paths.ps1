$skillRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$visitedRoots=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
for($hop=0;$hop -lt 8;$hop++){
    if(-not $visitedRoots.Add($skillRoot)){throw '钉钉 Skill 目录链接存在循环。'}
    $directory=Get-Item -LiteralPath $skillRoot -Force
    if(-not $directory.PSIsContainer){throw '钉钉 Skill 根路径不是目录。'}
    if(-not ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){break}
    $targets=@($directory.Target)
    if($targets.Count -ne 1 -or -not $targets[0]){throw '不能唯一解析钉钉 Skill 目录链接。'}
    $target=[string]$targets[0]
    if(-not [IO.Path]::IsPathRooted($target)){$target=Join-Path (Split-Path $skillRoot -Parent) $target}
    $skillRoot=[IO.Path]::GetFullPath($target)
    if($hop -eq 7){throw '钉钉 Skill 目录链接层数过多。'}
}
$sharedRoot=Join-Path $skillRoot 'shared'
if(-not (Test-Path -LiteralPath (Join-Path $sharedRoot 'Runtime.ps1'))){$sharedRoot=[IO.Path]::GetFullPath((Join-Path $skillRoot '..\..\shared'))}
. (Join-Path $sharedRoot 'Runtime.ps1')
$layout=Get-RpaLayout $skillRoot
