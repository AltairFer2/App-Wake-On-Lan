import 'dart:io';

import '../../../core/network/reachability_probe.dart';
import '../../devices/domain/device.dart';

/// Direcciones a sondear para un dispositivo: su IPv4 local y su IPv6 global,
/// si están configuradas y hay un puerto de sondeo.
List<InternetAddress> probeTargetsFor(Device device) {
  if (device.probePort == null) return const [];
  return [
    for (final raw in [device.localIpv4, device.ipv6Address])
      if (raw != null && InternetAddress.tryParse(raw.trim()) != null)
        InternetAddress(raw.trim()),
  ];
}

/// Sondea un dispositivo hasta detectarlo o agotar el tiempo. Un resultado
/// negativo significa "no confirmado", nunca "apagado".
class WakeConfirmer {
  const WakeConfirmer({
    required this._probe,
    this.timeout = const Duration(seconds: 120),
    this.interval = const Duration(seconds: 5),
  });

  final ReachabilityProbe _probe;

  /// Un arranque en frío de Windows suele tardar entre 20 y 90 s.
  final Duration timeout;
  final Duration interval;

  /// Devuelve `true` en cuanto algún destino responde. [isCancelled] permite
  /// abandonar la espera (p. ej. al cerrar la pantalla).
  Future<bool> waitUntilReachable(
    Device device, {
    bool Function()? isCancelled,
  }) => _waitFor(
    device,
    (status) => status == ReachabilityStatus.reachable,
    timeout,
    isCancelled,
  );

  /// Devuelve `true` cuando el equipo deja de responder al sondeo (tras una
  /// orden de apagado o suspensión). No prueba que esté apagado: solo que ya
  /// no responde.
  Future<bool> waitUntilUnresponsive(
    Device device, {
    Duration timeout = const Duration(seconds: 150),
    bool Function()? isCancelled,
  }) => _waitFor(
    device,
    (status) => status != ReachabilityStatus.reachable,
    timeout,
    isCancelled,
  );

  Future<bool> _waitFor(
    Device device,
    bool Function(ReachabilityStatus? status) condition,
    Duration timeout,
    bool Function()? isCancelled,
  ) async {
    if (probeTargetsFor(device).isEmpty) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() ?? false) return false;
      if (condition(await checkOnce(device))) return true;
      await Future<void>.delayed(interval);
    }
    return false;
  }

  /// Un sondeo de todos los destinos: `reachable` si alguno responde.
  /// Devuelve `null` si el dispositivo no tiene sondeo configurado.
  Future<ReachabilityStatus?> checkOnce(Device device) async =>
      aggregate(await probeEach(device));

  /// Sondea cada destino en paralelo y devuelve el resultado de cada uno.
  Future<List<ReachabilityResult>> probeEach(Device device) async {
    final port = device.probePort;
    if (port == null) return const [];
    return Future.wait([
      for (final target in probeTargetsFor(device)) _probe.probe(target, port),
    ]);
  }

  /// `reachable` si algún destino respondió; `noRoute` si ninguno tiene ruta;
  /// `null` si no hubo destinos.
  static ReachabilityStatus? aggregate(List<ReachabilityResult> results) {
    if (results.isEmpty) return null;
    final statuses = results.map((r) => r.status);
    if (statuses.contains(ReachabilityStatus.reachable)) {
      return ReachabilityStatus.reachable;
    }
    if (statuses.every((s) => s == ReachabilityStatus.noRoute)) {
      return ReachabilityStatus.noRoute;
    }
    return ReachabilityStatus.unverifiable;
  }
}
