import 'dart:io';
import 'dart:typed_data';

/// El sistema operativo no aceptó el datagrama en su cola de envío.
class UdpSendException implements Exception {
  const UdpSendException(this.message);

  final String message;

  @override
  String toString() => 'UdpSendException: $message';
}

abstract interface class UdpSender {
  /// Entrega [payload] al sistema operativo para enviarlo a
  /// [destination]:[port].
  ///
  /// Completar sin error solo significa que el datagrama salió del teléfono;
  /// UDP no confirma la recepción. Lanza [SocketException] o
  /// [UdpSendException] si el envío falla localmente.
  Future<void> send(
    Uint8List payload,
    InternetAddress destination,
    int port, {
    bool broadcast = false,
  });
}

class RawDatagramUdpSender implements UdpSender {
  const RawDatagramUdpSender({
    this.maxWriteAttempts = 3,
    this.retryDelay = const Duration(milliseconds: 50),
  });

  /// `RawDatagramSocket.send` devuelve 0 si el búfer del sistema está lleno;
  /// se reintenta un número acotado de veces antes de declarar el fallo.
  final int maxWriteAttempts;
  final Duration retryDelay;

  @override
  Future<void> send(
    Uint8List payload,
    InternetAddress destination,
    int port, {
    bool broadcast = false,
  }) async {
    final bindAddress = destination.type == InternetAddressType.IPv6
        ? InternetAddress.anyIPv6
        : InternetAddress.anyIPv4;
    final socket = await RawDatagramSocket.bind(bindAddress, 0);
    try {
      socket.broadcastEnabled = broadcast;
      for (var attempt = 0; attempt < maxWriteAttempts; attempt++) {
        final written = socket.send(payload, destination, port);
        if (written == payload.length) return;
        await Future<void>.delayed(retryDelay);
      }
      throw const UdpSendException(
        'El sistema no aceptó el datagrama tras varios intentos.',
      );
    } finally {
      socket.close();
    }
  }
}
