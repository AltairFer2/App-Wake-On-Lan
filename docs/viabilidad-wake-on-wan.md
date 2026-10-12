# Viabilidad de Wake-on-WAN — FiberHome HG6145F (RP4379)

Fecha del análisis: 2026-10-11. Leyenda: **[C]** confirmado con datos
observados, **[I]** inferencia técnica, **[P]** pendiente de comprobar.

## 1. Topología observada

| Dato | Valor | Estado |
|---|---|---|
| Acceso | GPON, PPPoE, interfaz `TR069_INTERNET` | [C] |
| IPv4 WAN | 10.85.101.80/32, gateway 10.85.64.1 | [C] |
| IPv4 WAN dentro de RFC 1918 | Sí (10.0.0.0/8) | [C] |
| IPv6 WAN | Global, prefijo `2806:` (bloque asignado a ISP mexicanos) | [C] |
| ISP | Totalplay (prefijo `2806:2f0`, AS17072) | [C] |
| LAN | 192.168.100.0/24, máscara 255.255.255.0 | [C] |
| IPv6 en LAN | Prefijo delegado por el ISP; SLAAC + DHCPv6 con estado (M y O activos), rango `::2`–`::64` | [C] |
| PC y teléfono con IPv6 global en la LAN | Sí | [C] |
| Menús de Wake-on-LAN en el router | Ninguno visible en `Application` | [C] |
| `Security > Firewall > IPv6 Filtering` | Existe; lista blanca/negra con dirección, IP/puerto origen y destino, protocolo | [C] |
| Política IPv6 entrante por defecto | Desconocida; el modo actual de IPv4 Filtering es lista negra | [P] |
| `DHCPv6 Static IP Settings` | Existe; permitiría fijar el sufijo IPv6 del PC | [C] |
| Reenvío a difusión, ARP estático | Sin evidencia en la interfaz | [P] |

### Equipo objetivo

| Dato | Valor | Estado |
|---|---|---|
| Placa | MSI B550M PRO-VDH WIFI, BIOS AMI 2.I0 | [C] |
| Conexión | Ethernet Realtek PCIe GbE, 1 Gbps | [C] |
| Wake on Magic Packet / Shutdown Wake-On-Lan | Habilitados | [C] |
| ARP Offload / NS Offload | Habilitados | [C] |
| Tarjeta armada para despertar (`powercfg /devicequery wake_armed`) | Sí | [C] |
| Estados disponibles | S3, hibernación (sin Modern Standby) | [C] |
| Inicio rápido | Desactivado el 2026-10-11 | [C] |
| Perfil de red de Windows | Público. Un puerto cerrado no responde RST ni con regla de permiso; el sondeo usa el agente (TCP 47123, solo subred local) | [C] |
| Agente alcanzable desde el teléfono en la LAN | Sí, por IPv4 e IPv6 | [C] |
| BIOS: ErP Ready desactivado, Resume By PCI-E activado | No legible desde Windows | [P] |

**Conclusión de topología [C]:** una dirección 10.x no puede existir en
Internet, por lo que el ISP aplica NAT aguas arriba (CGNAT/NAT444). El tráfico
iniciado desde Internet hacia IPv4 nunca llega al HG6145F; el `Port Mapping`
IPv4 no tiene efecto para conexiones entrantes.

## 2. Por qué Wake-on-WAN es difícil sin un equipo encendido

El paquete mágico debe llegar como trama Ethernet a la tarjeta del PC apagado.
El router solo puede construir esa trama si conoce la MAC de destino:

- **IPv4 unicast**: el router necesita una entrada ARP. Con el PC apagado nadie
  responde ARP; la entrada caduca minutos después [I] (en routers Linux pasa a
  `STALE`, se usa una vez y se elimina al fallar la verificación).
- **IPv6 unicast**: igual, con Neighbor Discovery (RFC 4861). IPv6 no tiene
  broadcast; `ff02::1` es de enlace local y un router no lo reenvía desde
  Internet.
- **Difusión IPv4 dirigida** (`192.168.100.255`): evita el problema de ARP,
  pero depende de que el firmware acepte esa dirección en `Port Mapping` [P].
  RFC 2644 recomienda que los routers la descarten por defecto.

## 3. Evaluación de alternativas

### A. IPv4 directa con NAT — **no viable hoy** [C]
La IPv4 WAN es privada. Abrir puertos no sirve porque el tráfico no llega al
router. No se recomienda configurar nada en esta ruta.

### B. IPv6 — **la única ruta plausible sin cambios del ISP** [I]
Requisitos, todos [P] salvo indicación:

1. El PC recibe una IPv6 global `2806:` en la LAN (`ipconfig`).
2. El firewall IPv6 del HG6145F permite crear una regla de entrada UDP hacia
   esa dirección. Si el firmware bloquea todo y no ofrece reglas, esta ruta
   queda descartada.
3. El teléfono tiene IPv6 global con datos móviles (la pantalla Diagnóstico de
   la app lo indica).
4. El router conserva la MAC del PC en su caché de vecinos:
   - **Suspensión (S3 / Modern Standby)**: tarjetas con *NS offload* responden
     a Neighbor Solicitation en nombre de Windows; la ruta puede funcionar de
     forma consistente [I].
   - **Hibernación / apagado**: no hay NS offload; solo funcionaría dentro de
     la ventana en que la entrada sigue en caché [I]. No es confiable.
5. El prefijo IPv6 no cambia. Si el ISP lo rota (reconexión PPPoE, reinicio),
   la IPv6 del PC cambia y la app deja de apuntar al destino correcto. Un DDNS
   AAAA actualizado por el PC lo resolvería, pero es un servicio externo y
   requiere tu autorización.
6. Windows usa direcciones temporales (privacidad) y una estable; hay que usar
   la **estable** (no "temporal" en `ipconfig`).

### C. Funciones propias del router — **no viable con lo observado** [C]
El menú `Application` no muestra Wake-on-LAN y no se encontró documentación
pública de esa función para el HG6145F. No se usarán interfaces de
administración expuestas ni automatizaciones sobre el panel.

### D. IPv4 pública del ISP — **condicional** [P]
Algunos ISP mexicanos la ofrecen por plan o a solicitud (información de foros,
no oficial). Aun con IPv4 pública:
- `Port Mapping` UDP hacia la IP unicast del PC solo funciona mientras el
  router conserve la entrada ARP (mismo problema del punto 2).
- Si el firmware acepta `192.168.100.255` como Private IP, la difusión dirigida
  evitaría ese problema [P].
- Cualquiera que conozca la IP y el puerto puede enviar paquetes WoL (sin
  autenticación). El riesgo se limita a encendidos no deseados.

## 4. Requisitos en Windows (fuente: Microsoft Learn, KB 2776718)

- Windows 10/11 **no arma la tarjeta para WoL tras un apagado con Inicio
  rápido** (apagado híbrido S4). WoL está soportado desde suspensión (S3) e
  hibernación explícita. Desde S5 depende del firmware de la placa.
- Para probar desde apagado: desactivar *Inicio rápido*.
- BIOS/UEFI: activar *Wake on LAN / Power On by PCI-E*, desactivar *ErP/EuP*.
- Adaptador **Ethernet** (no Wi-Fi): *Wake on Magic Packet* habilitado y
  "Permitir que este dispositivo reactive el equipo".

## 5. Veredicto

| Escenario | Viabilidad con teléfono + router + PC |
|---|---|
| LAN, cualquier estado soportado por el hardware | Viable (MVP implementado) |
| Internet → PC suspendido, vía IPv6 | Plausible; depende de los puntos B.2–B.5 |
| Internet → PC apagado/hibernado, vía IPv6 | No confiable (caché de vecinos) |
| Internet vía IPv4 | No viable mientras exista CGNAT |

Con la arquitectura restringida (sin equipos adicionales) **no se puede
garantizar** el encendido remoto desde apagado total. La estrategia
recomendada es dejar el PC en **suspensión** y usar la ruta IPv6, después de
verificarla con el protocolo de [pruebas-reales.md](pruebas-reales.md).

## 6. Información que falta (mínima)

1. Si el plan de Totalplay incluye o permite solicitar IPv4 pública.
2. Formulario `Add` de `IPv6 Filtering`: opciones de `Direction` y si el
   router bloquea por defecto el tráfico IPv6 entrante no solicitado.
3. Desde la app, con datos móviles: si el teléfono tiene IPv6 global.
4. Si el prefijo `2806:` cambia tras reiniciar el router o con los días.
5. BIOS (MSI): *ErP Ready* = Disabled y *Resume By PCI-E Device* = Enabled.
6. ¿NS Offload de la Realtek cubre la dirección DHCPv6 (`::2`) o solo la
   SLAAC estable? Se determina probando ambas desde suspensión.

## Fuentes

- Microsoft Learn — *Wake on LAN behavior in Windows*:
  https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/wake-on-lan-feature
- RFC 1918 (direcciones privadas), RFC 6598 (100.64.0.0/10), RFC 4861
  (Neighbor Discovery), RFC 2644 (difusión dirigida), RFC 4291 (arquitectura
  de direccionamiento IPv6).
- Hojas de datos del HG6145F (Intelbras/FiberHome): doble pila IPv4/IPv6,
  firewall y ACL; no mencionan Wake-on-LAN.
