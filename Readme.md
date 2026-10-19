# Lazy Wake Up

Aplicación Flutter (Android) para encender computadoras mediante Wake-on-LAN
en la red local y, cuando la red lo permite, desde Internet. Un agente
opcional para Windows permite además consultar el estado, suspender y apagar
el equipo, y la app abre el escritorio remoto de los equipos encendidos.

El proyecto se llamó antes "Altair Wake": el identificador del paquete
(`com.altair.altair_wake`), el agente y sus tareas, carpetas y reglas de
firewall conservan ese nombre para no romper instalaciones existentes.

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
  scripts/remote-desktop.ps1  activa RDP solo para la red local (administrador)
assets/branding/              logotipo original e icono para la app
tool/generate_launcher_icons.py  genera los iconos de Android desde el logotipo
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

python tool/generate_launcher_icons.py   # tras cambiar assets/branding/lazy_wake_up_logo.png (requiere Pillow)

(cd packages/altair_agent_protocol && dart test)
(cd agent && dart test)
dart compile exe agent/bin/altair_wake_agent.dart -o build/agent/altair_wake_agent.exe
```

### Librerías nativas del escritorio remoto (FreeRDP)

`android/app/src/main/jniLibs/` no está en git: se genera con

```powershell
powershell -ExecutionPolicy Bypass -File tool/native/build_freerdp_android.ps1
```

El script descarga con versión fija y verifica (SHA-256 o etiqueta git) MSYS2,
OpenSSL 3.5 (LTS) y FreeRDP 3.32 en `D:\Desarrollo\lwu-native` (ruta sin
espacios), compila para `arm64-v8a` (API 24, páginas de 16 KB) y copia las
`.so`. Requiere el NDK 28.2 y CMake 3.22.1 del SDK de Android. Sin esas
librerías la app compila igual y el botón **Escritorio** usa Windows App.
La clase puente `com.freerdp.freerdpcore.services.LibFreeRDP` debe conservar
paquete y firmas (contrato JNI); `proguard-rules.pro` evita que R8 la renombre.

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
| Red | TCP 47123 en IPv4 e IPv6; regla de firewall limitada al ejecutable y a `LocalSubnet`, más los rangos de `-RemoteAddress` si se indican |
| Fuera de casa | La app prueba la IPv4 local y, si no conecta, la IPv6 del equipo. Una orden que llegó no se repite por la otra dirección. Requiere IPv6 en el teléfono (p. ej. Cloudflare WARP en datos móviles), `-RemoteAddress 2a09:bac0::/29` (salida IPv6 de WARP) y abrir TCP 47123 hacia el PC en el filtro IPv6 del router |
| Autenticación | HMAC-SHA256 con clave de 256 bits; marca de tiempo (±30 s) y nonce contra repeticiones |
| Respuestas | Firmadas y vinculadas al nonce de la petición. Sin firma válida no se responde nada |
| Abuso | 10 peticiones inválidas en 1 min bloquean el origen 5 min |
| Órdenes | `status`, `suspend` (S3, eventos de activación habilitados), `shutdown` (30 s, cancelable), `cancel`, `display` (enciende la pantalla y evita la suspensión durante 10 min), `rdp` (túnel al Escritorio remoto, ver abajo) |
| Tras despertar por red | Windows deja la pantalla apagada y vuelve a dormir a los ~2 min si nadie lo usa. La app envía `display` al confirmar el encendido (y desde ⋮ → *Encender pantalla*). El agente usa `PowerSetRequest` con *DisplayRequired* + *SystemRequired* |
| Clave en el PC | `C:\ProgramData\AltairWake\agent.key`, accesible solo por SYSTEM y Administradores |
| Clave en el teléfono | `flutter_secure_storage` (Android Keystore); nunca en el JSON de equipos |
| Registro | `C:\ProgramData\AltairWake\agent.log` (rotación a 1 MB), sin la clave |

Instalación (PowerShell como administrador, tras compilar el `.exe`):

```powershell
.\agent\scripts\install.ps1 -ShowKey     # muestra la clave para pegarla en la app
.\agent\scripts\install.ps1 -RotateKey   # genera una clave nueva
.\agent\scripts\install.ps1 -RemoteAddress '2a09:bac0::/29'   # admite además órdenes vía WARP
.\agent\scripts\uninstall.ps1            # elimina tarea, regla, programa y datos
```

En la app: editar el equipo → *Agente de Windows* → puerto 47123 y la clave.
Las órdenes aparecen en el menú ⋮ de la tarjeta.

## Escritorio remoto

| Aspecto | Implementación |
|---|---|
| PC | `agent/scripts/remote-desktop.ps1` activa RDP con NLA y las reglas integradas de firewall limitadas a `LocalSubnet` (`-Disable` lo revierte). Requiere iniciar sesión con contraseña, no con PIN. `-AllowBlankPassword` (no recomendado) permite cuentas sin contraseña por red; `-Disable` restaura el bloqueo |
| App | Con *Puerto RDP* configurado y el equipo encendido, la tarjeta muestra **Escritorio**: abre una sesión RDP **integrada** (FreeRDP 3 compilado para Android, dibujado en una textura de Flutter). Si el teléfono no tiene las librerías nativas (otra arquitectura), recurre a Windows App (`rdp://…`) |
| Control | Tres modos (menú de la barra superior). **Puntero** (por defecto, como un touchpad): un dedo mueve el puntero dibujado por la app y la vista lo sigue; tocar = clic donde está. **Toque directo**: el clic va bajo el dedo; arrastrar = arrastrar. **Mover la vista**: un dedo desplaza la vista y no envía nada. En los dos primeros: mantener = clic derecho; mantener y mover = arrastrar; **doble toque y mantener** = el clic izquierdo queda presionado mientras el dedo siga en la pantalla (moviéndolo, arrastra). Siempre: dos dedos = rueda; pellizcar = zoom |
| Pantalla | La sesión se abre en horizontal y a pantalla completa (deslizar desde el borde muestra las barras del sistema); el botón de girar cambia a vertical. Al salir se restaura la orientación |
| Teclado | El teclado del teléfono funciona como en cualquier campo de texto (sugerencias, escritura deslizando): la app envía al PC solo lo que cambia (retrocesos por lo borrado y el texto nuevo). Barra inferior: Esc, Tab, Ctrl/Alt/Win (se aplican a la siguiente tecla), flechas, Supr, Inicio, Fin, RePág, AvPág. Estas teclas se envían con la marca de tecla extendida (`KBDEXT`); sin ella FreeRDP las traduce al teclado numérico |
| Monitores | *Monitores del PC* en el equipo: **Auto** (pantalla del teléfono) o de 1 a 4 monitores con la resolución de cada uno (lista o *Otra…*), de izquierda a derecha y el principal primero. Con uno solo se fija esa resolución. Con varios, al conectar se elige usarlos todos o solo el principal. En la sesión se ve **un monitor a la vez** (empieza por el principal; lo demás se tapa) y los botones **1 · 2 · … · Todos** de la barra superior cambian de pantalla; en modo puntero, llevar el puntero al borde pasa al monitor vecino. El zoom y el desplazamiento no salen del monitor elegido |
| Certificado | Se muestra la huella SHA-256 la primera vez y FreeRDP la recuerda; si cambia, la app avisa en rojo |
| Fuera de casa | Si RDP no responde en la IPv4 local, la app pide un **túnel al agente** (IPv4 local y después IPv6, como las órdenes): el agente, tras verificar la petición firmada, conecta con RDP en `127.0.0.1:3389` y retransmite. El tráfico va en tramas con HMAC-SHA256 (clave por sentido derivada de la clave del agente y del nonce de la petición), así que nadie en la ruta puede inyectar ni secuestrar la conexión; el contenido ya va cifrado por el TLS de RDP. En el teléfono, el túnel corre en un isolate propio y escucha en `127.0.0.1` en un puerto fijo por equipo (40000–49999), solo para la primera conexión. Máximo 2 túneles a la vez en el agente |
| Alcance | RDP sigue limitado a la red local en el firewall y no se abre en el router: desde fuera solo se llega a través del agente y con su clave. Requiere el agente actualizado en el PC (`install.ps1`) |
| Prueba del túnel | `cd agent; dart run tool/tunnel_smoke_test.dart` levanta un agente temporal y comprueba que el Escritorio remoto del PC responde a través del túnel (negociación X.224), sin iniciar sesión |

## Seguridad

- No se expone RDP, no se usa DMZ ni UPnP, no se publica el panel del router.
- Por defecto el agente solo acepta conexiones de la subred local. Abrirlo a
  Internet es opcional y conviene limitarlo a un rango conocido (p. ej. la
  salida de WARP): sin la clave nadie puede dar órdenes, pero quien la
  obtenga podría apagar el equipo y, con el túnel, abrir su escritorio
  remoto desde fuera. Con una cuenta de Windows sin contraseña, la clave del
  agente es la única barrera: conviene poner contraseña y quitar
  `-AllowBlankPassword`.
- La MAC no es una credencial. Un puerto UDP abierto para WoL permite que
  cualquiera que conozca la dirección encienda el equipo; no da acceso a él.
- Copia de seguridad de Android desactivada para no subir MAC, IPs ni claves a
  la nube.

## Documentación

- [Viabilidad de Wake-on-WAN](docs/viabilidad-wake-on-wan.md)
- [Protocolo de pruebas físicas](docs/pruebas-reales.md)
