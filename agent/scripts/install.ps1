#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instala el agente de Altair Wake como tarea programada de SYSTEM.

.DESCRIPTION
    Copia el ejecutable a Program Files, crea la clave compartida en
    ProgramData con acceso exclusivo de SYSTEM y Administradores, abre el
    puerto TCP solo para la subred local y registra la tarea al inicio.
    Es idempotente: volver a ejecutarlo actualiza el ejecutable y conserva la
    clave salvo que se indique -RotateKey.

.PARAMETER ExePath
    Ejecutable compilado con:
    dart compile exe agent/bin/altair_wake_agent.dart -o build/agent/altair_wake_agent.exe

.PARAMETER KeyOutFile
    Si se indica, escribe la clave en ese archivo para transferirla a la app.
    Bórralo después de usarlo.
#>
param(
    [string]$ExePath = (Join-Path $PSScriptRoot '..\..\build\agent\altair_wake_agent.exe'),
    [ValidateRange(1, 65535)][int]$Port = 47123,
    [switch]$RotateKey,
    [switch]$ShowKey,
    [string]$KeyOutFile
)
$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:ProgramFiles 'AltairWake'
$dataDir = Join-Path $env:ProgramData 'AltairWake'
$exeTarget = Join-Path $installDir 'altair_wake_agent.exe'
$keyFile = Join-Path $dataDir 'agent.key'
$logFile = Join-Path $dataDir 'agent.log'
$taskName = 'AltairWakeAgent'
$ruleName = 'Altair Wake - agente (LAN)'

# SID en lugar de nombres: los grupos están localizados ("Administradores").
$systemSid = '*S-1-5-18'
$adminsSid = '*S-1-5-32-544'

if (-not (Test-Path $ExePath)) { throw "No existe el ejecutable: $ExePath" }

# Detener una instancia previa para poder reemplazar el ejecutable.
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Get-Process altair_wake_agent -ErrorAction SilentlyContinue | Stop-Process -Force
}

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item -Path $ExePath -Destination $exeTarget -Force

# ProgramData permite escribir a usuarios estándar por herencia; se elimina
# para que nadie sin privilegios pueda leer la clave ni alterar el registro.
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
icacls $dataDir /inheritance:r /grant:r "${systemSid}:(OI)(CI)F" "${adminsSid}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'No se pudieron fijar los permisos de ProgramData\AltairWake.' }

if ($RotateKey -or -not (Test-Path $keyFile)) {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $encoded = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [System.IO.File]::WriteAllText($keyFile, $encoded, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'Clave nueva generada.'
}

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName `
    -Description 'Órdenes autenticadas de Altair Wake (estado, suspender, apagar). Solo subred local.' `
    -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress LocalSubnet `
    -Program $exeTarget -Action Allow -Profile Any | Out-Null

$arguments = "--key-file `"$keyFile`" --port $Port --log-file `"$logFile`""
$action = New-ScheduledTaskAction -Execute $exeTarget -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Agente de Altair Wake' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Start-Sleep -Seconds 2
$listening = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if (-not $listening) { throw "El agente no está escuchando en el puerto $Port. Revisa $logFile" }

Write-Host "Agente instalado y escuchando en TCP $Port (solo subred local)."
if ($ShowKey) { Write-Host "Clave: $(Get-Content $keyFile -Raw)" }
if ($KeyOutFile) { Copy-Item $keyFile $KeyOutFile -Force }
