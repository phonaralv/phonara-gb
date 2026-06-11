# Starts Supabase MCP (stdio) with PAT from repo .env — no secrets in mcp.json.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $repoRoot '.env'

if (-not (Test-Path $envFile)) {
  [Console]::Error.WriteLine('run-supabase-mcp: missing .env — set SUPABASE_ACCESS_TOKEN')
  exit 1
}

foreach ($line in Get-Content $envFile -Encoding UTF8) {
  if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
  $parts = $line -split '=', 2
  $key = $parts[0].Trim()
  $val = $parts[1].Trim().Trim('"').Trim("'")
  if ($key -eq 'SUPABASE_ACCESS_TOKEN' -and $val) {
    $env:SUPABASE_ACCESS_TOKEN = $val
    break
  }
}

if (-not $env:SUPABASE_ACCESS_TOKEN) {
  [Console]::Error.WriteLine('run-supabase-mcp: SUPABASE_ACCESS_TOKEN not set in .env')
  exit 1
}

$npx = Join-Path $env:ProgramFiles 'nodejs\npx.cmd'
$globalMcp = Join-Path $env:APPDATA 'npm\mcp-server-supabase.cmd'
$mcpArgs = @(
  '--project-ref=yocjhjsdwoijfdrehzoq',
  '--read-only',
  '--features=database,debugging'
)

if (Test-Path $globalMcp) {
  & $globalMcp @mcpArgs
  exit $LASTEXITCODE
}

if (-not (Test-Path $npx)) {
  $npx = (Get-Command npx -ErrorAction SilentlyContinue).Source
}
if (-not $npx) {
  [Console]::Error.WriteLine('run-supabase-mcp: npx not found')
  exit 1
}

& $npx '-y' '@supabase/mcp-server-supabase@0.8.2' @mcpArgs
