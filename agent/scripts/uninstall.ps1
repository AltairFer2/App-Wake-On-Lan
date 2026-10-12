#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Desinstala el agente de Altair Wake.

.PARAMETER KeepData
    Conserva ProgramData\AltairWake (clave y registro).
#>
param([switch]$KeepData)
$ErrorActionPreference = 'Stop'

$taskName = 'AltairWakeAgent'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
Get-Process altair_wake_agent -ErrorAction SilentlyContinue | Stop-Process -Force
Get-NetFirewallRule -DisplayName 'Altair Wake - agente (LAN)' -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule

$installDir = Join-Path $env:ProgramFiles 'AltairWake'
if (Test-Path $installDir) { Remove-Item -Path $installDir -Recurse -Force }

$dataDir = Join-Path $env:ProgramData 'AltairWake'
if (-not $KeepData -and (Test-Path $dataDir)) { Remove-Item -Path $dataDir -Recurse -Force }

Write-Host 'Agente desinstalado.'
