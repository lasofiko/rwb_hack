$ErrorActionPreference = 'Stop'
$compose = "$PSScriptRoot/compose.yml"
docker compose -p rwb-b -f $compose up -d --wait postgres
if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL startup failed' }
$first = & docker compose -p rwb-b -f $compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U hack -d marketplace_b -f /work/profiling/04_verify_etl.sql
if ($LASTEXITCODE -ne 0) { throw 'ETL verification failed' }
$second = & docker compose -p rwb-b -f $compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U hack -d marketplace_b -f /work/profiling/04_verify_etl.sql
if ($LASTEXITCODE -ne 0) { throw 'Second ETL verification failed' }
if (($first -join "`n") -cne ($second -join "`n")) { throw 'ETL is not reproducible' }
foreach ($line in $second) { $null = $line | ConvertFrom-Json }
[IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'etl-verification.jsonl'),[string[]]$second,[Text.UTF8Encoding]::new($false))
Write-Output 'Two ETL runs match; raw unchanged; money conserved'
$second
