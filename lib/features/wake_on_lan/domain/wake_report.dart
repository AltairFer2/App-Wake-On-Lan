import '../../devices/domain/device.dart';

enum WakeRouteKind { lanBroadcast, wanIpv4, wanIpv6 }

enum WakeRouteOutcome {
  /// El datagrama salió del teléfono. No implica que llegara ni que encendiera.
  sent,

  invalidAddress,
  dnsFailure,
  socketError,

  /// El teléfono no tiene ruta hacia el destino con la red actual.
  noConnectivity,

  /// El destino remoto es privado o CGNAT: Internet no puede alcanzarlo.
  likelyBlockedByNat,
}

class WakeRouteResult {
  const WakeRouteResult({
    required this.kind,
    required this.target,
    required this.outcome,
    required this.detail,
  });

  final WakeRouteKind kind;

  /// Destino legible, ej. `192.168.100.255:9`.
  final String target;
  final WakeRouteOutcome outcome;
  final String detail;

  bool get isSent => outcome == WakeRouteOutcome.sent;
}

class WakeReport {
  const WakeReport({required this.at, required this.routes});

  final DateTime at;
  final List<WakeRouteResult> routes;

  bool get anySent => routes.any((r) => r.isSent);

  WakeAttemptStatus get status {
    final sentCount = routes.where((r) => r.isSent).length;
    if (sentCount == 0) return WakeAttemptStatus.notSent;
    if (sentCount < routes.length) return WakeAttemptStatus.partiallySent;
    return WakeAttemptStatus.sent;
  }
}
