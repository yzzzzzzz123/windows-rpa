[CmdletBinding()]
param([string]$EvidenceRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Skill.Core.ps1')
if(-not $EvidenceRoot){$EvidenceRoot=(Get-SkillEnvironment).RunsRoot}
$reports=@(Get-ChildItem -LiteralPath $EvidenceRoot -Filter result.json -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if($reports.Count -eq 0){throw '尚无运行记录。'}
$report=Get-Content -LiteralPath $reports[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
[pscustomobject]@{Status=$report.Status;Version=$report.Version;Reason=$report.Reason;ReportPath=$reports[0].FullName;Publish=$report.Publish;Continuous=$report.Continuous;Processed=$report.Processed;Published=$report.Published;Previewed=$report.Previewed;LastVideoId=$report.LastVideoId;Actions=$report.Actions}
