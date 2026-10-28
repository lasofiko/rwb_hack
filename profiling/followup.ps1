$ErrorActionPreference = 'Stop'
$result = & docker compose -p rwb-b -f "$PSScriptRoot/compose.yml" exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U hack -d marketplace_b -f /profiling/02_followup.sql
if ($LASTEXITCODE -ne 0) { throw 'Focused checks failed' }
foreach ($line in $result) { $null = $line | ConvertFrom-Json }
[IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'followup.jsonl'), [string[]]$result, [Text.UTF8Encoding]::new($false))
$result
