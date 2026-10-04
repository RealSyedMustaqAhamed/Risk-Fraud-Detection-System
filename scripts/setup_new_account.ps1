$ErrorActionPreference = "Stop"
if (-not $env:SNOWFLAKE_ACCOUNT) { Write-Host "Set SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER and SNOWFLAKE_PASSWORD first."; exit 1 }
Write-Host "Run SQL files in Snowflake in this order:"
Get-ChildItem ".\risk_copilot\sql\*.sql" | Sort-Object Name | ForEach-Object { Write-Host " - $($_.Name)" }
Write-Host ""
Write-Host "Recommended order: 01 -> 02 -> 03 -> 04 -> 05 -> 06 -> 07 -> 08 -> 09 -> 10."
Write-Host "Then deploy the existing Streamlit app and configure the MCP server."
