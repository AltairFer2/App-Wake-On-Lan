import 'package:flutter/services.dart';

import '../domain/remote_desktop.dart';

enum RemoteDesktopLaunch {
  /// Un cliente aceptó el enlace `rdp://` y abre la conexión.
  connection,

  /// El cliente no acepta enlaces: se abrió su pantalla principal.
  clientApp,

  /// No hay cliente instalado: se abrió su ficha en Google Play.
  store,

  /// No se pudo abrir nada.
  unavailable,
}

/// Abre el cliente de escritorio remoto mediante el canal nativo de Android
/// (`MainActivity.kt`).
class RemoteDesktopLauncher {
  const RemoteDesktopLauncher([
    this._channel = const MethodChannel('lazy_wake_up/remote_desktop'),
  ]);

  final MethodChannel _channel;

  Future<RemoteDesktopLaunch> open(String host, int port) async {
    try {
      final result = await _channel.invokeMethod<String>('open', {
        'link': remoteDesktopLink(host, port),
        'package': windowsAppPackage,
      });
      return RemoteDesktopLaunch.values.asNameMap()[result] ??
          RemoteDesktopLaunch.unavailable;
    } on PlatformException {
      return RemoteDesktopLaunch.unavailable;
    } on MissingPluginException {
      // Plataformas sin la implementación nativa (p. ej. pruebas o escritorio).
      return RemoteDesktopLaunch.unavailable;
    }
  }
}
