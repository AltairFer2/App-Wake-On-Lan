# Protocolo de pruebas físicas

Estas pruebas no pueden automatizarse: requieren el PC, el router y el
teléfono reales. Registra solo lo observado; "Paquete UDP enviado" en la app
**no** significa que el equipo encendió.

## Preparación (una sola vez)

1. PC conectado por **cable Ethernet**.
2. BIOS/UEFI: Wake on LAN / Power On by PCI-E activado; ErP/EuP desactivado.
3. Windows → Administrador de dispositivos → adaptador Ethernet:
   - Administración de energía: permitir que reactive el equipo, solo con
     Magic Packet.
   - Opciones avanzadas: *Wake on Magic Packet* = Habilitado; si existen,
     *Shutdown Wake-On-Lan* = Habilitado y *NS Offload* / *ARP Offload* =
     Habilitado.
4. Para la prueba desde apagado: Panel de control → Opciones de energía →
   desactivar *Activar inicio rápido*.
5. Router → `Network > LAN Settings > DHCP Static IP Settings`: reserva la MAC
   del PC (p. ej. 192.168.100.20). Este cambio es local y reversible.
6. Instala el agente (`agent/scripts/install.ps1`, ver README).
7. En la app: registra el PC con MAC, IPv4 reservada, difusión
   `192.168.100.255`, puerto UDP 9, puerto de sondeo 47123 y la sección
   *Agente de Windows* (puerto 47123 y clave).
8. Con el PC encendido, verifica que la tarjeta muestra **Alcanzable** y que
   ⋮ → *Consultar agente* responde "agente autenticado".

## Resultados ya obtenidos (2026-10-11, teléfono en Wi-Fi de casa)

| Prueba | Resultado |
|---|---|
| Sondeo TCP 47123 por IPv4 e IPv6 | Alcanzable |
| Sondeo a puerto cerrado con regla de permiso (TCP 9) | Sin respuesta: Windows no envía RST |
| ⋮ → Consultar agente | Respuesta autenticada |
| ⋮ → Apagar y luego Cancelar apagado | Apagado programado por SYSTEM (evento 1074) y cancelado |
| ⋮ → Suspender | El equipo entró en suspensión (evento Kernel-Power 42, "Application API") |
| Encender desde suspensión (Wi-Fi) | **No despertó** en 38 min. Al cortar y restaurar la corriente, Windows se restauró del archivo de hibernación (suspensión híbrida, arranque tipo 0x2) |
| Captura `pktmon` en la tarjeta con el PC encendido | Llegan la difusión `192.168.100.255:9` (×3) y el unicast IPv6 `[::2]:9`, 102 bytes: el router reenvía Wi-Fi → cable |
| Conclusión | La entrega funciona; el fallo está en la activación desde S3. Revisar BIOS: *ErP Ready* = Disabled, *Wake Up Event By* = BIOS, *Resume By PCI-E Device* = Enabled |
| Encendido por Wake-on-LAN | Pendiente tras el ajuste de BIOS (filas 2–7) |

Nota: cortar la corriente con el equipo suspendido elimina la alimentación de
la tarjeta; tras un corte, el encendido remoto solo funciona si la BIOS
mantiene la alimentación en S5 (ErP desactivado).

## Matriz de pruebas

Repite cada fila al menos 3 veces. Para el estado "apagado" anota cuántos
minutos pasaron desde el apagado (afecta a las rutas remotas).

| # | Estado del PC | Red del teléfono | Ruta | Minutos desde el apagado | Resultado en la app | ¿Encendió? | Fecha/hora | Notas |
|---|---|---|---|---|---|---|---|---|
| 1 | Encendido (control) | Wi-Fi casa | LAN | — | | | | |
| 2 | Suspendido | Wi-Fi casa | LAN | — | | | | |
| 3 | Hibernado | Wi-Fi casa | LAN | | | | | |
| 4 | Apagado (sin Inicio rápido) | Wi-Fi casa | LAN | | | | | |
| 5 | Suspendido | Datos móviles, Wi-Fi apagada | IPv6 | — | | | | |
| 6 | Hibernado | Datos móviles, Wi-Fi apagada | IPv6 | | | | | |
| 7 | Apagado | Datos móviles, Wi-Fi apagada | IPv6 | | | | | |

Las filas 5–7 solo tienen sentido después de configurar la regla de firewall
IPv6 (si el router la permite) y comprobar en Diagnóstico que el teléfono tiene
IPv6 global con datos móviles.

## Criterios

- **LAN cumplida**: filas 2 y 4 (o las que el hardware soporte) encienden de
  forma consistente.
- **Wake-on-WAN cumplido**: alguna de las filas 5–7 enciende el PC
  físicamente en todos los intentos y en días distintos. Un envío sin errores
  no cuenta como éxito.
