param([Parameter(Mandatory=$true)][string]$HandoutRoot)
$ErrorActionPreference = 'Stop'
$localDir = Join-Path $PSScriptRoot 'local'
$dataDir = Join-Path $localDir 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null
$mapping = [ordered]@{
    orders = 'olist_orders_dataset.csv'
    order_items = 'olist_order_items_dataset.csv'
    order_payments = 'olist_order_payments_dataset.csv'
    order_reviews = 'olist_order_reviews_dataset.csv'
    products = 'olist_products_dataset.csv'
    sellers = 'olist_sellers_dataset.csv'
    customers = 'olist_customers_dataset.csv'
    product_category_translation = 'product_category_name_translation.csv'
}
$base = 'https://raw.githubusercontent.com/olist/work-at-olist-data/master/datasets'
$manifest = foreach ($table in $mapping.Keys) {
    $name = $mapping[$table]
    $target = Join-Path $dataDir $name
    if (!(Test-Path -LiteralPath $target)) {
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile "$target.part"
        Move-Item -LiteralPath "$target.part" -Destination $target
    }
    [pscustomobject]@{file=$name; url="$base/$name"; sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash; bytes=(Get-Item -LiteralPath $target).Length}
}
$manifest | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $localDir 'source-manifest.json')
$ddl = Get-Content -Raw -Encoding UTF8 (Join-Path $HandoutRoot 'scripts/init/02_raw_ddl.sql')
$sql = @"
BEGIN;
DO `$`$ BEGIN
  IF EXISTS (SELECT FROM pg_namespace WHERE nspname='raw') THEN
    RAISE EXCEPTION 'raw already exists; bootstrap refuses to overwrite it';
  END IF;
END `$`$;
CREATE SCHEMA raw;
"@ + "`n" + $ddl
foreach ($table in $mapping.Keys) {
    $name = $mapping[$table]
    $header = Get-Content -LiteralPath (Join-Path $dataDir $name) -Encoding UTF8 -TotalCount 1
    $columns = ($header -replace '"','') -split ','
    foreach ($column in $columns) {
        if ($column -notmatch '^[a-z_]+$') { throw "Unexpected CSV column: $column" }
    }
    $sql += "`nCOPY raw.$table ($($columns -join ', ')) FROM '/workspace/data/$name' WITH (FORMAT csv, HEADER true);"
    $sql += "`nUPDATE raw.$table SET _source_file = '$name';"
}
$sql += "`nCOMMIT;`n"
[IO.File]::WriteAllText((Join-Path $localDir 'load.sql'), $sql, [Text.UTF8Encoding]::new($false))
docker compose -p rwb-b -f "$PSScriptRoot/compose.yml" up -d --wait postgres
if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL startup failed' }
docker compose -p rwb-b -f "$PSScriptRoot/compose.yml" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U hack -d marketplace_b -f /workspace/load.sql
if ($LASTEXITCODE -ne 0) { throw 'Raw initialization failed (existing raw is preserved)' }
