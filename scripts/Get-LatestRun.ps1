[CmdletBinding()]
param([string]$EvidenceRoot)
$ErrorActionPreference='Stop'
if(-not $EvidenceRoot){$EvidenceRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'evidence\runs'}
$reports=@(Get-ChildItem -LiteralPath $EvidenceRoot -Filter result.json -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if($reports.Count -eq 0){throw '尚无运行记录。'}
$report=Get-Content -LiteralPath $reports[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
[pscustomobject]@{Status=$report.Status;Version=$report.Version;Reason=$report.Reason;ReportPath=$reports[0].FullName;Actions=$report.Actions}
