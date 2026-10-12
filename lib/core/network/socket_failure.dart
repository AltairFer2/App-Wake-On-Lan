import 'dart:io';

/// Categoría de un error de socket del sistema operativo.
enum SocketFailureKind {
  /// El teléfono no tiene ruta hacia la red de destino.
  networkUnreachable,

  /// Sin respuesta de resolución de vecinos (ARP/NDP) o el router informó
  /// que el host es inalcanzable.
  hostUnreachable,

  /// El host respondió rechazando la conexión: está encendido.
  connectionRefused,

  /// El sistema operativo denegó la operación.
  permissionDenied,

  timedOut,
  other,
}

/// Traduce el `errno` de [SocketException.osError] a una categoría.
///
/// Los códigos dependen de la plataforma: Android/Linux usan `errno` POSIX y
/// Windows (pruebas en escritorio) usa los códigos WSA.
SocketFailureKind classifySocketFailure(
  SocketException error, {
  bool? isWindows,
}) {
  final code = error.osError?.errorCode;
  if (code == null) {
    final message = error.message.toLowerCase();
    return message.contains('timed out')
        ? SocketFailureKind.timedOut
        : SocketFailureKind.other;
  }
  final codes = (isWindows ?? Platform.isWindows) ? _windowsCodes : _posixCodes;
  return codes[code] ?? SocketFailureKind.other;
}

const Map<int, SocketFailureKind> _posixCodes = {
  1: SocketFailureKind.permissionDenied, // EPERM
  13: SocketFailureKind.permissionDenied, // EACCES
  101: SocketFailureKind.networkUnreachable, // ENETUNREACH
  110: SocketFailureKind.timedOut, // ETIMEDOUT
  111: SocketFailureKind.connectionRefused, // ECONNREFUSED
  113: SocketFailureKind.hostUnreachable, // EHOSTUNREACH
};

/// Dart en Windows puede reportar códigos Win32 (12xx) o WSA (100xx) según la
/// operación; p. ej. una conexión TCP rechazada llega como 1225.
const Map<int, SocketFailureKind> _windowsCodes = {
  1225: SocketFailureKind.connectionRefused, // ERROR_CONNECTION_REFUSED
  1231: SocketFailureKind.networkUnreachable, // ERROR_NETWORK_UNREACHABLE
  1232: SocketFailureKind.hostUnreachable, // ERROR_HOST_UNREACHABLE
  10013: SocketFailureKind.permissionDenied, // WSAEACCES
  10051: SocketFailureKind.networkUnreachable, // WSAENETUNREACH
  10060: SocketFailureKind.timedOut, // WSAETIMEDOUT
  10061: SocketFailureKind.connectionRefused, // WSAECONNREFUSED
  10065: SocketFailureKind.hostUnreachable, // WSAEHOSTUNREACH
};
