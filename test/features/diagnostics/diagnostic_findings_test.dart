import 'dart:io';

import 'package:altair_wake/core/network/local_network_inspector.dart';
import 'package:altair_wake/core/network/reachability_probe.dart';
import 'package:altair_wake/features/devices/domain/device.dart';
import 'package:altair_wake/features/diagnostics/domain/diagnostic_findings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

LocalNetworkSnapshot network(Map<String, List<String>> interfaces) =>
    LocalNetworkSnapshot([
      for (final entry in interfaces.entries)
        LocalInterface(
          name: entry.key,
          addresses: entry.value.map(InternetAddress.new).toList(),
        ),
    ]);

void main() {
  final homeWifi = network({
    'wlan0': ['192.168.100.35', '2806:2f0:1234::55'],
  });
  final mobileIpv4Only = network({
    'rmnet_data0': ['10.200.1.5'],
  });

  Iterable<String> titles(List<DiagnosticFinding> findings) =>
      findings.map((f) => f.title);

  test('sin interfaces informa falta de conectividad', () {
    final findings = buildFindings(
      DiagnosticInputs(network: network({})),
    );
    expect(findings.single.severity, FindingSeverity.blocking);
  });

  test('advierte si el teléfono no está en la subred del equipo', () {
    final findings = buildFindings(
      DiagnosticInputs(device: sampleDevice(), network: mobileIpv4Only),
    );
    expect(titles(findings), contains('El teléfono no parece estar en la red del equipo'));
  });

  test('no advierte de subred si el teléfono está en la LAN', () {
    final findings = buildFindings(
      DiagnosticInputs(device: sampleDevice(), network: homeWifi),
    );
    expect(
      titles(findings),
      isNot(contains('El teléfono no parece estar en la red del equipo')),
    );
  });

  test('modo IPv4 con dirección CGNAT/privada es bloqueante', () {
    final findings = buildFindings(
      DiagnosticInputs(
        device: sampleDevice(
          remoteMode: RemoteAccessMode.ipv4,
          remoteHost: '10.85.101.80',
        ),
        resolvedRemote: [InternetAddress('10.85.101.80')],
      ),
    );
    final blocking = findings.where((f) => f.severity == FindingSeverity.blocking);
    expect(titles(blocking.toList()), contains('La dirección remota IPv4 no es pública'));
  });

  test('modo IPv6 sin IPv6 global en el teléfono es bloqueante', () {
    final findings = buildFindings(
      DiagnosticInputs(
        device: sampleDevice(
          remoteMode: RemoteAccessMode.ipv6,
          ipv6Address: '2806:2f0:1234::10',
        ),
        network: mobileIpv4Only,
      ),
    );
    expect(
      titles(findings),
      contains('La red actual del teléfono no tiene IPv6 global'),
    );
  });

  test('un error DNS se reporta', () {
    final findings = buildFindings(
      DiagnosticInputs(
        device: sampleDevice(
          remoteMode: RemoteAccessMode.ipv4,
          remoteHost: 'casa.example.net',
        ),
        resolutionError: 'No se pudo resolver casa.example.net.',
      ),
    );
    expect(titles(findings), contains('Error de resolución DNS'));
  });

  test('sondeo sin respuesta es "no verificable", nunca "apagado"', () {
    final findings = buildFindings(
      DiagnosticInputs(
        device: sampleDevice(),
        reachability: ReachabilityStatus.unverifiable,
      ),
    );
    final finding = findings.firstWhere((f) => f.title == 'Estado no verificable');
    expect(finding.explanation, contains('no confirma que esté apagado'));
    expect(titles(findings).any((t) => t.toLowerCase().contains('apagado')), isFalse);
  });

  test('sin puerto de sondeo informa que no se puede verificar', () {
    final findings = buildFindings(
      DiagnosticInputs(device: sampleDevice(probePort: null)),
    );
    expect(titles(findings), contains('Sin sondeo de estado'));
  });
}
