# Altair Wake

Aplicación Flutter (Android) para encender computadoras mediante Wake-on-LAN
en la red local y, cuando la red lo permite, desde Internet. Un agente
opcional para Windows permite además consultar el estado, suspender y apagar
el equipo desde la red local.

La aplicación distingue entre **paquete enviado** y **encendido confirmado**:
solo marca un equipo como encendido si responde a un sondeo TCP posterior al
envío. La falta de respuesta se muestra como "no verificable", nunca como
"apagado".

## Estado

| Fase | Estado |
|---|---|
| 1. Diagnóstico de viabilidad | Documentado en [docs/viabilidad-wake-on-wan.md](docs/viabilidad-wake-on-wan.md) |
| 2. Wake-on-LAN local | Implementado y probado de forma automatizada; **falta prueba física de encendido** |
| 3. Wake-on-WAN | Soporte en la app (rutas IPv4/IPv6); **no verificado** en la red real |
| 4. Producto | Gestión de equipos, persistencia, diagnósticos, interfaz |
| 5. Agente de Windows | Estado, apagar y cancelar verificados en la red real; suspender pendiente de prueba física |

## Estructura del repositorio

```
lib/                          aplicación Flutter
packages/altair_agent_protocol/  protocolo compartido app ↔ agente (Dart puro)
agent/                        agente de Windows (Dart, compilado a .exe)
  scripts/install.ps1         instalación (administrador)
  scripts/uninstall.ps1       desinstalación (administrador)
docs/                         viabilidad y protocolo de pruebas físicas
```

## Requisitos

- Flutter 3.44 / Dart 3.12 (canal stable), Android SDK 36.
- Dependencias añadidas:
  - `shared_preferences` (flutter.dev, BSD-3): lista de equipos.
  - `flutter_secure_storage` (BSD-3): clave del agente cifrada con Android
    Keystore.
  - `crypto` (dart.dev, BSD-3): HMAC-SHA256 del protocolo.
  - `ffi` (dart.dev, BSD-3, solo el agente): `SetSuspendState` y privilegios.

## Comandos

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release        # build/app/outputs/flutter-apk/app-release.apk
flutter install                    # con el teléfono conectado por USB

(cd packages/altair_agent_protocol && dart test)
(cd agent && dart test)
dart compile exe agent/bin/altair_wake_agent.dart -o build/agent/altair_wake_agent.exe
```

### Problemas conocidos del entorno Windows

- **SDK de Flutter en una ruta con espacios** (`C:\Users\Altair Fernando\...`):
  el *build hook* de `objective_c` (dependencia transitiva de
  `flutter_secure_storage_windows` → `path_provider`) arma un comando sin
  comillas y `flutter test` / `flutter build` fallan. Solución sin cambiar el
  proyecto: invocar Flutter por su ruta corta 8.3, por ejemplo
  `C:\Users\ALTAIR~1\fvm\versions\stable\bin\flutter.bat test`, o mover el SDK
  a una ruta sin espacios.
- `android/gradle.properties` desactiva la compilación incremental de Kotlin:
  falla cuando el proyecto y la caché de pub están en unidades distintas.
- La compilación `release` usa la firma de depuración de la plantilla de
  Flutter. Para distribuirla hace falta una clave propia.

## Arquitectura de la app

```
lib/
  main.dart                  composición de dependencias
  app/                       MaterialApp, tema oscuro Material 3, dependencias
  core/
    network/                 MAC, paquete mágico, validadores, clasificación IP,
                             envío UDP, DNS, sondeo TCP, interfaces del teléfono
    security/                almacén cifrado de claves del agente
    errors/  storage/  formatting/
  features/
    devices/                 modelo, repositorio, controlador, lista y formulario
    wake_on_lan/             envío por rutas (WakeService) y confirmación
    power_control/           cliente del agente (estado, suspender, apagar)
    diagnostics/             hallazgos y recomendaciones, pantalla
```

- Estado con `ChangeNotifier` + `ListenableBuilder`.
- Rutas de envío: difusión LAN (siempre) y, opcionalmente, unicast a IPv4
  pública o a IPv6 global. Cada ruta reporta su resultado por separado.
- Un destino remoto privado o de CGNAT no se envía y se informa como "posible
  bloqueo por NAT".
- El paquete se envía 3 veces por ruta para compensar pérdidas de UDP.

## Verificación de estado (sondeo)

Android no permite ICMP desde `dart:io`, así que el estado se comprueba con una
conexión TCP al puerto de sondeo (por defecto el del agente, 47123):

- conexión aceptada o rechazada → **Encendido**;
- sin respuesta → **Sin respuesta** (apagado, suspendido, desconectado o
  firewall que descarta el sondeo; no se afirma que esté apagado).

El sondeo se repite cada 15 s mientras la app está en primer plano. La acción
principal de cada tarjeta depende del resultado: **Encender** si no responde;
**Suspender / Apagar** si responde y tiene agente. Tras una orden de apagado o
suspensión, la tarjeta muestra "Apagando…" (cancelable) hasta que el equipo
deja de responder.

Un puerto sin proceso escuchando **no sirve** como sondeo en este equipo:
aun con una regla de firewall que lo permite, Windows no respondió con RST
(prueba real del 2026-10-11). Por eso el sondeo usa el puerto del agente.

## Agente de Windows

| Aspecto | Implementación |
|---|---|
| Ejecución | Tarea programada `AltairWakeAgent`, cuenta SYSTEM, al iniciar Windows |
| Red | TCP 47123 en IPv4 e IPv6; regla de firewall limitada a `LocalSubnet` y al ejecutable |
| Autenticación | HMAC-SHA256 con clave de 256 bits; marca de tiempo (±30 s) y nonce contra repeticiones |
| Respuestas | Firmadas y vinculadas al nonce de la petición. Sin firma válida no se responde nada |
| Abuso | 10 peticiones inválidas en 1 min bloquean el origen 5 min |
| Órdenes | `status`, `suspend` (S3, eventos de activación habilitados), `shutdown` (30 s, cancelable), `cancel` |
| Clave en el PC | `C:\ProgramData\AltairWake\agent.key`, accesible solo por SYSTEM y Administradores |
| Clave en el teléfono | `flutter_secure_storage` (Android Keystore); nunca en el JSON de equipos |
| Registro | `C:\ProgramData\AltairWake\agent.log` (rotación a 1 MB), sin la clave |

Instalación (PowerShell como administrador, tras compilar el `.exe`):

```powershell
.\agent\scripts\install.ps1 -ShowKey     # muestra la clave para pegarla en la app
.\agent\scripts\install.ps1 -RotateKey   # genera una clave nueva
.\agent\scripts\uninstall.ps1            # elimina tarea, regla, programa y datos
```

En la app: editar el equipo → *Agente de Windows* → puerto 47123 y la clave.
Las órdenes aparecen en el menú ⋮ de la tarjeta.

## Seguridad

- No se expone RDP, no se usa DMZ ni UPnP, no se publica el panel del router.
- El agente solo acepta conexiones de la subred local; no se recomienda
  abrirlo a Internet.
- La MAC no es una credencial. Un puerto UDP abierto para WoL permite que
  cualquiera que conozca la dirección encienda el equipo; no da acceso a él.
- Copia de seguridad de Android desactivada para no subir MAC, IPs ni claves a
  la nube.

## Documentación

- [Viabilidad de Wake-on-WAN](docs/viabilidad-wake-on-wan.md)
- [Protocolo de pruebas físicas](docs/pruebas-reales.md)
