#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Activa (o desactiva) el Escritorio remoto de Windows solo para la red local.

.DESCRIPTION
    Habilita RDP con autenticación a nivel de red (NLA) y las reglas de
    firewall integradas de Escritorio remoto, limitadas a LocalSubnet: RDP no
    queda accesible desde Internet aunque el router dejara pasar el puerto.
    Con -Disable vuelve a denegar las conexiones, desactiva las reglas y
    restaura el bloqueo de cuentas sin contraseña.

.PARAMETER AllowBlankPassword
    NO RECOMENDADO. Permite iniciar sesión por red con cuentas sin
    contraseña (LimitBlankPasswordUse = 0). Afecta a todo acceso por red, no
    solo a RDP: cualquiera en la red local podría entrar con esa cuenta.
    Usarlo solo por decisión explícita del propietario; lo seguro es poner
    contraseña a la cuenta.
#>
param([switch]$Disable, [switch]$AllowBlankPassword)
$ErrorActionPreference = 'Stop'

$terminalServer = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
$rdpTcp = Join-Path $terminalServer 'WinStations\RDP-Tcp'
$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
# Grupo de reglas "Escritorio remoto" por recurso: el nombre está localizado.
$firewallGroup = '@FirewallAPI.dll,-28752'

if ($Disable) {
    Set-ItemProperty -Path $terminalServer -Name fDenyTSConnections -Value 1
    Get-NetFirewallRule -Group $firewallGroup | Disable-NetFirewallRule
    Set-ItemProperty -Path $lsa -Name LimitBlankPasswordUse -Value 1
    Write-Host 'Escritorio remoto desactivado y bloqueo de cuentas sin contraseña restaurado.'
    return
}

if ($AllowBlankPassword) {
    Set-ItemProperty -Path $lsa -Name LimitBlankPasswordUse -Value 0
    Write-Warning 'Cuentas sin contraseña habilitadas para inicio de sesión por red.'
}

Set-ItemProperty -Path $terminalServer -Name fDenyTSConnections -Value 0
# NLA: la contraseña se valida antes de abrir la sesión gráfica.
Set-ItemProperty -Path $rdpTcp -Name UserAuthentication -Value 1
Get-NetFirewallRule -Group $firewallGroup |
    Set-NetFirewallRule -RemoteAddress LocalSubnet -Enabled True

$port = (Get-ItemProperty -Path $rdpTcp).PortNumber
Write-Host "Escritorio remoto activo en TCP $port, solo desde la subred local (NLA activada)."
