$ErrorActionPreference = 'Stop'
$result = & docker compose -p rwb-b -f "$PSScriptRoot/compose.yml" exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U hack -d marketplace_b -f /profiling/01_raw_profile.sql
if ($LASTEXITCODE -ne 0) { throw 'Profile failed; saved results were not changed' }
if (!$result) { throw 'Profile produced no records' }
foreach ($line in $result) { $null = $line | ConvertFrom-Json }
[IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'raw-profile.jsonl'), [string[]]$result, [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath "$PSScriptRoot/local/source-manifest.json" -Destination "$PSScriptRoot/source-manifest.json"
Write-Output "Saved $($result.Count) profile records"
