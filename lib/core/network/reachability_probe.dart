import 'dart:io';

import 'socket_failure.dart';

enum ReachabilityStatus {
  /// El equipo respondió (aceptó o rechazó activamente la conexión TCP).
  reachable,

  /// Sin respuesta. Puede estar apagado, suspendido, desconectado o un
  /// firewall descarta el sondeo: no equivale a "apagado".
  unverifiable,

  /// El teléfono no tiene ruta hacia la red del equipo.
  noRoute,
}

class ReachabilityResult {
  const ReachabilityResult(this.status, this.detail);

  final ReachabilityStatus status;
  final String detail;
}

abstract interface class ReachabilityProbe {
  Future<ReachabilityResult> probe(InternetAddress address, int port);
}

/// Sondeo por conexión TCP. Se usa TCP porque Android no permite ICMP (ping)
/// desde `dart:io` sin privilegios, y porque un RST de un puerto cerrado
/// también demuestra que el sistema operativo está en ejecución.
class TcpReachabilityProbe implements ReachabilityProbe {
  const TcpReachabilityProbe({this.timeout = const Duration(seconds: 3)});

  final Duration timeout;

  @override
  Future<ReachabilityResult> probe(InternetAddress address, int port) async {
    final target = '${address.address}:$port';
    try {
      final socket = await Socket.connect(address, port, timeout: timeout);
      socket.destroy();
      return ReachabilityResult(
        ReachabilityStatus.reachable,
        'El puerto TCP $target aceptó la conexión.',
      );
    } on SocketException catch (error) {
      return _fromFailure(error, target);
    }
  }

  ReachabilityResult _fromFailure(SocketException error, String target) {
    switch (classifySocketFailure(error)) {
      case SocketFailureKind.connectionRefused:
        return ReachabilityResult(
          ReachabilityStatus.reachable,
          '$target rechazó la conexión: el equipo está encendido, '
          'aunque ese puerto está cerrado.',
        );
      case SocketFailureKind.networkUnreachable:
        return ReachabilityResult(
          ReachabilityStatus.noRoute,
          'El teléfono no tiene ruta hacia $target con la red actual.',
        );
      case SocketFailureKind.hostUnreachable:
        return ReachabilityResult(
          ReachabilityStatus.unverifiable,
          'Sin respuesta de $target a la resolución de vecinos (ARP/NDP). '
          'Puede estar apagado, suspendido o desconectado.',
        );
      case SocketFailureKind.timedOut:
      case SocketFailureKind.permissionDenied:
      case SocketFailureKind.other:
        return ReachabilityResult(
          ReachabilityStatus.unverifiable,
          'Sin respuesta de $target en ${timeout.inSeconds} s. Puede estar '
          'apagado, suspendido o un firewall descarta el sondeo.',
        );
    }
  }
}
