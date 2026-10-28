$ErrorActionPreference = 'Stop'
$compose = "$PSScriptRoot/compose.yml"
$exists = & docker compose -p rwb-b -f $compose exec -T postgres psql -X -At -U hack -d postgres -c "SELECT 1 FROM pg_database WHERE datname='marketplace_b_etl_fixture'"
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect fixture database' }
if (!$exists) {
    docker compose -p rwb-b -f $compose exec -T postgres createdb -U hack marketplace_b_etl_fixture
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create fixture database' }
}
$result = & docker compose -p rwb-b -f $compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U hack -d marketplace_b_etl_fixture -f /work/profiling/05_etl_fixture.sql
if ($LASTEXITCODE -ne 0) { throw 'ETL fixture failed' }
foreach ($line in $result) { $null = $line | ConvertFrom-Json }
[IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'etl-fixture.jsonl'),[string[]]$result,[Text.UTF8Encoding]::new($false))
$result
