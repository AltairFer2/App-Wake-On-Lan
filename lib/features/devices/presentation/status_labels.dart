import '../../../core/network/reachability_probe.dart';
import '../../wake_on_lan/domain/wake_report.dart';
import '../domain/device.dart';

String attemptStatusLabel(WakeAttemptStatus status) => switch (status) {
  WakeAttemptStatus.sent => 'Paquete enviado (sin confirmar)',
  WakeAttemptStatus.partiallySent => 'Enviado por algunas rutas (sin confirmar)',
  WakeAttemptStatus.notSent => 'No se pudo enviar',
  WakeAttemptStatus.confirmedAwake => 'Encendido confirmado',
  WakeAttemptStatus.notConfirmed => 'Enviado; encendido no confirmado',
};

String connectivityLabel(ReachabilityStatus status) => switch (status) {
  // Una respuesta del equipo demuestra que está encendido; su ausencia no
  // demuestra que esté apagado.
  ReachabilityStatus.reachable => 'Encendido',
  ReachabilityStatus.unverifiable => 'Sin respuesta',
  ReachabilityStatus.noRoute => 'Sin ruta',
};

String remoteModeLabel(RemoteAccessMode mode) => switch (mode) {
  RemoteAccessMode.none => 'Solo LAN',
  RemoteAccessMode.ipv4 => 'LAN + IPv4 remota',
  RemoteAccessMode.ipv6 => 'LAN + IPv6 remota',
};

String routeKindLabel(WakeRouteKind kind) => switch (kind) {
  WakeRouteKind.lanBroadcast => 'LAN',
  WakeRouteKind.wanIpv4 => 'WAN IPv4',
  WakeRouteKind.wanIpv6 => 'WAN IPv6',
};

String routeOutcomeLabel(WakeRouteOutcome outcome) => switch (outcome) {
  WakeRouteOutcome.sent => 'Paquete UDP enviado',
  WakeRouteOutcome.invalidAddress => 'Dirección inválida',
  WakeRouteOutcome.dnsFailure => 'Error de resolución DNS',
  WakeRouteOutcome.socketError => 'Error de socket',
  WakeRouteOutcome.noConnectivity => 'Sin conectividad',
  WakeRouteOutcome.likelyBlockedByNat => 'Posible bloqueo por NAT',
};
