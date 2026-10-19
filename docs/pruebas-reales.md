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
| BIOS (2026-10-11 23:09) | *Resume por dispositivo PCI-E* = Enabled, *ErP Ready* = Desactivado, *Restaurar tras pérdida de CA* = Apagado |
| **Encender desde suspensión (Wi-Fi, LAN)** | **Funciona.** Suspendido 23:14:34, despertó 23:14:51; origen de reactivación: *Realtek PCIe GbE Family Controller* |
| Comportamiento tras despertar por red | Windows queda en modo desatendido: pantalla apagada hasta que se pulsa una tecla y nueva suspensión a los ~2 min sin actividad |
| Encender desde apagado | Pendiente |
| Prefijo IPv6 de la LAN tras 7 días | Sin cambios. La dirección DHCPv6 del PC sí cambió (`::2` → `::5`); se usa la SLAAC estable |
| Envío desde datos móviles (otro teléfono) | No llegó nada a la tarjeta del PC (captura `pktmon`). No se sabe si el teléfono tenía IPv6 en datos |
| Tráfico IPv6 externo (Globalping, 2026-10-18): ICMPv6, TCP 47123 y traceroute UDP 9 | **Ningún paquete externo llegó a la tarjeta del PC.** El traceroute llega hasta `2806:2f0:6360:…:c21e`, probablemente la WAN del HG6145F, y no pasa de ahí |
| Conclusión | Con *IPv6 Filtering* en Black List sin reglas, el módem **descarta el IPv6 entrante no solicitado**. Wake-on-WAN requiere abrir UDP 9 hacia el PC en el módem |
| Teléfono con datos móviles (Movistar) | Solo IPv4 con CGNAT; la red no entrega IPv6. Sin IPv6 en el teléfono no hay ruta hacia la casa |
| Regla del módem (2026-10-18) | *IPv6 Filtering*: Downlink = White List, regla Wan→Lan, UDP, Dst IPv6 = SLAAC estable del PC, Dst Port 40009. La tarjeta despierta con el paquete mágico en cualquier puerto, así que no hace falta el 9 |
| UDP IPv6 desde datos móviles + Cloudflare WARP (2026-10-18) | **Llegó a la tarjeta del PC** (`pktmon`): origen `2a09:bac5:…` (salida de WARP), destino `[…]:40009` |
| Apagar por el agente desde datos móviles + WARP (2026-10-18 18:30 y 18:36) | **Funciona** (evento 1074 de SYSTEM, "Apagado solicitado desde Altair Wake") |
| Encender por IPv6 desde datos con el PC **apagado** (S5) | **No encendió** (según el usuario). Probable causa: apagado, la tarjeta no responde a la resolución de vecinos IPv6 (NS Offload solo funciona en suspensión), así que el módem no sabe a qué tarjeta entregar el paquete |
| Encender por IPv6 desde datos con el PC **suspendido** (S3, 18:28) | **No despertó** (según el usuario). La suspensión la terminó un dispositivo USB, no la red |
| Encender por Wi-Fi (LAN) con el PC apagado (S5, 18:43) | **Funciona** |
| Hipótesis para S3 por IPv6 | La tarjeta tenía 4 IPv6 (enlace local, temporal, SLAAC estable y DHCPv6 `::5`); el NS Offload solo cubre algunas y Windows elige cuáles. Si la estable no está cubierta, el módem no la resuelve y descarta el paquete |
| Cambio aplicado (2026-10-18 18:53) | `netsh interface ipv6 set privacy state=disabled` y se quitaron la temporal y la `::5`: quedan solo la de enlace local y la estable. `ManagedAddressConfiguration` no puede desactivarse en la interfaz (error 87, lo dicta el anuncio del router), así que la `::5` puede volver al renovar DHCPv6. Revertir: `privacy state=enabled` |
| **Wake-on-WAN por IPv6 con el PC suspendido tras el cambio (18:56)** | **Funciona.** Desde datos móviles + WARP; origen de reactivación: *Realtek PCIe GbE Family Controller*. Al despertar volvió la `::5` (3 direcciones), así que la que impedía la resolución era probablemente la temporal |
| Botón **Escritorio** (Wi-Fi casa, 2026-10-18 21:30) | Windows App (`com.microsoft.rdc.androidx`) acepta el enlace `rdp://full%20address=s:…` (actividad `RdpFileUriLaunchActivity`) y abre la sesión: el PC registró conexiones RDP desde la IP del teléfono (eventos 131/65 de RdpCoreTS). Inicio de sesión con contraseña pendiente de confirmar por el usuario |
| Escritorio remoto **integrado** (FreeRDP, 2026-10-18 23:01) | **Conecta y muestra el escritorio** en la app. Huella del certificado verificada contra el del PC (`ec:18:1f:…:2e:f6`). NLA con cuenta sin contraseña (requiere `LimitBlankPasswordUse=0`). Si alguien vuelve a iniciar sesión en el PC, Windows (Pro, una sesión) desconecta al teléfono (`ERRINFO_RPC_INITIATED_DISCONNECT`) |
| Ratón y teclado en la sesión integrada (2026-10-18) | Según el usuario: **el ratón no funciona** y algunas teclas sí y otras no. Causa de las teclas (revisando el código de FreeRDP): flechas, Inicio, Fin y Supr se enviaban sin `KBDEXT` y llegaban como teclas del teclado numérico; Win no tenía código. Del ratón no se encontró causa en el código: los toques sí generan eventos (prueba de widget) y la app no dibujaba cursor |
| Teclas extendidas, puntero visible (modo touchpad) y selector de monitores (2026-10-19) | **El ratón funciona** (según el usuario). Pendiente: el teclado obligaba a escribir letra por letra (campo de tipo contraseña, sin sugerencias) y en vertical el escritorio de 2 monitores se veía como una franja pequeña |
| Teclado con sugerencias y sesión en horizontal a pantalla completa (2026-10-19) | Instalado; pendiente de prueba física |

Nota: `EffectiveState=5` en el evento Kernel-Power 42 aparece también en la
suspensión híbrida normal; la reanudación sin arranque (sin evento
Kernel-Boot 27) confirma que fue S3.

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
