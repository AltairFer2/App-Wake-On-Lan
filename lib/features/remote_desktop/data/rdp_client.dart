import 'dart:async';

import 'package:flutter/services.dart';

/// Datos para abrir una sesión RDP integrada (FreeRDP). La contraseña solo
/// viaja al código nativo; no se guarda ni se registra.
class RdpConnectionRequest {
  const RdpConnectionRequest({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.width,
    required this.height,
    this.monitorLayout = const [],
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final int width;
  final int height;

  /// x, y, ancho, alto por monitor (ver `MonitorLayout.toFlatList`). Vacío:
  /// un solo monitor de [width] x [height].
  final List<int> monitorLayout;

  Map<String, Object> toMap() => {
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'width': width,
    'height': height,
    'monitorLayout': monitorLayout,
  };
}

/// Evento de la sesión emitido por el código nativo.
sealed class RdpEvent {
  const RdpEvent();

  /// `null` si el tipo es desconocido (versiones futuras del lado nativo).
  static RdpEvent? fromMap(Map<Object?, Object?> map) => switch (map['type']) {
    'resize' => RdpResized(map['width']! as int, map['height']! as int),
    'connected' => const RdpConnected(),
    'failed' => RdpFailed((map['message'] as String?) ?? ''),
    'disconnected' => const RdpDisconnected(),
    'certificate' => RdpCertificateRequest(
      requestId: map['requestId']! as int,
      host: map['host']! as String,
      port: map['port']! as int,
      subject: (map['subject'] as String?) ?? '',
      issuer: (map['issuer'] as String?) ?? '',
      fingerprint: (map['fingerprint'] as String?) ?? '',
      changed: (map['changed'] as bool?) ?? false,
      previousFingerprint: map['oldFingerprint'] as String?,
    ),
    _ => null,
  };
}

class RdpResized extends RdpEvent {
  const RdpResized(this.width, this.height);
  final int width;
  final int height;
}

class RdpConnected extends RdpEvent {
  const RdpConnected();
}

class RdpFailed extends RdpEvent {
  const RdpFailed(this.message);

  /// Texto de error de FreeRDP (en inglés); puede venir vacío.
  final String message;
}

class RdpDisconnected extends RdpEvent {
  const RdpDisconnected();
}

/// FreeRDP espera la respuesta antes de continuar la conexión.
class RdpCertificateRequest extends RdpEvent {
  const RdpCertificateRequest({
    required this.requestId,
    required this.host,
    required this.port,
    required this.subject,
    required this.issuer,
    required this.fingerprint,
    required this.changed,
    this.previousFingerprint,
  });

  final int requestId;
  final String host;
  final int port;
  final String subject;
  final String issuer;
  final String fingerprint;

  /// El equipo presenta un certificado distinto al aceptado antes.
  final bool changed;
  final String? previousFingerprint;
}

class RdpException implements Exception {
  const RdpException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'RdpException($code): $message';
}

/// Acceso al cliente RDP nativo (`RdpChannel.kt`).
class RdpClient {
  const RdpClient({
    this._methods = const MethodChannel('lazy_wake_up/rdp'),
    this._events = const EventChannel('lazy_wake_up/rdp/events'),
  });

  final MethodChannel _methods;
  final EventChannel _events;

  /// `false` si la plataforma o la arquitectura no incluyen FreeRDP.
  Future<bool> isSupported() async {
    try {
      return await _methods.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Stream<RdpEvent> get events => _events
      .receiveBroadcastStream()
      .map((raw) => RdpEvent.fromMap(raw as Map<Object?, Object?>))
      .where((event) => event != null)
      .cast<RdpEvent>();

  /// Inicia la conexión y devuelve el id de la textura donde se dibuja.
  /// Lanza [RdpException] si no puede arrancar.
  Future<int> connect(RdpConnectionRequest request) async {
    try {
      final textureId = await _methods.invokeMethod<int>('connect', request.toMap());
      if (textureId == null) {
        throw const RdpException('connect_failed', 'Sin textura de destino.');
      }
      return textureId;
    } on PlatformException catch (error) {
      throw RdpException(error.code, error.message ?? '');
    } on MissingPluginException {
      throw const RdpException('unsupported', 'Cliente RDP no disponible.');
    }
  }

  /// Evento de ratón en coordenadas del escritorio remoto (`PointerFlags`).
  Future<void> sendPointer(int x, int y, int flags) =>
      _methods.invokeMethod<void>('pointer', {'x': x, 'y': y, 'flags': flags});

  /// Tecla por código virtual de Windows (`VirtualKey`).
  Future<void> sendKey(int virtualKey, {required bool down}) =>
      _methods.invokeMethod<void>('key', {'virtualKey': virtualKey, 'down': down});

  /// Texto escrito: cada carácter se pulsa y suelta como Unicode.
  Future<void> sendText(String text) =>
      _methods.invokeMethod<void>('text', {'text': text});

  Future<void> answerCertificate(int requestId, {required bool accept}) =>
      _methods.invokeMethod<void>('answerCertificate', {
        'requestId': requestId,
        'accept': accept,
      });

  Future<void> disconnect() => _methods.invokeMethod<void>('disconnect');
}
