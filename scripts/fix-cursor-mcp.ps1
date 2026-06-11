# Sync Cursor MCP + fix GPU argv (run once after clone or MCP errors).
# Does NOT print secrets.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $repoRoot '.env'
$argvPath = Join-Path $env:APPDATA 'Cursor\argv.json'
$mcpPath = Join-Path $repoRoot '.cursor\mcp.json'

Write-Host '=== PHONARA Cursor MCP fix ==='

# 1) argv.json — aggressive GPU off breaks Electron MessagePort / McpProcess IPC on Windows.
$argv = @{
  'enable-low-end-device-mode' = $true
  'max-memory'                 = 4096
}
$argv | ConvertTo-Json | Set-Content -Path $argvPath -Encoding UTF8
Write-Host "[ok] argv.json updated (removed disable-gpu*) -> $argvPath"

# 2) Global MCP — HTTP streamableHttp (last success: 2026-06-11 02:58 user-supabase).
#    Project-level duplicate causes project-0-* + MessagePort races — keep global ONLY.
$globalMcpPath = Join-Path $env:USERPROFILE '.cursor\mcp.json'
$globalMcp = @{
  mcpServers = @{
    supabase = @{
      type = 'http'
      url  = 'https://mcp.supabase.com/mcp?project_ref=yocjhjsdwoijfdrehzoq&read_only=true'
    }
  }
}
$globalMcp | ConvertTo-Json -Depth 5 | Set-Content -Path $globalMcpPath -Encoding UTF8
Write-Host "[ok] global HTTP MCP -> $globalMcpPath"

# 3) Project MCP — empty (no duplicate server).
$mcpPath = Join-Path $repoRoot '.cursor\mcp.json'
@{ mcpServers = @{} } | ConvertTo-Json | Set-Content -Path $mcpPath -Encoding UTF8
Write-Host "[ok] project mcp.json cleared -> $mcpPath"

# 4) Preflight .env PAT
if (-not (Test-Path $envFile)) {
  Write-Host '[warn] .env missing — add SUPABASE_ACCESS_TOKEN'
  exit 1
}
$hasToken = $false
foreach ($line in Get-Content $envFile -Encoding UTF8) {
  if ($line -match '^\s*SUPABASE_ACCESS_TOKEN=(.+)$') { $hasToken = $true; break }
}
if (-not $hasToken) {
  Write-Host '[warn] SUPABASE_ACCESS_TOKEN not in .env'
  exit 1
}
Write-Host '[ok] SUPABASE_ACCESS_TOKEN present in .env'

Write-Host 'NEXT (required — timing matters):'
Write-Host '  1. Quit Cursor completely (tray icon too)'
Write-Host '  2. Reopen phonara-gb'
Write-Host '  3. supabase MCP stays OFF — wait 3 FULL minutes (McpProcess cold start)'
Write-Host '  4. Then Settings -> Tools & MCP -> supabase ON once'
Write-Host '  5. First connect may show Loading tools ~30s — do NOT spam toggle'
Write-Host ''
Write-Host 'Why: last success (02:58 log) connected ~3min after McpProcess init.'
Write-Host 'Early toggle = MessagePort Error / Loading tools forever.'
Write-Host ''
Write-Host 'If still Error after 3min wait: Cursor reinstall or report to Cursor forum.'
