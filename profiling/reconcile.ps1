$ErrorActionPreference = 'Stop'
$result = & docker compose -p rwb-b -f "$PSScriptRoot/compose.yml" exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U hack -d marketplace_b -f /profiling/03_reconciliation.sql
if ($LASTEXITCODE -ne 0) { throw 'Reconciliation failed; saved results were not changed' }
if (!$result) { throw 'Reconciliation produced no records' }
foreach ($line in $result) { $null = $line | ConvertFrom-Json }
[IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'reconciliation.jsonl'), [string[]]$result, [Text.UTF8Encoding]::new($false))
$result
