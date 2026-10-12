import 'package:altair_wake/core/network/reachability_probe.dart';
import 'package:altair_wake/features/wake_on_lan/domain/wake_confirmer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  test('probeTargetsFor incluye IPv4 local e IPv6 si hay puerto de sondeo', () {
    final targets = probeTargetsFor(
      sampleDevice(ipv6Address: '2806:2f0:1234::10'),
    );
    expect(targets.map((a) => a.address), ['192.168.100.20', '2806:2f0:1234::10']);
    expect(probeTargetsFor(sampleDevice(probePort: null)), isEmpty);
    expect(probeTargetsFor(sampleDevice(localIpv4: null)), isEmpty);
  });

  test('checkOnce devuelve null sin sondeo configurado', () async {
    final confirmer = WakeConfirmer(probe: FakeReachabilityProbe());
    expect(await confirmer.checkOnce(sampleDevice(probePort: null)), isNull);
  });

  test('aggregate: basta un destino alcanzable', () {
    const reachable = ReachabilityResult(ReachabilityStatus.reachable, '');
    const silent = ReachabilityResult(ReachabilityStatus.unverifiable, '');
    const noRoute = ReachabilityResult(ReachabilityStatus.noRoute, '');
    expect(WakeConfirmer.aggregate([silent, reachable]), ReachabilityStatus.reachable);
    expect(WakeConfirmer.aggregate([noRoute, noRoute]), ReachabilityStatus.noRoute);
    expect(WakeConfirmer.aggregate([noRoute, silent]), ReachabilityStatus.unverifiable);
    expect(WakeConfirmer.aggregate([]), isNull);
  });

  test('waitUntilReachable confirma cuando el equipo responde', () async {
    final probe = FakeReachabilityProbe(ReachabilityStatus.reachable);
    final confirmer = WakeConfirmer(probe: probe, interval: Duration.zero);
    expect(await confirmer.waitUntilReachable(sampleDevice()), isTrue);
  });

  test('waitUntilReachable devuelve false al agotar el tiempo, sin afirmar apagado', () async {
    final probe = FakeReachabilityProbe(ReachabilityStatus.unverifiable);
    final confirmer = WakeConfirmer(
      probe: probe,
      timeout: const Duration(milliseconds: 50),
      interval: const Duration(milliseconds: 10),
    );
    expect(await confirmer.waitUntilReachable(sampleDevice()), isFalse);
    expect(probe.calls, greaterThan(1));
  });

  test('waitUntilReachable respeta la cancelación', () async {
    final probe = FakeReachabilityProbe();
    final confirmer = WakeConfirmer(probe: probe);
    final result = await confirmer.waitUntilReachable(
      sampleDevice(),
      isCancelled: () => true,
    );
    expect(result, isFalse);
    expect(probe.calls, 0);
  });
}
